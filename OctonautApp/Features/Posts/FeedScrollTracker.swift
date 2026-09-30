import Foundation

/// Holds what the feed's scroll view is currently showing, so
/// `FeedScrollReadRule` can be asked the positional question.
///
/// Keyed on post id rather than row index: the list is derived from a store
/// shared by every feed on the navigation stack, so an index means different
/// things to a feed and to the one mounted beneath it.
///
/// Deliberately a plain class rather than `@Observable`. This changes on
/// every scroll event and must not re-render the feed; the views that read
/// it do so inside callbacks, never in a body.
@MainActor
final class FeedScrollTracker {
    private(set) var visibleIDs: Set<String> = []
    private(set) var isScrolledFromTop = false

    /// The visible set as it stood when a row last reported itself visible.
    ///
    /// Pushing a post detail covers the feed, so every row reports
    /// not-visible and `visibleIDs` empties without the reader having
    /// scrolled. Popping back restores the same offsets, so no row crosses
    /// the visibility threshold again and nothing refills the set. Keeping
    /// the previous set lets the rule be asked the question on return, where
    /// it is not merely a guess but the right answer: the scroll position
    /// either side of the push is identical.
    private var lastPopulatedVisibleIDs: Set<String> = []

    /// What to ask `FeedScrollReadRule` about. Empty only before the first
    /// row has ever reported itself visible.
    var effectiveVisibleIDs: Set<String> {
        visibleIDs.isEmpty ? lastPopulatedVisibleIDs : visibleIDs
    }

    /// Bumped whenever something the read rule reads actually changes.
    ///
    /// The rule is asked its question from `onScrollGeometryChange`, so once
    /// per frame, but its inputs are the visible set and whether the list is
    /// off the top -- and those change perhaps ten times a second. Measured
    /// on device at 575 posts, recomputing regardless cost 0.68ms of every
    /// 8.3ms frame. This is what lets the other hundred calls return early
    /// without removing the trigger that needs them.
    private(set) var generation = 0

    private var markedGeneration = -1

    /// Whether anything has changed since this was last asked. Asking
    /// consumes the change, so the first caller in a frame does the work and
    /// the second returns.
    func takeChangedGeneration() -> Bool {
        guard generation != markedGeneration else { return false }
        markedGeneration = generation
        return true
    }

    func setVisibility(_ isVisible: Bool, id: String) {
        if isVisible {
            guard visibleIDs.insert(id).inserted else { return }
            generation += 1
            lastPopulatedVisibleIDs = visibleIDs
        } else {
            // Deliberately not snapshotted here. A push empties the set as a
            // cascade of single removals, so snapshotting on the way down
            // would erode the fallback to whichever row happened to report
            // last -- one row, somewhere below the true top.
            guard visibleIDs.remove(id) != nil else { return }
            generation += 1
        }
    }

    /// A point of slack, so that a list resting at the top is not called
    /// scrolled by sub-pixel layout noise.
    ///
    /// Only the crossing counts, not the offset: the rule reads whether the
    /// list is off the top, never by how much, so a thousand frames of
    /// scrolling are one change.
    func updateOffset(fromTop offset: CGFloat) {
        let scrolled = offset > 1
        guard scrolled != isScrolledFromTop else { return }
        isScrolledFromTop = scrolled
        generation += 1
    }

    func reset() {
        visibleIDs.removeAll()
        lastPopulatedVisibleIDs.removeAll()
        isScrolledFromTop = false
        generation += 1
    }
}

/// Holds a marking decision briefly, so overscrolling can be taken back.
///
/// A post crossing the read line is not read the instant it does: flick a
/// little too far and it should be possible to scroll back without having
/// lost it. Each post gets its own short wait, and coming back into view
/// before it elapses cancels the mark outright.
///
/// This is FUN-LIST-005's 750 milliseconds, applied as the grace on the
/// decision rather than as a dwell that marks posts merely for being on
/// screen -- which would mark the whole screenful for opening a feed.
@MainActor
final class FeedSeenMarkScheduler {
    private var pending: [String: Task<Void, Never>] = [:]
    private let delay: Duration

    init(delay: Duration = .milliseconds(750)) {
        self.delay = delay
    }

    /// The ids currently past the read line. Anything pending that is no
    /// longer among them has been scrolled back to, and is dropped.
    func schedule(_ ids: [String], mark: @escaping @MainActor (String) -> Void) {
        let eligible = Set(ids)
        for (id, task) in pending where !eligible.contains(id) {
            task.cancel()
            pending.removeValue(forKey: id)
        }
        let delay = delay
        for id in ids where pending[id] == nil {
            pending[id] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                mark(id)
                self?.pending.removeValue(forKey: id)
            }
        }
    }

    func cancelAll() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
    }

    var pendingCount: Int { pending.count }
}
