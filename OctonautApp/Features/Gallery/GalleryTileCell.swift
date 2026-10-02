import UIKit

/// A view that stays a capsule whatever height it is given.
///
/// It rounds itself, in its own layout pass, because the cell cannot do it
/// for it. The badge lives in the cell's `contentView`, so its frame is
/// resolved when *`contentView`* lays out its subviews -- which happens after
/// `GalleryTileCell.layoutSubviews` has already returned. Reading the height
/// there got zero on the first pass, so the badge was a square until some
/// later pass happened to run, and whether one did came down to what else the
/// grid was doing: tiles on screen when the column count changed were round,
/// and everything else was square.
final class CapsuleView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

/// One tile of the gallery grid.
///
/// Plain UIKit rather than `UIHostingConfiguration`, which was the other
/// option and would have let the SwiftUI tile stay as it was. Two reasons it
/// did not: a hosting configuration still runs a SwiftUI update pass per cell
/// per reuse, and -- the deciding one -- the pooled `AVPlayerLayer` has to be
/// re-parented into a view this cell owns, which means the cell has to own a
/// plain `UIView` to put it in.
///
/// The cell draws nothing itself when it holds video. The pool's layer is
/// added over `playerHostView` and removed again when the lease goes, so a tile
/// between leases shows the black underneath rather than a torn frame.
final class GalleryTileCell: UICollectionViewCell {
    static let reuseIdentifier = "GalleryTileCell"

    private let imageView = UIImageView()
    /// Where the pool parents its `AVPlayerLayer`. Exposed because the grid,
    /// not the cell, decides which tiles hold a player.
    let playerHostView = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failureIcon = UIImageView()
    private let blur = UIVisualEffectView(effect: nil)
    private let badge = UIImageView()
    private let badgeBackground = CapsuleView()

    private var imageTask: Task<Void, Never>?
    private var lease: GalleryPlayerPool.Lease?
    private(set) var item: GalleryMediaItem?
    private var isBlurred = false
    /// The copy this tile has asked for, which is not the same thing as the
    /// item it is showing: the item fixes the picture, the column width fixes
    /// which rung of Reddit's ladder to fetch it from. Kept so a tile that is
    /// re-configured -- a blur toggle, a column change -- can tell "ask for a
    /// bigger copy" from "nothing about my picture moved".
    private var requestedURL: URL?

    /// Steps the grid's column count by `$0`, returning whether it moved.
    ///
    /// Here rather than on the collection view because VoiceOver focuses
    /// cells, not the grid, so the zoom action has to be offered by the thing
    /// the reader is actually on. The grid owns the count; the cell only
    /// forwards.
    var onZoom: ((Int) -> Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.backgroundColor = .secondarySystemBackground

        // Poster underneath, player over the top. The order matters and was
        // wrong the first time: with the host view on the bottom and opaque
        // black, every video tile that did not hold one of the four leases
        // was a black rectangle with a play badge on it -- and in a
        // GIF-heavy gallery that is most of the grid. Worse, a lease moving
        // as the reader scrolled flipped tiles between video and black, which
        // is the popping the whole rebuild was supposed to remove.
        //
        // Now the poster is the tile's resting state and the player is an
        // overlay. Taking a lease covers the poster; losing one uncovers it.
        // Nothing ever goes black, and nothing changes size either way.
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isHidden = true
        add(imageView, fill: true)

        playerHostView.backgroundColor = .clear
        playerHostView.isHidden = true
        add(playerHostView, fill: true)

        add(blur, fill: true)

        spinner.hidesWhenStopped = true
        add(spinner, fill: false)

        failureIcon.image = UIImage(systemName: "photo.slash")
        failureIcon.tintColor = .secondaryLabel
        failureIcon.contentMode = .center
        failureIcon.isHidden = true
        add(failureIcon, fill: false)

        badgeBackground.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        badgeBackground.isHidden = true
        badgeBackground.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badgeBackground)

        badge.tintColor = .white
        badge.contentMode = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeBackground.addSubview(badge)

