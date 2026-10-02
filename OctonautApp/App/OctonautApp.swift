import SwiftUI

@main
struct OctonautApp: App {
    @State private var dependencies: AppDependencies

    init() {
#if DEBUG
        if ProcessInfo.processInfo.environment["OCTONAUT_SCREENSHOT"] != nil {
            let preview = AppDependencies.preview()
            preview.settings.customFeeds = [
                CustomFeed(name: "Apple & Swift", communities: ["apple", "swift"]),
                CustomFeed(name: "Photography", communities: ["iphone", "photography"])
            ]
            _dependencies = State(initialValue: preview)
        } else {
            _dependencies = State(initialValue: AppDependencies.live())
        }
#else
        _dependencies = State(initialValue: AppDependencies.live())
#endif
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(dependencies)
                .id(dependencies.resetGeneration)
                .task {
#if OCTOFORK_DEV_ADDIN
                    // Started at launch rather than when its settings screen
                    // is opened: the add-in gates network access, so it has to
                    // be live before the first request, and the first request
                    // happens on this screen.
                    await OctoforkAddinModel.shared.start()
#endif
                    OctonautImageCache.beginRespondingToMemoryWarnings()
                    await OctonautAudioSession.prepareForMutedFeedPlayback()
                    await OctonautImageCache.configure(
                        diskCapacityMB: dependencies.settings.imageCacheLimitMB
                    )
                    await dependencies.accounts.load()
                }
        }
    }
}
