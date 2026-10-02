import SwiftUI
import UIKit

/// The status line under the grid: paging, the end of the listing, or a
/// failure the reader can retry.
final class GalleryFooterView: UICollectionReusableView {
    static let reuseIdentifier = "GalleryFooterView"
    static let height: CGFloat = 64

    enum State: Equatable {
        case none
        case loadingMore
        case end
        case failed(String)
    }

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 2
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
        addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func handleTap() { onTap?() }

    func apply(_ state: State) {
        switch state {
        case .none:
            spinner.stopAnimating()
            label.text = nil
        case .loadingMore:
            spinner.startAnimating()
            label.text = "Loading more"
        case .end:
            spinner.stopAnimating()
            label.text = "You've reached the end."
        case .failed(let message):
            spinner.stopAnimating()
            label.text = "\(message)\nTap to try again."
        }
    }
}

/// A collection view that says when its width changed.
///
/// `updateUIView` is not a geometry callback: SwiftUI runs it when the
/// representable's *values* change, and a rotation changes none of them. The
/// column count and the range of counts the width can carry both have to be
/// re-resolved when the width moves, so something has to notice -- and the
/// layout noticing is no help, because changing the count from inside a
/// layout pass is how a layout loop starts.
final class GalleryCollectionView: UICollectionView {
    var onWidthChange: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        let width = bounds.width
        Task { @MainActor [weak self] in self?.onWidthChange?(width) }
    }
}