        NSLayoutConstraint.activate([
            badgeBackground.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -6),
            badgeBackground.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -6),
            badge.topAnchor.constraint(equalTo: badgeBackground.topAnchor, constant: 5),
            badge.bottomAnchor.constraint(equalTo: badgeBackground.bottomAnchor, constant: -5),
            badge.leadingAnchor.constraint(equalTo: badgeBackground.leadingAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: badgeBackground.trailingAnchor, constant: -8)
        ])

        isAccessibilityElement = true
        // `supportsZoom` is what puts VoiceOver's zoom actions on the tile,
        // and it is the only way to the column count for a reader who cannot
        // pinch. The toolbar menu is the other.
        accessibilityTraits = [.button, .supportsZoom]
        accessibilityHint = "Opens the full screen media viewer"
    }

    /// Zooming *in* magnifies, which means larger tiles, which means fewer
    /// columns -- the same step the pinch takes.
    override func accessibilityZoomIn(at point: CGPoint) -> Bool {
        onZoom?(-1) ?? false
    }

    override func accessibilityZoomOut(at point: CGPoint) -> Bool {
        onZoom?(1) ?? false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The pooled layer is not in the view hierarchy, so nothing lays it
        // out but this.
        if let playerLayer = playerHostView.layer.sublayers?.first {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = playerHostView.bounds
            CATransaction.commit()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        releasePlayer()
        imageView.image = nil
        imageView.isHidden = true
        imageView.alpha = 1
        playerHostView.isHidden = true
        failureIcon.isHidden = true
        spinner.stopAnimating()
        blur.effect = nil
        badgeBackground.isHidden = true
        item = nil
        requestedURL = nil
        onZoom = nil
    }

    /// - Parameter displayWidth: the width of the column this tile landed in,
    ///   which decides which of Reddit's copies is worth fetching. Passed in
    ///   rather than measured, because the collection view applies the layout
    ///   attributes' frame *after* `cellForItemAt` returns -- at this point a
    ///   recycled cell is still the size of whatever tile had it last.
    func configure(with item: GalleryMediaItem, blurred: Bool, displayWidth: CGFloat) {
        // A tile being re-configured for the item it already holds -- the
        // reader pinched the grid to a different column count, or toggled the
        // blur -- keeps what it is showing. Clearing it would flash the whole
        // visible grid grey on every pinch step, and the copy it holds is a
        // perfectly good stand-in for the larger one on its way.
        let keepsImage = self.item?.id == item.id && imageView.image != nil

        self.item = item
        self.isBlurred = blurred

        blur.effect = blurred ? UIBlurEffect(style: .systemThickMaterial) : nil
        accessibilityLabel = "\(item.post.isSensitive ? "Sensitive media. " : "")"
            + "\(item.post.title), image \(item.page + 1) of "
            + "\(max(1, item.post.galleryURLs.count))"
        // Not `false`: a re-configure reaches cells that are mid-playback, and
        // answering "not playing" for one of those puts a play badge back over
        // a running video.
        updateBadge(isPlaying: lease != nil)

        // A video with no poster has nothing but black to fall back to, so
        // the tile paints itself black rather than showing the grey an image
        // tile uses while it loads.
        contentView.backgroundColor = item.isVideo ? .black : .secondarySystemBackground

        guard !blurred else {
            // Behind a blur there is nothing to see, so there is nothing worth
            // fetching either.
            return
        }

        guard let url = item.previewURL(displayWidth: displayWidth) else {
            // A video without a poster is not a failure -- it is just a tile
            // waiting for a player. Only an image with no URL is broken.
            failureIcon.isHidden = item.isVideo
            return
        }

        // This exact copy has already been asked for. The commonest outcome of
        // a column change by some distance: Reddit's ladder is coarse, so most
        // steps land a tile back on the rung it was already on, and a tile
        // that reloaded anyway would be doing the work twice to show the same
        // pixels.
        guard requestedURL != url else { return }
        imageTask?.cancel()
        requestedURL = url

        if let cached = OctonautImageCache.cachedImage(for: url) {
            // No fade and no spinner on a cache hit: the commonest case by far
            // once a tile has been past once, and animating it is what made
            // scrolling back through a gallery flicker.
            imageTask = nil
            show(cached, animated: false)
            return
        }

        if !keepsImage {
            imageView.image = nil
            imageView.isHidden = true
            // No spinner over a video: the tile is already black with a play
            // badge, which reads as a video that has not started rather than
            // as something still loading.
            if !item.isVideo { spinner.startAnimating() }
        }
        let isVideo = item.isVideo
        // The shape of a picture belongs to the picture, not to the rung it
        // arrived on, so the measurement is filed under the canonical URL --
        // which is what lets the copy vary with the column width at all.
        let canonicalURL = item.url
        imageTask = Task { [weak self] in
            do {
                let image = try await OctonautImageCache.image(for: url)
                guard !Task.isCancelled, let self, self.requestedURL == url else { return }
                // Measured once and remembered, so a tile that has been off
                // screen and back still knows its shape while its image is
                // being fetched. Images only: what a video tile loads here is
                // Reddit's `thumbnail`, a small crop with proportions of its
                // own, and laying the tile out to those would letterbox the
                // video inside a box of the wrong shape when a player arrives.
                if !isVideo, image.size.height > 0 {
                    GalleryTileRatios.remember(
                        image.size.width / image.size.height, for: canonicalURL)
                }
                // No fade when the tile is only trading up to a larger copy of
                // the picture it is already showing: there is nothing to
                // reveal, and the fade reads as a flicker.
                self.show(image, animated: !keepsImage)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.requestedURL == url else { return }
                self.spinner.stopAnimating()
                self.failureIcon.isHidden = isVideo
            }
        }
    }

    /// Hands this tile a pooled player. The layer is already parented by the
    /// pool; the cell only has to stop showing whatever it had.
    func adopt(_ lease: GalleryPlayerPool.Lease, playing: Bool) {
        self.lease = lease
        playerHostView.isHidden = false
        spinner.stopAnimating()
        if playing {
            lease.play()
        } else {
            lease.pause()
        }
        updateBadge(isPlaying: playing)
    }

    func releasePlayer() {
        // Called for every visible cell on every pass, most of which never
        // held a player, so the nothing-to-do case must actually do nothing
        // -- `updateBadge` builds a symbol image, and doing that ten times a
        // cell a second to arrive at the badge already showing is exactly the
        // sort of work this rebuild is meant to remove.
        guard lease != nil || !playerHostView.isHidden else { return }
        lease?.release()
        lease = nil
        // Back to the poster. The layer has already been taken off this view
        // by the pool, so leaving the host visible would show nothing but the
        // clear it is painted with.
        playerHostView.isHidden = true
        updateBadge(isPlaying: false)
    }

    var heldURL: URL? { lease?.isValid == true ? lease?.url : nil }

    private func show(_ image: UIImage, animated: Bool) {
        spinner.stopAnimating()
        failureIcon.isHidden = true
        imageView.image = image
        imageView.isHidden = false
        guard animated else { return }
        imageView.alpha = 0
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
            self.imageView.alpha = 1
        }
    }

    private func updateBadge(isPlaying: Bool) {
        guard let item else {
            badgeBackground.isHidden = true
            return
        }
        // Still worth marking a mounted-but-paused video: the first frame
        // alone does not say it is a video.
        let symbol: String?
        if isBlurred {
            symbol = "eye.slash.fill"
        } else if item.isVideo && !isPlaying {
            symbol = "play.fill"
        } else {
            symbol = nil
        }
        guard let symbol else {
            badgeBackground.isHidden = true
            return
        }
        badge.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(
                textStyle: .caption1, scale: .medium))
        badgeBackground.isHidden = false
    }

    private func add(_ view: UIView, fill: Bool) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        if fill {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                view.topAnchor.constraint(equalTo: contentView.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
            ])
        }
    }
}
