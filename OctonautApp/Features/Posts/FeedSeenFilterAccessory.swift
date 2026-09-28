import SwiftUI

/// The feed's tab bar accessory: a running tally of posts read, and the
/// control that clears them out of the feed.
///
/// Earlier attempts put this in a `.bottomBar` toolbar item and, before that,
/// a floating glass circle. The bottom bar collides with the tab bar -- it
/// rendered directly beneath the Settings tab -- and Apple's toolbar guidance
/// does not endorse floating buttons over content. The accessory is the slot
/// the system reserves above the tab bar, so it supplies the glass, the
/// margins, and the minimize-on-scroll behaviour.
///
/// The tally gives the control a purpose beyond an abstract filter: it reads
/// as "you have read twelve of these, tap to clear them out", and pressing
/// the button does exactly that.
///
/// Deliberately not a toggle. It used to flip the hide-seen setting, so the
/// second press put back everything the first press had taken away -- while
/// the label promised the opposite. An action can be pressed repeatedly with
/// the meaning the tally implies: clear these, read some more, clear those.
@MainActor
struct FeedSeenFilterAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    /// The store is read here rather than passed as a count, so that the
    /// running tally is observed by this view alone. Reading it up in the
    /// app shell made every marked post re-render the whole TabView.
    let store: OctonautFeatureStore
    let action: () -> Void

    private var postsRead: Int { store.postsReadSinceReset }

    /// Nothing to clear means nothing to press.
    private var hasReadPosts: Bool { store.hasReadPostsInFeed }

    /// Minimized, the accessory shares the tab bar's own height, so it drops
    /// to the count alone rather than competing with the tab labels.
    private var isInline: Bool { placement == .inline }

    private var tally: Text {
        postsRead == 0
            ? Text("No posts read yet")
            : Text("^[\(postsRead) post](inflect: true) read")
    }

    var body: some View {
        HStack(spacing: 12) {
            tally
                .font(isInline ? .caption : .subheadline)
                .foregroundStyle(postsRead == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .contentTransition(.numericText(value: Double(postsRead)))
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: action) {
                Label("Clear read posts", systemImage: "eye.slash")
                    .labelStyle(.iconOnly)
                    .font(isInline ? .body : .title3)
                    .frame(minWidth: 44, minHeight: isInline ? 28 : 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hasReadPosts ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .disabled(!hasReadPosts)
        }
        .padding(.horizontal, 16)
        .animation(.snappy, value: postsRead)
        .animation(.snappy, value: hasReadPosts)
        .sensoryFeedback(.success, trigger: postsRead == 0)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Removes posts you have already read from this feed")
    }
}
