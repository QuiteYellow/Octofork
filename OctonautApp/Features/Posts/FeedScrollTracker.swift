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

    func setVisibility(_ isVisible: Bool, id: String) {
        if isVisible {
            visibleIDs.insert(id)
        } else {
            visibleIDs.remove(id)
        }
    }

    /// A point of slack, so that a list resting at the top is not called
    /// scrolled by sub-pixel layout noise.
    func updateOffset(fromTop offset: CGFloat) {
        isScrolledFromTop = offset > 1
    }

    func reset() {
        visibleIDs.removeAll()
        isScrolledFromTop = false
    }
}