/// The gallery grid, on a recycling container.
///
/// What this replaces was `LazyVStack` columns inside a `ScrollView`. A lazy
/// stack defers building a subview until it is needed but is under no
/// obligation to ever let one go, so tiles -- and their observers, their
/// decoded images and their players -- accumulated with how far the reader had
/// scrolled rather than with how much was on screen. A collection view
/// recycles, so the population is bounded by the viewport.
///
/// Three things are deliberately kept from the old grid, because each was
/// arrived at by fixing a real symptom:
///
/// - **Tiles are sized from Reddit's published dimensions**, not from the
///   loaded image. Sizing from the image meant every tile was square until its
///   bytes arrived and then jumped to its real shape, dragging the column with
///   it.
/// - **A tile that has been placed keeps its place.** See
///   `GalleryWaterfallLayout`, where the rule now lives.
/// - **Every ratio is clamped into 9:16...16:9.** Reddit carries comic strips
///   and infographics at ratios like 1:8, which at this column width render as
///   a 1,500pt bar down one side of the grid and wreck the column balancing.
///
/// What changes, besides recycling: a tile no longer decides for itself
/// whether to hold a player. The grid decides, for all of them at once, which
/// is the only place a cap can actually be enforced.
struct GalleryGridView: UIViewRepresentable {
    let items: [GalleryMediaItem]
    let blursNSFW: Bool
    let blursSpoilers: Bool
    let autoplays: Bool
    /// The reader's column count, or zero for "they have never said", in
    /// which case the grid answers from its own width.
    let columns: Int
    let haptics: Bool
    let footerState: GalleryFooterView.State
    let onOpen: (GalleryMediaItem) -> Void
    let onReachEnd: () -> Void
    let onRetry: () -> Void
    let onRefresh: () -> Void
    /// A column count the reader just arrived at, to be remembered.
    let onColumnsChange: (Int) -> Void
    /// The counts this width can carry, so the toolbar can offer exactly
    /// those. The grid is the only thing that knows -- it holds the spacing,
    /// the insets and the tile-width floor the ceiling is derived from.
    let onColumnRangeChange: (ClosedRange<Int>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> GalleryCollectionView {
        let coordinator = context.coordinator
        let view = GalleryCollectionView(frame: .zero, collectionViewLayout: coordinator.layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.dataSource = coordinator
        view.delegate = coordinator
        view.register(GalleryTileCell.self, forCellWithReuseIdentifier: GalleryTileCell.reuseIdentifier)
        view.register(
            GalleryFooterView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
            withReuseIdentifier: GalleryFooterView.reuseIdentifier)

        let refresh = UIRefreshControl()
        refresh.addTarget(coordinator, action: #selector(Coordinator.handleRefresh), for: .valueChanged)
        view.refreshControl = refresh

        // Nothing to arbitrate with the scroll view's pan: the grid does not
        // use `UIScrollView` zooming, so there is no second recognizer with a
        // claim on two fingers.
        view.addGestureRecognizer(
            UIPinchGestureRecognizer(
                target: coordinator, action: #selector(Coordinator.handlePinch)))

        coordinator.collectionView = view
        view.onWidthChange = { [weak coordinator] _ in
            coordinator?.widthChanged()
        }
        coordinator.layout.aspectRatio = { [weak coordinator] index in
            guard let coordinator, coordinator.items.indices.contains(index) else {
                return GalleryMediaItem.fallbackAspectRatio
            }
            return coordinator.items[index].aspectRatio
        }
        return view
    }

    func updateUIView(_ view: GalleryCollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(items: items, footer: footerState)
    }

    static func dismantleUIView(_ view: GalleryCollectionView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var parent: GalleryGridView
        let layout = GalleryWaterfallLayout()
        weak var collectionView: UICollectionView?
        private(set) var items: [GalleryMediaItem] = []
        private var footer: GalleryFooterView.State = .none
        private var playerUpdate: Task<Void, Never>?
        /// When `updatePlayers` last ran, for the throttle above.
        private var lastPlayerUpdate: TimeInterval = 0
        private var lastOffset: CGFloat = 0
        private var lastOffsetSample: TimeInterval = 0
        /// Points per second, from the last pair of scroll events.
        private var scrollSpeed: CGFloat = 0
        private var hasRequestedNextPage = false
        /// The parent values that decide what a tile shows and whether it
        /// plays, as of the last `apply`. Nil until the first one.
        private var lastInputs: Inputs?
        /// Prepared when a pinch begins, so the tap confirming a column step
        /// is not also the thing warming the Taptic Engine up.
        private var feedback: UIImpactFeedbackGenerator?
        /// The last range handed to the parent, so a report that has not
        /// changed does not bounce SwiftUI state on every update.
        private var reportedRange: ClosedRange<Int>?

        /// Everything outside the item list that changes a tile's behaviour.
        ///
        /// `apply` used to look only at the items and return early when they
        /// had not changed -- which is almost always, because SwiftUI calls
        /// `updateUIView` for any reason at all. So a change in *these* was
        /// silently dropped, and that is why no video played until the grid
        /// was scrolled: `autoplayVideo` defaults to `.wifi`, and
        /// `OctonautNetworkStatus.isConnectedViaWiFi` starts false and is set
        /// asynchronously by `NWPathMonitor`. The first render therefore has
        /// autoplay off; the monitor reports Wi-Fi a moment later; SwiftUI
        /// re-renders with `autoplays` now true; `apply` sees the same items
        /// and returns. Nothing asked the grid to start playing, so nothing
        /// did until a scroll event happened to.
        struct Inputs: Equatable {
            var autoplays: Bool
            var blursNSFW: Bool
            var blursSpoilers: Bool
        }

        /// How much of a tile has to be on screen before it is worth running.
        ///
        /// Was 0.6, inherited from the old grid, where it was one of two
        /// gates on an expensive per-tile player. Half the tile is a more
        /// honest reading of "the reader can see this", and starting earlier
        /// is most of what makes a grid feel like it plays as you scroll
        /// rather than after you stop.
        private static let playThreshold: CGFloat = 0.5

        /// How often playback decisions are revisited while the grid moves.
        ///
        /// This replaced a 160ms *debounce*, and the difference is the whole
        /// answer to "why don't the GIFs play while scrolling". A debounce
        /// re-arms on every event, and `scrollViewDidScroll` fires every
        /// frame -- so during a continuous scroll the timer was cancelled
        /// about sixty times a second and `updatePlayers` simply never ran.
        /// Nothing could start until the reader stopped moving, which is
        /// exactly the symptom.
        ///
        /// The dwell was there because *creating* an `AVPlayer` cost 6 to 17
        /// a second during a scroll. The pool removed that reason: at most
        /// eight players are ever created, and a lease is an
        /// `AVPlayerItem` swap. So this throttles instead -- it runs on the
        /// leading edge and then at most this often, so a tile that comes
        /// into view starts within a frame or two of doing so.
        private static let playbackInterval: TimeInterval = 0.1

        /// Above this speed, in points per second, no new video is started.
        ///
        /// Playing during a scroll is the point, but not during a *fling*.
        /// A tile crossing the screen in a fraction of a second cannot be
        /// watched, and starting it means opening a connection and buffering
        /// a video the reader will never see -- on a metered connection,
        /// repeatedly. Measured on the driven sweep, which covers 31,000
        /// points in 12 seconds (~2,580 pt/s, far faster than reading), the
        /// ungated version took 6.3 leases a second, nearly all of them
        /// abandoned.
        ///
        /// 1,400 pt/s is roughly three screenfuls a second: above a brisk
        /// read, below a flick. Releases are not gated -- a tile leaving the
        /// screen always gives its player back, however fast the grid is
        /// moving, so a fling frees players rather than hoarding them.
        private static let maximumPlaybackScrollSpeed: CGFloat = 1400

        /// The narrowest tile the grid will lay out *on its own*, which is to
        /// say the widest tile a default column count is allowed to produce.
        private static let minimumTileWidth: CGFloat = 170

        /// The narrowest tile the reader may pinch down to.
        ///
        /// Two floors because the one constant was answering two questions,
        /// and that is exactly why a phone could not show three columns: at
        /// 170 points, `Int(389 / 174)` is 2 on a 393-point screen, so the
        /// count the width *suggested* was also the count it *allowed*. A
        /// reader who asks for three gets 125-point tiles there, which is
        /// wider than the system photo grid's own default -- the floor for a
        /// count somebody chose can sit well below the floor for one the app
        /// picks on their behalf.
        private static let minimumPinchedTileWidth: CGFloat = 110

        /// What one column step costs in pinch travel, as a power of two of
        /// the gesture's scale.
        ///
        /// A power of two rather than the raw scale so that a step costs the
        /// same pinch in both directions: two columns to three is a factor of
        /// 0.67 and coming back is a factor of 1.5, and no single threshold on
        /// a linear scale can be fair to both. 0.45 is a factor of about 1.37
        /// -- more travel than an off-axis swipe or a two-finger scroll
        /// produces by accident, and little enough that one deliberate pinch
        /// crosses two steps without the reader letting go.
        private static let columnStepTravel: CGFloat = 0.45

        init(_ parent: GalleryGridView) {
            self.parent = parent
        }

        func tearDown() {
            playerUpdate?.cancel()
            GalleryPlayerPool.shared.releaseAll()
        }

        func apply(items newItems: [GalleryMediaItem], footer newFooter: GalleryFooterView.State) {
            guard let collectionView else { return }
            applyColumnPreference(in: collectionView)

            let footerChanged = newFooter != footer
            footer = newFooter
            layout.footerHeight = newFooter == .none ? 0 : GalleryFooterView.height

            // What the collection view itself believes it is showing, asked
            // *before* `items` moves under it.
            //
            // An insert is described relative to the count the collection view
            // has already committed to, not to the one the data source would
            // answer now. Reading this after the assignment made the first
            // apply fatal: the view had never loaded, so the question itself
            // committed it to the new count, and inserting two rows into a
            // list that already had them is `Invalid batch updates detected`.
            let committed = collectionView.numberOfItems(inSection: 0)
            let sharesPrefix = items.indices.allSatisfy { newItems.indices.contains($0)
                && newItems[$0].id == items[$0].id }

            // Pagination only ever appends, and an append is the one change
            // that can be made without disturbing a single tile already on
            // screen. Anything else -- a refresh, a different feed, a filter
            // -- is a different list and has to start again. So is any
            // disagreement with what the view has committed to, which is not
            // supposed to happen and must not be resolved with an insert.
            let isAppend = newItems.count > items.count
                && committed == items.count
                && sharesPrefix
            let isSame = newItems.count == items.count && sharesPrefix

            let inputs = Inputs(
                autoplays: parent.autoplays,
                blursNSFW: parent.blursNSFW,
                blursSpoilers: parent.blursSpoilers)
            let inputsChanged = inputs != lastInputs
            let blurChanged = lastInputs.map {
                $0.blursNSFW != inputs.blursNSFW || $0.blursSpoilers != inputs.blursSpoilers
            } ?? false
            lastInputs = inputs

            if isSame {
                items = newItems
                if footerChanged {
                    layout.invalidateLayout()
                    reapplyFooter()
                }
                // Blurring is drawn by the cell, so a change to it has to
                // reach cells that are already on screen -- the same early
                // return that swallowed the autoplay change swallowed the
                // reveal-sensitive-media button too.
                if blurChanged { reconfigureVisibleCells() }
                if inputsChanged { schedulePlayerUpdate(immediately: true) }
                return
            }

            let inserted = isAppend ? Array(items.count..<newItems.count) : []
            items = newItems
            hasRequestedNextPage = false

            if isAppend {
                // No animation: these tiles are below the fold by definition,
                // and animating an insert during a scroll is work with nothing
                // to show for it.
                UIView.performWithoutAnimation {
                    collectionView.performBatchUpdates {
                        collectionView.insertItems(
                            at: inserted.map { IndexPath(item: $0, section: 0) })
                    }
                }
            } else {
                layout.reset()
                collectionView.reloadData()
            }
            schedulePlayerUpdate()
        }

        /// Re-applies the parent's settings to cells already on screen,
        /// without disturbing their place or their images.
        private func reconfigureVisibleCells() {
            guard let collectionView else { return }
            let displayWidth = layout.tileWidth
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let cell = collectionView.cellForItem(at: indexPath) as? GalleryTileCell,
                      items.indices.contains(indexPath.item) else { continue }
                let item = items[indexPath.item]
                cell.configure(
                    with: item,
                    blurred: item.post.isSensitive(
                        blurringNSFW: parent.blursNSFW, blurringSpoilers: parent.blursSpoilers),
                    displayWidth: displayWidth)
            }
        }

        private func reapplyFooter() {
            guard let collectionView else { return }
            let kind = UICollectionView.elementKindSectionFooter
            for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
                let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath)
                (view as? GalleryFooterView)?.apply(footer)
            }
        }

        // MARK: - Columns

        /// The grid got wider or narrower -- a rotation, an iPad split view
        /// dragged. Both the resolved count and the range the toolbar offers
        /// are answers about a width, so both are stale.
        func widthChanged() {
            guard let collectionView else { return }
            applyColumnPreference(in: collectionView)
        }

        /// Brings the grid to the reader's column count, or to the width's own
        /// answer when they have never chosen one.
        ///
        /// Called from `apply`, which SwiftUI runs for any reason at all, so it
        /// has to be idempotent when nothing moved. It also has to be here
        /// rather than only on the gesture: the toolbar menu writes the
        /// setting, and the new value arrives back through exactly this path.
        private func applyColumnPreference(in collectionView: UICollectionView) {
            let width = collectionView.bounds.width
            guard width > 0 else { return }
            report(columnRange(forWidth: width))
            setColumns(
                parent.columns > 0 ? parent.columns : defaultColumns(forWidth: width),
                anchoredAt: nil,
                notifying: false)
        }

        /// How many columns of at least `minimum` points of tile fit in
        /// `width`.
        private func columnsFitting(tileWidth minimum: CGFloat, in width: CGFloat) -> Int {
            let usable = width - layout.horizontalInset * 2 + layout.spacing
            return max(1, Int(usable / (minimum + layout.spacing)))
        }

        /// The column counts this width can carry.
        func columnRange(forWidth width: CGFloat) -> ClosedRange<Int> {
            let ceiling = min(
                SettingsStore.maximumGalleryColumnCount,
                columnsFitting(tileWidth: Self.minimumPinchedTileWidth, in: width))
            return 1...max(1, ceiling)
        }

        private func clampColumns(_ requested: Int, toWidth width: CGFloat) -> Int {
            let range = columnRange(forWidth: width)
            return min(max(requested, range.lowerBound), range.upperBound)
        }

        /// What to lay out at when the reader has never said.
        ///
        /// The width's own answer, which is two on every phone and more on an
        /// iPad -- and the reason the stored preference has a "never said"
        /// value at all. Storing a flat 2 instead would be right on a phone
        /// and much too coarse on a 1,024-point screen, with no way left to
        /// tell a 2 somebody chose from a 2 nobody did.
        private func defaultColumns(forWidth width: CGFloat) -> Int {
            max(2, columnsFitting(tileWidth: Self.minimumTileWidth, in: width))
        }

        /// Lays the grid out at `columns`, keeping the tile under `point`
        /// where it is on screen.
        ///
        /// The offset correction is the whole gesture. Two columns to three
        /// cuts the content height by about a third, and nothing moves
        /// `contentOffset` on its own -- so a reader twelve thousand points
        /// into a feed is dropped somewhere unrelated, which reads as the grid
        /// having lost their place rather than having changed shape.
        ///
        /// It is done here rather than from the layout's
        /// `targetContentOffset(forProposedContentOffset:)`, which is the hook
        /// that looks built for it: that one is called for a layout
        /// *replacement* or an animated transition, not for the plain
        /// invalidation this does, so it would never run.
        ///
        /// Nothing is animated, and that is a decision rather than an
        /// omission. Two column counts of a waterfall layout are not affine
        /// versions of each other -- the packing differs, so almost every tile
        /// changes both column and height -- which leaves nothing meaningful
        /// to interpolate. The anchor is what makes the change legible: the
        /// tile under the reader's fingers does not move, so the grid reads as
        /// having re-flowed around it.
        /// `requested` is clamped into what this width can carry, here rather
        /// than at each call site, because every route in -- the pinch, the
        /// zoom action, a stored preference made on a wider screen -- can ask
        /// for a count that does not exist. An unclamped zero is not merely
        /// out of range: it persists as "automatic", and it leaves
        /// `columnHeights.count` at one against a `columnCount` of zero, which
        /// `prepare()` reads as a changed column count and resets the whole
        /// placement for, on every pass, for as long as the grid is open.
        @discardableResult
        private func setColumns(
            _ requested: Int, anchoredAt point: CGPoint?, notifying: Bool
        ) -> Bool {
            guard let collectionView else { return false }
            let columns = clampColumns(requested, toWidth: collectionView.bounds.width)
            guard columns != layout.columnCount else { return false }

            // Nothing on screen yet: no place to keep, and no reason to force
            // a layout pass to find one. This is the path the first `apply`
            // takes, and that one runs inside `updateUIView`.
            guard layout.placedCount > 0, !collectionView.indexPathsForVisibleItems.isEmpty else {
                layout.columnCount = columns
                layout.invalidateLayout()
                if notifying { notifyColumns(columns) }
                return true
            }

            let anchor = anchor(near: point, in: collectionView)
            layout.columnCount = columns
            layout.invalidateLayout()
            // Forces `prepare`, so the anchor has a new frame to be read on
            // the next line. Deliberately once, on commit: placement is O(n)
            // over the whole paged-out list, which is nothing for a gesture
            // and ruinous per frame -- which is also why the recognizer
            // commits on a threshold rather than tracking continuously.
            collectionView.layoutIfNeeded()
            if let anchor { restore(anchor, in: collectionView) }
            // Tiles now sit in a column of a different width, so the copy
            // worth fetching has changed. Cheap in the common case: Reddit's
            // ladder is coarse enough that most steps leave a tile on the rung
            // it already had, and the cell returns early for those.
            reconfigureVisibleCells()
            if notifying { notifyColumns(columns) }
            schedulePlayerUpdate(immediately: true)
            return true
        }

        /// Resolves the stored preference against the current width, for a
        /// test that has no SwiftUI update to arrive through.
        func applyStoredColumnsForTesting() {
            guard let collectionView else { return }
            applyColumnPreference(in: collectionView)
        }

        /// One column step, from the pinch or from VoiceOver's zoom action.
        @discardableResult
        func step(columns step: Int) -> Bool {
            setColumns(layout.columnCount + step, anchoredAt: nil, notifying: true)
        }

        /// The tile to hold still across a column change, and where on screen
        /// to hold it: the one under the reader's fingers, or failing that
        /// whatever sits nearest the top of the viewport.
        private func anchor(
            near point: CGPoint?, in collectionView: UICollectionView
        ) -> (index: Int, distanceFromTop: CGFloat)? {
            // What the reader sees as the top of the grid, which is below the
            // navigation bar rather than at the content origin.
            let visualTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            let nearestVisible = collectionView.indexPathsForVisibleItems
                .compactMap { path -> (IndexPath, CGFloat)? in
                    guard let frame = layout.layoutAttributesForItem(at: path)?.frame else {
                        return nil
                    }
                    return (path, frame.minY)
                }
                .min { abs($0.1 - visualTop) < abs($1.1 - visualTop) }?
                .0
            guard let candidate = point.flatMap({ collectionView.indexPathForItem(at: $0) })
                ?? nearestVisible,
                  let frame = layout.layoutAttributesForItem(at: candidate)?.frame else {
                return nil
            }
            // Measured against the raw offset, not the visual top, so putting
            // it back is independent of an inset that may have changed in
            // between.
            return (candidate.item, frame.minY - collectionView.contentOffset.y)
        }

        /// Puts the anchor tile back where it was on screen, now that it has a
        /// new frame.
        private func restore(
            _ anchor: (index: Int, distanceFromTop: CGFloat), in collectionView: UICollectionView
        ) {
            guard let frame = layout.layoutAttributesForItem(
                at: IndexPath(item: anchor.index, section: 0))?.frame else { return }
            let insets = collectionView.adjustedContentInset
            let lowest = -insets.top
            // `max` with the floor, because a grid shorter than its viewport
            // has a ceiling below its floor and the clamp below would invert.
            let highest = max(
                lowest,
                layout.collectionViewContentSize.height + insets.bottom
                    - collectionView.bounds.height)
            let y = min(max(frame.minY - anchor.distanceFromTop, lowest), highest)
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: y), animated: false)
        }

        private func notifyColumns(_ columns: Int) {
            if parent.haptics {
                (feedback ?? UIImpactFeedbackGenerator(style: .light)).impactOccurred()
            }
            let notify = parent.onColumnsChange
            // A hop, because this is reachable from `apply` -- and writing
            // SwiftUI state from inside a view update is the one reliable way
            // to make SwiftUI complain about it.
            Task { @MainActor in notify(columns) }
        }

        private func report(_ range: ClosedRange<Int>) {
            guard range != reportedRange else { return }
            reportedRange = range
            let notify = parent.onColumnRangeChange
            Task { @MainActor in notify(range) }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let collectionView else { return }
            switch gesture.state {
            case .began:
                feedback = parent.haptics ? UIImpactFeedbackGenerator(style: .light) : nil
                feedback?.prepare()
            case .changed:
                let travel = log2(max(gesture.scale, 0.01))
                guard abs(travel) >= Self.columnStepTravel else { return }
                // Re-baselined before acting, and unconditionally. A gesture
                // left sitting past the threshold would otherwise fire on
                // every frame for the rest of the pinch; resetting even when
                // the step is refused is what gives the ends of the range a
                // dead stop instead of a buzz per frame.
                gesture.scale = 1
                // Pinching out magnifies, which means larger tiles, which
                // means fewer columns.
                setColumns(
                    layout.columnCount + (travel > 0 ? -1 : 1),
                    anchoredAt: gesture.location(in: collectionView),
                    notifying: true)
            case .ended, .cancelled, .failed:
                feedback = nil
            default:
                break
            }
        }

        @objc func handleRefresh() {
            parent.onRefresh()
            // The store drives the spinner's removal through `updateUIView`;
            // ending it here keeps the control from sticking if a refresh
            // returns nothing new to apply.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.collectionView?.refreshControl?.endRefreshing()
            }
        }

