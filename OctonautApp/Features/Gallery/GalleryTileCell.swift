import UIKit

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
    private let badgeBackground = UIView()

    private var imageTask: Task<Void, Never>?
    private var lease: GalleryPlayerPool.Lease?
    private(set) var item: GalleryMediaItem?
    private var isBlurred = false

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
        accessibilityTraits = .button
        accessibilityHint = "Opens the full screen media viewer"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        badgeBackground.layer.cornerRadius = badgeBackground.bounds.height / 2
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
    }

    func configure(with item: GalleryMediaItem, blurred: Bool) {
        self.item = item
        self.isBlurred = blurred

        blur.effect = blurred ? UIBlurEffect(style: .systemThickMaterial) : nil
        accessibilityLabel = "\(item.post.isSensitive ? "Sensitive media. " : "")"
            + "\(item.post.title), image \(item.page + 1) of "
            + "\(max(1, item.post.galleryURLs.count))"
        updateBadge(isPlaying: false)

        // A video with no poster has nothing but black to fall back to, so
        // the tile paints itself black rather than showing the grey an image
        // tile uses while it loads.
        contentView.backgroundColor = item.isVideo ? .black : .secondarySystemBackground

        guard !blurred else {
            // Behind a blur there is nothing to see, so there is nothing worth
            // fetching either.
            return
        }

        guard let url = item.previewURL else {
            // A video without a poster is not a failure -- it is just a tile
            // waiting for a player. Only an image with no URL is broken.
            failureIcon.isHidden = item.isVideo
            return
        }

        if let cached = OctonautImageCache.cachedImage(for: url) {
            // No fade and no spinner on a cache hit: the commonest case by far
            // once a tile has been past once, and animating it is what made
            // scrolling back through a gallery flicker.
            show(cached, animated: false)
            return
        }

        // No spinner over a video: the tile is already black with a play
        // badge, which reads as a video that has not started rather than as
        // something still loading.
        if !item.isVideo { spinner.startAnimating() }
        let isVideo = item.isVideo
        imageTask = Task { [weak self] in
            do {
                let image = try await OctonautImageCache.image(for: url)
                guard !Task.isCancelled, let self, self.item?.previewURL == url else { return }
                // Measured once and remembered, so a tile that has been off
                // screen and back still knows its shape while its image is
                // being fetched. Images only: what a video tile loads here is
                // Reddit's `thumbnail`, a small crop with proportions of its
                // own, and laying the tile out to those would letterbox the
                // video inside a box of the wrong shape when a player arrives.
                if !isVideo, image.size.height > 0 {
                    GalleryTileRatios.remember(image.size.width / image.size.height, for: url)
                }
                self.show(image, animated: true)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.item?.previewURL == url else { return }
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
