import SwiftUI

@MainActor
struct PostsRootView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    var onSelectFeed: ((FeedDescriptorModel) -> Void)? = nil
    var selectedFeed: FeedDescriptorModel? = nil
    @Environment(AppDependencies.self) private var dependencies
    @State private var communityQuery = ""
    @State private var editingFeed: CustomFeed?
    @AppStorage("posts.sections.feeds.expanded") private var feedsExpanded = true
    @AppStorage("posts.sections.favorites.expanded") private var favoritesExpanded = true
    @AppStorage("posts.sections.communities.expanded") private var communitiesExpanded = true

    private var filteredCommunities: [CommunityCardModel] {
        guard !communityQuery.isEmpty else { return store.communities }
        return store.communities.filter { $0.name.localizedStandardContains(communityQuery) }
    }

    private var favoriteCommunities: [CommunityCardModel] {
        filteredCommunities.filter(\.isFavorite)
    }

    /// The star that leads the index strip and lands on Favorites -- only
    /// while there is a favourite there for it to land on. Every other
    /// non-letter section carries no label, so the strip reads star, #, A...
    ///
    /// A literal star rather than `star.fill`: `SectionIndexLabel` has an
    /// image case, but neither public `sectionIndexLabel` overload can build
    /// one -- both wrap their argument in `.text`, and the strip resolves that
    /// to a string. An SF Symbol in a `Text` compiles and then draws an empty
    /// slot in the index.
    private var favoritesIndexLabel: Text? {
        favoriteCommunities.isEmpty ? nil : Text(verbatim: "\u{2605}")
    }

    /// Whether the trailing A-Z strip takes part, and with it the per-letter
    /// sections it points at.
    ///
    /// Only while the list is showing the whole subscription list: a search
    /// shows flat results, because a reader who has typed three letters wants
    /// the matches rather than the alphabet, and a collapsed Communities
    /// section has no rows for the strip to scroll to.
    private var showsCommunityIndex: Bool {
        communityQuery.isEmpty && communitiesExpanded && !store.communitySections.isEmpty
    }

    var body: some View {
        List {
            Section {
                if feedsExpanded {
                    feedLink(.home, title: "Home", systemImage: "house.fill")
                    feedLink(.popular, title: "Popular", systemImage: "flame.fill")
                    feedLink(.all, title: "All", systemImage: "globe")
                    ForEach(dependencies.settings.customFeeds) { feed in
                        feedLink(feed.descriptor, title: feed.name, systemImage: "rectangle.stack")
                            .contextMenu {
                                Button("Edit Feed", systemImage: "pencil") { editingFeed = feed }
                                Button("Delete Feed", systemImage: "trash", role: .destructive) { deleteFeed(feed) }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", role: .destructive) { deleteFeed(feed) }
                                Button("Edit") { editingFeed = feed }.tint(.orange)
                            }
                    }
                    Button {
                        editingFeed = CustomFeed(name: "", communities: [])
                    } label: {
                        Label("New Custom Feed", systemImage: "plus")
                    }
                }
            } header: {
                collapsibleHeader("Feeds", count: 3 + dependencies.settings.customFeeds.count, systemImage: "rectangle.stack", isExpanded: $feedsExpanded)
            }

            Section {
                if favoritesExpanded {
                    if favoriteCommunities.isEmpty {
                        Text(dependencies.accounts.selectedAccount == nil ? "Sign in to load account favorites." : "Tap a star beside a community to add it here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .wideInterfaceEdgeToEdgeListSeparator(insets: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    } else {
                        ForEach(favoriteCommunities) { community in
                            communityLink(community)
                        }
                    }
                }
            } header: {
                collapsibleHeader("Favorites", count: favoriteCommunities.count, systemImage: "star.fill", isExpanded: $favoritesExpanded)
            }
            .sectionIndexLabel(favoritesIndexLabel)

            Section {
                if communitiesExpanded {
                    communitiesContent
                }
            } header: {
                collapsibleHeader("Communities", count: filteredCommunities.filter { !$0.isFavorite }.count, systemImage: "person.3.fill", isExpanded: $communitiesExpanded)
            }

            if showsCommunityIndex {
                // Grouped in the store, so scrolling and unrelated state
                // changes do not re-sort the whole subscription list.
                ForEach(store.communitySections) { section in
                    Section {
                        ForEach(section.communities) { community in
                            communityLink(community)
                        }
                    } header: {
                        Text(section.title)
                    }
                    .sectionIndexLabel(section.title)
                }
            }
        }
        .listStyle(.plain)
        // Feeds and the Communities header carry no index label, so the strip
        // holds the favourites star and then the letters.
        .listSectionIndexVisibility(showsCommunityIndex ? .visible : .hidden)
        .navigationTitle("Posts")
        .searchable(text: $communityQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a community")
        .refreshable { await store.refreshCommunities(forceRefresh: true) }
        .task(id: store.accountContextKey) { await store.refreshCommunities() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New Custom Feed", systemImage: "rectangle.stack.badge.plus") { editingFeed = CustomFeed(name: "", communities: []) }
                    Button { router.presentedSheet = .composer(.post, community: nil) } label: { Label("New Post", systemImage: "square.and.pencil") }
                    Button { router.push(.gallery(.home)) } label: { Label("Gallery Mode", systemImage: "square.grid.2x2") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
        .sheet(item: $editingFeed) { feed in
            CustomFeedEditorView(feed: feed, communities: store.communities) { saved in
                if let index = dependencies.settings.customFeeds.firstIndex(where: { $0.id == saved.id }) {
                    dependencies.settings.customFeeds[index] = saved
                } else {
                    dependencies.settings.customFeeds.append(saved)
                }
                feedsExpanded = true
                if let onSelectFeed { onSelectFeed(saved.descriptor) }
                else {
                    store.clearVisibleFeed()
                    router.push(.feed(saved.descriptor))
                }
            }
        }
        .sheet(item: Binding(get: { router.presentedSheet }, set: { router.presentedSheet = $0 })) { sheet in
            switch sheet {
            case .composer(let kind, let community): ComposerView(kind: kind, store: store, community: community ?? "")
            case .quickCommunitySearch: QuickCommunitySearchView(store: store, router: router, onSelectFeed: onSelectFeed)
            case .quickAccountSwitcher: QuickAccountSwitcherView(store: store)
            }
        }
    }

    @ViewBuilder
    private var communitiesContent: some View {
        switch store.communitiesState {
        case .loading where store.communities.isEmpty:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading subscriptions…").foregroundStyle(.secondary)
            }
            .wideInterfaceEdgeToEdgeListSeparator(insets: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        case .failed(let message) where store.communities.isEmpty:
            VStack(alignment: .leading, spacing: 6) {
                Label("Communities could not be loaded", systemImage: "exclamationmark.triangle")
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Try Again") { Task { await store.refreshCommunities() } }
            }
            .wideInterfaceEdgeToEdgeListSeparator(insets: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        default:
            let values = filteredCommunities.filter { !$0.isFavorite }
            if values.isEmpty {
                Text(dependencies.accounts.selectedAccount == nil ? "Sign in to load your Reddit subscriptions." : "No subscribed communities found.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .wideInterfaceEdgeToEdgeListSeparator(insets: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            } else if !showsCommunityIndex {
                // Searching, so the matches are one flat run with no letters
                // between them. Otherwise the rows live in the indexed
                // sections below this one.
                ForEach(values) { community in
                    communityLink(community)
                }
            }
            if case .failed(let message) = store.communitiesState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .wideInterfaceEdgeToEdgeListSeparator(insets: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }
        }
    }

    private func collapsibleHeader(_ title: String, count: Int, systemImage: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 20, alignment: .center)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
    }

    @ViewBuilder
    private func communityLink(_ community: CommunityCardModel) -> some View {
        let row = OctonautCommunityRow(
            community: community,
            showsIcon: dependencies.settings.showCommunityIcons,
            onFavorite: { store.toggleFavorite(communityID: community.id) },
            onSubscribe: { store.toggleSubscribe(communityID: community.id) }
        )
        Group {
            if let onSelectFeed {
                Button {
                    onSelectFeed(FeedDescriptorModel(kind: .community, name: community.name))
                } label: {
                    row
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: FeatureRoute.community(community.name)) {
                    row
                }
            }
        }
        .listRowBackground(isSelected(FeedDescriptorModel(kind: .community, name: community.name)) ? Color.accentColor.opacity(0.12) : Color.clear)
        // Keep the system disclosure indicator on the same trailing line as
        // the section controls while the row content still spans the width.
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 14))
        // The row draws its own full-bleed divider, as every self-dividing row
        // here does, so the system separator would be a second line under it --
        // which is what the letter sections made visible. Hiding it also
        // retires the edge-to-edge separator alignment this row used to ask
        // for: there is no system separator left to align.
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func feedLink(_ descriptor: FeedDescriptorModel, title: String, systemImage: String) -> some View {
        Group {
            if let onSelectFeed {
                Button {
                    onSelectFeed(descriptor)
                } label: {
                    Label(title, systemImage: systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: FeatureRoute.feed(descriptor)) {
                    Label(title, systemImage: systemImage)
                }
            }
        }
        .listRowBackground(isSelected(descriptor) ? Color.accentColor.opacity(0.12) : Color.clear)
        .wideInterfaceEdgeToEdgeListSeparator(insets: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    private func deleteFeed(_ feed: CustomFeed) {
        dependencies.settings.customFeeds.removeAll { $0.id == feed.id }
        if selectedFeed?.customFeedID == feed.id { onSelectFeed?(.home) }
    }

    private func isSelected(_ descriptor: FeedDescriptorModel) -> Bool {
        guard onSelectFeed != nil, let selectedFeed else { return false }
        if descriptor.kind == .custom { return selectedFeed.customFeedID == descriptor.customFeedID }
        return selectedFeed.kind == descriptor.kind
            && selectedFeed.name.caseInsensitiveCompare(descriptor.name) == .orderedSame
    }
}

private extension View {
    @ViewBuilder
    func wideInterfaceEdgeToEdgeListSeparator(insets: EdgeInsets) -> some View {
        modifier(WideInterfaceListSeparatorModifier(insets: insets))
    }
}

private struct WideInterfaceListSeparatorModifier: ViewModifier {
    let insets: EdgeInsets
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ViewBuilder
    func body(content: Content) -> some View {
        if OctonautAdaptiveLayout.usesWideInterface(horizontalSizeClass: horizontalSizeClass) {
            content
                .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                    dimensions[.leading] - insets.leading
                }
                .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                    dimensions[.trailing] + insets.trailing
                }
        } else {
            content
        }
    }
}

@MainActor
struct FeedView: View {
    let descriptor: FeedDescriptorModel
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    var onSelectPost: ((PostCardModel) -> Void)? = nil
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingLogin = false
    @State private var selectedMediaPost: PostCardModel?
    @State private var selectedMediaPage = 0
    @State private var crosspostPost: PostCardModel?
    @State private var pendingScrollPoints: CGFloat = 0
    @State private var mediaPreloader = OctonautFeedMediaPreloader()
    @State private var scrollTracker = FeedScrollTracker()
    @State private var markScheduler = FeedSeenMarkScheduler()
    @State private var powerState = OctonautPowerState.shared

    private let mediaPreloadDistance = 20

    /// Warming twenty rows ahead is the most speculative work the feed does, so
    /// it is the first thing Low Power Mode should stop -- `REDDIT-ERROR-003`.
    private var allowsPrefetch: Bool {
        OctonautPrefetchPolicy.allowsPrefetch(
            isLowPowerModeEnabled: powerState.isLowPowerModeEnabled,
            respectsLowPowerMode: dependencies.settings.respectLowPowerMode
        )
    }

    @State private var availableHeight: CGFloat = 800
    private var layoutCommunity: String? { descriptor.kind == .community ? descriptor.name : nil }
    private var compactRows: Bool { dependencies.settings.feedLayout(for: layoutCommunity) == .compact }
    private var thumbnailOnRight: Bool { dependencies.settings.compactThumbnailSide == .right }

    private var visiblePosts: [PostCardModel] {
        switch descriptor.kind {
        case .community:
            return store.visiblePosts.filter { $0.community.caseInsensitiveCompare(descriptor.name) == .orderedSame }
        default:
            return store.visiblePosts
        }
    }

    var body: some View {
        OctonautStateView(state: store.feedState, retry: { Task { await store.refreshPosts(for: descriptor) } }) {
            if visiblePosts.isEmpty {
                ContentUnavailableView("No posts", systemImage: "text.page.slash", description: Text("This feed is empty or your filters removed every post."))
            } else {
                ScrollViewReader { proxy in
                    List {
                        if store.filteredPostCount > 0, dependencies.settings.showFilterCount {
                            Label("\(store.filteredPostCount) posts hidden by your filters", systemImage: "line.3.horizontal.decrease.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(Array(visiblePosts.enumerated()), id: \.element.id) { index, post in
                            Group {
                                if compactRows {
                                    OctonautCompactPostRow(post: post, isSeen: store.isSeen(post.id), thumbnailOnRight: thumbnailOnRight, showsFlair: dependencies.settings.showPostFlair, blursNSFW: dependencies.settings.blurNSFWMedia, blursSpoilers: dependencies.settings.blurSpoilers, onVote: { value in performVote(postID: post.id, value: value) }, onSave: { performSave(postID: post.id) }, onOpen: { open(post) }, onCommunityOpen: { open(post) })
                                } else {
                                    OctonautPostRow(
                                        post: post,
                                        isSeen: store.isSeen(post.id),
                                        showsFlair: dependencies.settings.showPostFlair,
                                        mediaPreloader: mediaPreloader,
                                        mediaMaximumHeight: usesWideInterface ? min(320, max(160, availableHeight * 0.45)) : nil,
                                        onVote: { value in
                                            performVote(postID: post.id, value: value)
                                        },
                                        onSave: { performSave(postID: post.id) },
                                        onSeen: { store.markSeen(postID: post.id) },
                                        onMedia: { page in
                                            selectedMediaPage = page
                                            selectedMediaPost = post
                                        },
                                        onOpen: { open(post) },
                                        onComments: { open(post) },
                                        onCommunityOpen: { open(post) },
                                        onCrosspost: {
                                            beginCrosspost(post)
                                        }
                                    )
                                }
                            }
                            // Viewport visibility, not cell lifecycle: this
                            // fires for the screenful present at first render,
                            // which `onAppear`/`onDisappear` pairs did not, and
                            // is unaffected by the tab bar minimizing mid-scroll.
                            //
                            // 0.4 is FUN-LIST-005's 60 percent, read as the
                            // share of the row that has gone. The threshold
                            // is the fraction that must still be showing for
                            // a row to count as visible, and the rule marks
                            // everything above the topmost visible row -- so
                            // at 0.4 a post is read once less than 40 percent
                            // of it remains, which is 60 percent of it gone
                            // off the top.
                            //
                            // The two neighbouring values are both wrong for
                            // this: 0.6 marks a post while nearly half of it
                            // is still on screen, and a sliver waits until it
                            // has vanished completely.
                            //
                            // Applied inside the row traits. Outside them it
                            // swallows `listRowInsets` and `listRowSeparator`,
                            // and the row comes back with the plain style's
                            // own inset on top of the card's padding.
                            .onScrollVisibilityChange(threshold: 0.4) { isVisible in
                                scrollTracker.setVisibility(isVisible, id: post.id)
                                markPostsScrolledPast()
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .id(post.id)
                            .onAppear {
                                preloadMedia(after: index)
                                // Until something new is visible, not just
                                // one page: a page whose posts are all read,
                                // all cleared, or all duplicates renders no
                                // row, and this `onAppear` is the only thing
                                // that asks for the next one.
                                if index >= visiblePosts.count - 2 {
                                    Task {
                                        await store.loadMorePostsUntilSomethingNewIsVisible(
                                            for: descriptor)
                                    }
                                }
                            }
                        }
                        if store.isPagingForNewPosts, !visiblePosts.isEmpty {
                            HStack { Spacer(); ProgressView("Loading more…"); Spacer() }.padding()
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .safeAreaPadding(.bottom, 24)
                    .frame(maxWidth: usesWideInterface ? 680 : .infinity)
                    .frame(maxWidth: .infinity)
                    .refreshable { await store.refreshPosts(for: descriptor, forceRefresh: true) }
                    .onChange(of: visiblePosts.first?.id) { _, firstID in
                        guard let firstID else { return }
                        proxy.scrollTo(firstID, anchor: .top)
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        geometry.contentOffset.y + geometry.contentInsets.top
                    } action: { oldOffset, newOffset in
                        scrollTracker.updateOffset(fromTop: newOffset)
                        // Recompute here too, not only on a visibility
                        // change. Returning from a pushed post restores the
                        // same offsets, so no row crosses the threshold and a
                        // visibility-only trigger never fires again.
                        markPostsScrolledPast()
                        pendingScrollPoints += abs(newOffset - oldOffset)
                        guard pendingScrollPoints >= 100 else { return }
                        let points = Int(pendingScrollPoints.rounded())
                        pendingScrollPoints = 0
                        Task { await store.recordFeedScroll(points: points) }
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        .navigationTitle(descriptor.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if usesWideInterface {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 16) {
                        sortMenu
                        displayMenu
                        actionsMenu
                    }
                }
            } else {
                ToolbarItem(placement: .principal) {
                    sortMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    displayMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    actionsMenu
                }
            }
        }
        .task(id: FeedLoadIdentity(descriptor: descriptor, account: store.accountContextKey)) {
            scrollTracker.reset()
            markScheduler.cancelAll()
            await store.refreshPosts(for: descriptor)
            await store.loadMorePostsUntilSomethingIsVisible(for: descriptor)
        }
        .task(id: visiblePosts.map(\.id)) {
            mediaPreloader.preload(
                posts: visiblePosts.prefix(mediaPreloadDistance),
                compact: compactRows
            )
        }
        .onChange(of: allowsPrefetch, initial: true) { _, allowed in
            mediaPreloader.allowsPrefetch = allowed
        }
        .sheet(isPresented: $showingLogin) {
            RedditLoginView(accounts: dependencies.accounts)
        }
        .sheet(item: $crosspostPost) { post in
            CrosspostComposerView(post: post)
        }
        .fullScreenCover(item: $selectedMediaPost) { post in
            OctonautMediaViewer(
                post: post,
                initialPage: selectedMediaPage,
                onSave: { performSave(postID: post.id) },
                onOpenPost: { open(post) }
            )
        }
    }

    private var usesWideInterface: Bool {
        OctonautAdaptiveLayout.usesWideInterface(horizontalSizeClass: horizontalSizeClass)
    }

    /// The sorts this route offers. Reddit has no Best listing for a combined
    /// feed, so it is left out rather than silently redirected to Hot.
    private var availableSorts: [PostSort] {
        descriptor.kind == .custom
            ? PostSort.selectable.filter { $0 != .best }
            : PostSort.selectable
    }

    private var activeSort: PostSort { store.effectiveSort(for: descriptor) }

    private var sortSummary: String {
        guard activeSort.acceptsTopTime else { return activeSort.title }
        return "\(activeSort.title) · \(store.selectedTopTime.title)"
    }

    private var sortMenu: some View {
        Menu {
            ForEach(availableSorts, id: \.rawValue) { sort in
                if sort.acceptsTopTime {
                    Menu {
                        ForEach(TopTime.allCases, id: \.self) { time in
                            Button {
                                apply(sort: sort, topTime: time)
                            } label: {
                                sortLabel(
                                    time.title,
                                    isSelected: activeSort == sort && store.selectedTopTime == time
                                )
                            }
                        }
                    } label: {
                        sortLabel(sort.title, isSelected: activeSort == sort)
                    }
                } else {
                    Button {
                        apply(sort: sort)
                    } label: {
                        sortLabel(sort.title, isSelected: activeSort == sort)
                    }
                }
            }
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Text(descriptor.name)
                    Image(systemName: "chevron.down")
                }
                .font(.headline)
                Text(sortSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Sort, \(sortSummary)")
    }

    @ViewBuilder
    private func sortLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func apply(sort: PostSort, topTime: TopTime? = nil) {
        Task { await store.applySort(sort, topTime: topTime, for: descriptor) }
    }

    private var displayMenu: some View {
        Menu {
            Picker("Display", selection: Binding(
                get: { dependencies.settings.feedLayout(for: layoutCommunity) },
                set: { dependencies.settings.setFeedLayout($0, for: layoutCommunity) }
            )) {
                Label("Compact", systemImage: "list.bullet").tag(FeedLayout.compact)
                Label("Cards", systemImage: "rectangle").tag(FeedLayout.full)
            }
            Button { router.push(.gallery(descriptor)) } label: {
                Label("Gallery", systemImage: "square.grid.2x2")
            }
            Divider()
            // iPhone gets the clearing action as a tab bar accessory, but the
            // wide and split layouts have no TabView to hang one on.
            Button(action: clearReadPosts) {
                Label("Clear Read Posts", systemImage: "eye.slash")
            }
            .disabled(!store.hasReadPostsInFeed)
            // The setting is the standing preference -- read posts are
            // dropped when the feed next reloads -- and stays a switch
            // because that is what it is.
            Toggle(isOn: Binding(
                get: { dependencies.settings.hideSeenPosts },
                set: { dependencies.settings.hideSeenPosts = $0 }
            )) {
                Label("Hide Read Posts on Refresh", systemImage: "eye.slash.circle")
            }
        } label: {
            Image(systemName: compactRows ? "list.bullet" : "rectangle.grid.1x2")
        }
        .accessibilityLabel("Feed display")
    }

    private var actionsMenu: some View {
        Menu {
            if descriptor.kind == .community {
                Button {
                    router.presentedSheet = .composer(.post, community: descriptor.name)
                } label: {
                    Label("New Post", systemImage: "square.and.pencil")
                }
            }
            Button(action: markVisibleSeen) {
                Label("Mark Visible Posts Read", systemImage: "eye")
            }
            ShareLink(item: URL(string: "https://www.reddit.com")!) {
                Label("Share Feed", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Feed actions")
    }

    private func performVote(postID: String, value: Int) {
        guard dependencies.accounts.selectedAccount?.health == .healthy,
              let accountID = dependencies.accounts.selectedAccountID else {
            showingLogin = true
            return
        }
        let token = dependencies.accounts.token(for: accountID)
        Task {
            do {
                try await store.performVote(postID: postID, value: value, accountID: accountID)
            } catch let error as RedditClientError where error == .authenticationRequired {
                guard dependencies.accounts.isCurrent(token) else { return }
                await dependencies.accounts.markNeedsLogin(accountID)
            } catch {
                // The store has already restored the previous local value.
            }
        }
    }

    private func open(_ post: PostCardModel) {
        store.setSeen(true, postID: post.id)
        if let onSelectPost {
            onSelectPost(post)
        } else {
            router.push(.post(post))
        }
    }

    /// Marks everything above the topmost visible row as read. See
    /// `FeedScrollReadRule` for why this is recomputed rather than tracked.
    private func markPostsScrolledPast() {
        guard dependencies.settings.autoMarkSeenWhileScrolling else {
            markScheduler.cancelAll()
            return
        }
        let read = FeedScrollReadRule.postsScrolledPast(
            in: visiblePosts,
            visibleIDs: scrollTracker.effectiveVisibleIDs,
            seenIDs: store.seenPostIDs,
            isScrolledFromTop: scrollTracker.isScrolledFromTop
        )
        // Not marked here: held for a moment, so scrolling back takes it
        // back. An empty list cancels everything pending, which is what
        // scrolling to the top means.
        markScheduler.schedule(read) { store.setSeen(true, postID: $0) }
    }

    private func markVisibleSeen() {
        store.setSeen(true, postIDs: visiblePosts.map(\.id), keepingVisible: false)
    }

    /// The wide and split layouts reach this through the menu rather than the
    /// tab bar accessory, so it does what the accessory does: take the read
    /// posts out of the feed, and page on if that leaves nothing to show.
    private func clearReadPosts() {
        store.clearReadPostsFromFeed()
        Task { await store.loadMorePostsUntilSomethingIsVisible(for: descriptor) }
    }

    private func preloadMedia(after index: Int) {
        let posts = visiblePosts
        guard posts.indices.contains(index) else { return }
        let end = min(posts.count, index + mediaPreloadDistance + 1)
        mediaPreloader.preload(posts: posts[index..<end], compact: compactRows)
    }

    private func beginCrosspost(_ post: PostCardModel) {
        guard dependencies.accounts.selectedAccount?.health == .healthy else {
            showingLogin = true
            return
        }
        crosspostPost = post
    }

    private func performSave(postID: String) {
        guard dependencies.accounts.selectedAccount?.health == .healthy,
              let accountID = dependencies.accounts.selectedAccountID else {
            showingLogin = true
            return
        }
        let token = dependencies.accounts.token(for: accountID)
        Task {
            do {
                try await store.performSave(postID: postID, accountID: accountID)
            } catch let error as RedditClientError where error == .authenticationRequired {
                guard dependencies.accounts.isCurrent(token) else { return }
                await dependencies.accounts.markNeedsLogin(accountID)
            } catch {
                // The store has already restored the previous local value.
            }
        }
    }
}

@MainActor
struct CommunityView: View {
    let name: String
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    var onSelectPost: ((PostCardModel) -> Void)? = nil

    private var community: CommunityCardModel? { store.communities.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    var body: some View {
        FeedView(
            descriptor: FeedDescriptorModel(kind: .community, name: name),
            store: store,
            router: router,
            onSelectPost: onSelectPost
        )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let community {
                        Button { store.toggleSubscribe(communityID: community.id) } label: {
                            Label(community.isSubscribed ? "Joined" : "Join", systemImage: community.isSubscribed ? "checkmark" : "person.badge.plus")
                        }
                    }
                }
            }
            .task(id: IDNormalization.community(name)) {
                await store.recordCommunityVisit(name)
            }
    }
}

@MainActor
struct QuickCommunitySearchView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    var onSelectFeed: ((FeedDescriptorModel) -> Void)? = nil
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(store.communities.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { community in
                Button {
                    dismiss()
                    let descriptor = FeedDescriptorModel(kind: .community, name: community.name)
                    if let onSelectFeed {
                        onSelectFeed(descriptor)
                    } else {
                        router.push(.community(community.name))
                    }
                } label: {
                    OctonautCommunityRow(
                        community: community,
                        showsIcon: dependencies.settings.showCommunityIcons)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Quick Community Search")
            .searchable(text: $query, prompt: "Community name")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

@MainActor
struct QuickAccountSwitcherView: View {
    let store: OctonautFeatureStore
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(dependencies.accounts.accounts) { account in
                Button {
                    Task { try? await dependencies.accounts.select(account.id) }
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.fill").font(.title2)
                        Text(account.username)
                        Spacer()
                        if dependencies.accounts.selectedAccountID == account.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Switch Account")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct FeedLoadIdentity: Hashable {
    let descriptor: FeedDescriptorModel
    let account: String
}

@MainActor
private struct CustomFeedEditorView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State var feed: CustomFeed
    let communities: [CommunityCardModel]
    let onSave: (CustomFeed) -> Void
    @State private var communityInput = ""
    @State private var query = ""
    @State private var addedCommunities: Set<String> = []
    @State private var inputError: String?

    private var choices: [String] {
        Set(communities.map { $0.name.lowercased() })
            .union(feed.communities).union(addedCommunities)
            .filter { query.isEmpty || $0.localizedStandardContains(query) }.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Feed name") {
                    TextField("Name", text: $feed.name)
                        .accessibilityLabel("Feed name")
                }
                Section {
                    HStack {
                        TextField("Community name, e.g. r/swift", text: $communityInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addCommunity)
                        Button("Add", action: addCommunity)
                            .disabled(communityInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let inputError { Text(inputError).foregroundStyle(.red) }
                } header: {
                    Text("Add a community")
                } footer: {
                    Text("You don’t need to subscribe to add a community to this feed.")
                }
                Section {
                    ForEach(choices, id: \.self) { name in
                        Toggle("r/\(name)", isOn: Binding(
                            get: { feed.communities.contains(name) },
                            set: { selected in
                                feed.communities.removeAll { $0 == name }
                                if selected { feed.communities.append(name) }
                            }
                        ))
                    }
                } header: {
                    Text("Communities · \(feed.communities.count) selected")
                } footer: {
                    Text(dependencies.settings.customFeedSyncStatus)
                }
            }
            .navigationTitle("Custom Feed")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Find a community")
            .onAppear { addedCommunities.formUnion(feed.communities) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        feed.name = feed.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        feed.communities.sort()
                        onSave(feed)
                        dismiss()
                    }
                    .disabled(feed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || feed.communities.isEmpty || !communityInput.isEmpty)
                }
            }
        }
    }

    private func addCommunity() {
        guard let name = CustomFeed.communityName(communityInput) else {
            inputError = "Use a community name with letters, numbers or underscores, up to 21 characters."
            return
        }
        addedCommunities.insert(name)
        if !feed.communities.contains(name) { feed.communities.append(name) }
        communityInput = ""
        inputError = nil
    }
}
