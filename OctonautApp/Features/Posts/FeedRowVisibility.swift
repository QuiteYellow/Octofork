import Foundation

/// Tracks which feed rows are on screen, so a row leaving past the top can
/// be told apart from one leaving past the bottom.
///
/// The distinction is the whole point of marking posts seen while scrolling:
/// a post that merely appeared has not been read. Marking on appearance
/// burned the entire first screen the moment a feed rendered, and with
/// "hide seen" on, those posts vanished before anyone looked at them.
///
/// Deliberately a plain class rather than `@Observable` -- this mutates on
/// every scroll event and must never re-render the feed.
@MainActor
final class FeedRowVisibility {
    private var indices: Set<Int> = []

    func rowAppeared(_ index: Int) {
        indices.insert(index)
    }

    /// Records that a row left the viewport and reports whether it left past
    /// the top, meaning a row below it is still on screen. Scrolling back up
    /// retires rows off the bottom instead, and those stay unseen.
    func rowDisappeared(_ index: Int) -> Bool {
        indices.remove(index)
        guard let deepestVisible = indices.max() else { return false }
        return index < deepestVisible
    }

    func reset() {
        indices.removeAll()
    }
}
