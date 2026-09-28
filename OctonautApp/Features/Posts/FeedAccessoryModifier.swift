import SwiftUI

/// Attaches the feed's tab bar accessory, and keeps it off every tab that is
/// not a feed.
///
/// An accessory whose content is empty still reserves its bar, so the other
/// tabs showed a blank strip above the tab bar. Only
/// `tabViewBottomAccessory(isEnabled:)` removes it outright, and that is
/// iOS 26.1 against a 26.0 deployment target -- hence the branch. The
/// availability check is constant for any given device, so it never flips at
/// runtime and never changes view identity.
@MainActor
struct FeedAccessoryModifier: ViewModifier {
    let descriptor: FeedDescriptorModel?
    /// The reader's "Show hide read posts bar" setting.
    let isEnabled: Bool
    let store: OctonautFeatureStore
    let action: (FeedDescriptorModel) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled && descriptor != nil) {
                accessory
            }
        } else {
            content.tabViewBottomAccessory {
                accessory
            }
        }
    }

    @ViewBuilder
    private var accessory: some View {
        if isEnabled, let descriptor {
            FeedSeenFilterAccessory(
                store: store,
                action: { action(descriptor) }
            )
        }
    }
}
