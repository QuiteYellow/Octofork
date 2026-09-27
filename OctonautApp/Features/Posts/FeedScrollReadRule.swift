import Foundation

/// Decides which posts a reader has scrolled past.
///
/// The rule is positional and stateless: everything above the topmost row
/// still on screen has been scrolled past, so it has been read. Recomputing
/// it from the whole visible set on every change is what makes it reliable.
///
/// The previous design tracked rows incrementally -- a set of visible
/// indices, with a row counted as read when it left while a lower row was
/// still on screen. That failed three ways. Indices are positions in a list
/// derived from a store shared by every feed on the navigation stack, so
/// pushing into a community renumbered the feed still mounted beneath it.
/// Being stateful, one missed event stayed wrong until the next reset. And
/// the decision was taken from a single row's departure, so it could only
/// ever be as good as that one event.
///
/// Stated positionally none of that applies: a missed event cannot strand a
/// post, because the next event recomputes from scratch. It is idempotent,
/// and scrolling back up marks nothing new -- the topmost visible row simply
/// moves back up the list.
enum FeedScrollReadRule {
    /// The ids of posts above the topmost visible row, skipping any already
    /// marked seen.
    ///
    /// Returns nothing while the list sits at the top. That is true by
    /// definition -- nothing has been scrolled past yet -- and it also
    /// discards a false positive seen on the device: during the first layout
    /// pass the top row reports itself not-visible for one frame while the
    /// rows below it report visible, which positionally reads as "the reader
    /// scrolled past row one" before they have touched anything.
    ///
    /// Returns nothing when the visible set does not intersect the list
    /// either, which happens in the moment after a feed swaps its contents.
    static func postsScrolledPast(
        in posts: [PostCardModel],
        visibleIDs: Set<String>,
        isScrolledFromTop: Bool
    ) -> [String] {
        guard isScrolledFromTop,
              !visibleIDs.isEmpty,
              let topmost = posts.firstIndex(where: { visibleIDs.contains($0.id) })
        else { return [] }
        return posts[..<topmost].lazy.filter { !$0.isSeen }.map(\.id)
    }
}