        // MARK: - Data source

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(
            _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: GalleryTileCell.reuseIdentifier, for: indexPath)
            guard let tile = cell as? GalleryTileCell, items.indices.contains(indexPath.item) else {
                return cell
            }
            let item = items[indexPath.item]
            tile.configure(
                with: item,
                blurred: item.post.isSensitive(
                    blurringNSFW: parent.blursNSFW, blurringSpoilers: parent.blursSpoilers),
                displayWidth: layout.tileWidth)
            tile.onZoom = { [weak self] step in self?.step(columns: step) ?? false }
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            viewForSupplementaryElementOfKind kind: String,
            at indexPath: IndexPath
        ) -> UICollectionReusableView {
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: GalleryFooterView.reuseIdentifier, for: indexPath)
            guard let footerView = view as? GalleryFooterView else { return view }
            footerView.apply(footer)
            footerView.onTap = { [weak self] in
                guard case .failed = self?.footer else { return }
                self?.parent.onRetry()
            }
            return footerView
        }

        // MARK: - Delegate

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            // The old tile was a `.plain` button and never showed a selected
            // state; a cell left selected would still be selected on the way
            // back from the viewer.
            collectionView.deselectItem(at: indexPath, animated: false)
            guard items.indices.contains(indexPath.item) else { return }
            parent.onOpen(items[indexPath.item])
        }

        func collectionView(
            _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            // Ask for the next page from a tile short of the end rather than
            // from a footer that has to come on screen first. A grid two
            // columns wide shows a dozen tiles, so a screenful of lead time
            // is about that many.
            if !hasRequestedNextPage, indexPath.item >= items.count - 12 {
                hasRequestedNextPage = true
                parent.onReachEnd()
            }
            schedulePlayerUpdate()
        }

        func collectionView(
            _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            (cell as? GalleryTileCell)?.releasePlayer()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let now = CACurrentMediaTime()
            let offset = scrollView.contentOffset.y
            let elapsed = now - lastOffsetSample
            if elapsed > 0, lastOffsetSample > 0 {
                scrollSpeed = abs(offset - lastOffset) / elapsed
            }
            lastOffset = offset
            lastOffsetSample = now
            schedulePlayerUpdate()
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            scrollSpeed = 0
            schedulePlayerUpdate(immediately: true)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else { return }
            scrollSpeed = 0
            schedulePlayerUpdate(immediately: true)
        }

        // MARK: - Players

        /// Decides which tiles hold a player, for the whole grid at once.
        ///
        /// A tile cannot make this call for itself. It knows whether it is on
        /// screen, which is what the old grid gated on, but it cannot know
        /// whether it is the third video in view or the fifteenth -- and that
        /// is the only question a cap turns on.
        private func schedulePlayerUpdate(immediately: Bool = false) {
            guard !immediately else {
                playerUpdate?.cancel()
                playerUpdate = nil
                runPlayerUpdate()
                return
            }
            // Leading edge: a tile arriving while the grid is already moving
            // starts now, not one interval from now.
            let elapsed = CACurrentMediaTime() - lastPlayerUpdate
            if elapsed >= Self.playbackInterval {
                playerUpdate?.cancel()
                playerUpdate = nil
                runPlayerUpdate()
                return
            }
            // Inside the interval: make sure one trailing pass happens, so
            // the frame the scroll ends on is not left stale. Deliberately
            // not re-armed if one is already pending -- re-arming on every
            // scroll event is the debounce this replaced.
            guard playerUpdate == nil else { return }
            let remaining = Self.playbackInterval - elapsed
            playerUpdate = Task { [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, let self else { return }
                self.playerUpdate = nil
                self.runPlayerUpdate()
            }
        }

        private func runPlayerUpdate() {
            lastPlayerUpdate = CACurrentMediaTime()
            updatePlayers()
        }

        private func updatePlayers() {
            guard let collectionView else { return }
            let viewport = CGRect(
                origin: collectionView.contentOffset, size: collectionView.bounds.size)
            let centre = viewport.midY

            // Only tiles that are actually going to play are candidates.
            //
            // This narrowed after the first device build. A lease used to go
            // to any video tile in view, playing or not, so that it could show
            // a first frame -- and with the poster now underneath, that reason
            // is gone: a paused tile shows its poster and its play badge,
            // which is what it should look like anyway. So the cap no longer
            // has to cover "video tiles on screen", only "videos running at
            // once", and the same number of players goes a great deal further.
            //
            // It also means a reader with autoplay off creates no players at
            // all, where before they got four, each paused and each holding a
            // decoder to display one still.
            let candidates = collectionView.indexPathsForVisibleItems
                .filter { indexPath in
                    guard items.indices.contains(indexPath.item) else { return false }
                    let item = items[indexPath.item]
                    // Behind a blur there is nothing to watch, so a blurred
                    // tile never takes a player off one that can be seen.
                    return item.isVideo && !item.post.isSensitive(
                        blurringNSFW: parent.blursNSFW, blurringSpoilers: parent.blursSpoilers)
                }
                .compactMap { indexPath -> (IndexPath, CGRect)? in
                    guard let frame = layout.layoutAttributesForItem(at: indexPath)?.frame else {
                        return nil
                    }
                    return (indexPath, frame)
                }
                .filter { _, frame in
                    frame.intersection(viewport).height / max(frame.height, 1) >= Self.playThreshold
                }
                // Nearest the middle of the screen first: where the reader is
                // looking, and so where the players go when the grid holds
                // more running videos than the pool can supply.
                .sorted { abs($0.1.midY - centre) < abs($1.1.midY - centre) }

            // A fling starts nothing new. Tiles that already hold a player
            // keep it -- `chosen` still contains them, so they are not
            // released and then re-leased as the speed crosses the line.
            let flinging = scrollSpeed > Self.maximumPlaybackScrollSpeed
            let eligible = flinging
                ? candidates.filter { indexPath, _ in
                    guard let cell = collectionView.cellForItem(at: indexPath)
                        as? GalleryTileCell else { return false }
                    return cell.heldURL != nil
                }
                : candidates
            let chosen = parent.autoplays
                ? Array(eligible.prefix(GalleryPlayerPool.capacity)) : []
            let chosenPaths = Set(chosen.map(\.0))

            // Every visible cell that should not be playing gives its player
            // back -- not just the candidates, because a tile that has just
            // scrolled below the threshold is no longer one.
            for indexPath in collectionView.indexPathsForVisibleItems
            where !chosenPaths.contains(indexPath) {
                (collectionView.cellForItem(at: indexPath) as? GalleryTileCell)?.releasePlayer()
            }

            for (indexPath, _) in chosen {
                guard let cell = collectionView.cellForItem(at: indexPath) as? GalleryTileCell,
                      items.indices.contains(indexPath.item) else { continue }
                let item = items[indexPath.item]
                if cell.heldURL == item.url { continue }
                let lease = GalleryPlayerPool.shared.lease(
                    url: item.url, in: cell.playerHostView, muted: true, loops: true)
                cell.adopt(lease, playing: true)
            }
        }
    }
}
