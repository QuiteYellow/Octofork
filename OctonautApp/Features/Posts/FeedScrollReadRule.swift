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
    /// - Parameters:
    ///   - posts: The feed's posts, unfiltered. Deliberately not the derived
    ///     visible list: building that is an array of several hundred
    ///     `PostCardModel`, each carrying a dozen refcounted fields, and this
    ///     runs once per scroll frame. Measured on device at 520 posts it was
    ///     1.03ms of an 8.3ms frame, about 14 percent of wall time while
    ///     scrolling, and the largest single cost in the feed by an order of
    ///     magnitude -- markdown re-parsing, the other suspect, was under
    ///     11ms a second. Nothing here needs the posts that are hidden
    ///     removed: they are hidden precisely because they have been read, so
    ///     `seenIDs` already excludes every one of them from the result.
    ///   - community: Restricts the walk to one community's posts, for a
    ///     community feed mounted over a shared store. Nil for a normal feed.
    static func postsScrolledPast(
        in posts: [PostCardModel],
        community: String? = nil,
        visibleIDs: Set<String>,
        seenIDs: Set<String>,
        isScrolledFromTop: Bool
    ) -> [String] {
        guard isScrolledFromTop, !visibleIDs.isEmpty else { return [] }
        // Indices rather than `for post in posts`, and one field read at a
        // time: the whole point is not to copy the elements.
        var scrolledPast: [String] = []
        for index in posts.indices {
            if let community,
               posts[index].community.caseInsensitiveCompare(community) != .orderedSame {
                continue
            }
            let id = posts[index].id
            // The topmost row still on screen. Everything gathered above it
            // has been scrolled past; everything below it has not.
            if visibleIDs.contains(id) { return scrolledPast }
            if !seenIDs.contains(id) { scrolledPast.append(id) }
        }
        // No visible row in this list at all, which is the moment after a feed
        // swaps its contents. Nothing can be said about what was scrolled past.
        return []
    }
}
