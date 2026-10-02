import SwiftUI
import UIKit

@MainActor
struct PostDetailView: View {
    let post: PostCardModel
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @Environment(AppDependencies.self) private var dependencies
    @State private var commentSort = "Best"
    @State private var composerTarget: CommentComposerTarget?
    @State private var isMediaViewerPresented = false
    @State private var selectedMediaPage = 0
    @State private var showingLogin = false
    @State private var crosspostPost: PostCardModel?

    private var currentPost: PostCardModel {
        guard let detailPost = store.detailPost, detailPost.id == post.id else { return post }
        return detailPost
    }

    private var flattenedComments: [CommentCardModel] {
        func flatten(_ comments: [CommentCardModel]) -> [CommentCardModel] {
            comments.flatMap { comment in
                guard !comment.isCollapsed else { return [comment] }
                return [comment] + flatten(comment.children)
            }
        }
        return flatten(store.comments)
    }

    private var summaryComments: [CommentSummaryInput.Comment] {
        func flatten(_ values: [CommentCardModel]) -> [CommentSummaryInput.Comment] {
            values.flatMap { value in
                let current =
                    value.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? [] : [CommentSummaryInput.Comment(id: value.id, text: value.body)]
                return current + flatten(value.children)
            }
        }
        return flatten(store.comments)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                OctonautPostRow(
                    post: currentPost,
                    bodyLineLimit: nil,
                    showsFlair: dependencies.settings.showPostFlair,
                    onVote: { performVote(postID: currentPost.id, value: $0) },
                    onSave: { performSave(postID: currentPost.id) },
                    onSeen: { store.markSeen(postID: currentPost.id) },
                    onMedia: { page in
                        selectedMediaPage = page
                        isMediaViewerPresented = true
                    },
                    onCommunityOpen: { router.push(.community(currentPost.community)) },
                    communityOpenAccessibilityHint: "Opens the subreddit"
                )
                .padding(.top, 4)

                if store.detailState == .loading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading comments…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
                } else if case .failed(let message) = store.detailState {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Comments could not be loaded").font(.subheadline.weight(.semibold))
                            Text(message).font(.caption).foregroundStyle(.secondary)
                            Button("Retry") {
                                Task { await store.loadPostDetail(for: currentPost, sort: commentSort, forceRefresh: true) }
                            }
                            .font(.caption.weight(.semibold))
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10)
                    )
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                if dependencies.settings.showPostSummaries, postSummaryEligible {
                    SummaryCardView(
                        title: "Post Summary",
                        input: .post(
                            PostSummaryInput(id: currentPost.id, title: currentPost.title, body: currentPost.body)
                        ),
                        intelligence: dependencies.intelligence,
                        cache: dependencies.summaryCache,
                        modelFamily: dependencies.summaryCacheModelFamily,
                        automatic: dependencies.settings.automaticVisibleSummaries,
                        useFallback: dependencies.settings.keyExcerptsFallback
                    )
                }
                if dependencies.settings.showCommentSummaries,
                   store.detailState == .loaded {
                    let comments = summaryComments
                    if SummaryEligibility.comments(comments) {
                        SummaryCardView(
                            title: "Comments Summary",
                            input: .comments(
                                CommentSummaryInput(postID: currentPost.id, comments: comments)
                            ),
                            intelligence: dependencies.intelligence,
                            cache: dependencies.summaryCache,
                            modelFamily: dependencies.summaryCacheModelFamily,
                            automatic: dependencies.settings.automaticCommentSummaries,
                            useFallback: dependencies.settings.keyExcerptsFallback
                        )
                    }
                }

                HStack {
                    Text("Comments")
                        .font(.title3.weight(.bold))
                    Spacer()
                    Button("Comment", systemImage: "square.and.pencil") {
                        beginReply(to: currentPost.fullname)
                    }
                    .font(.caption.weight(.semibold))
                    Menu {
                        ForEach(["Best", "New", "Top", "Controversial", "Old"], id: \.self) { value in
                            Button {
                                commentSort = value
                            } label: {
                                if value == commentSort {
                                    Label(value, systemImage: "checkmark")
                                } else {
                                    Text(value)
                                }
                            }
                        }
                    } label: {
                        Label(commentSort, systemImage: "arrow.up.arrow.down")
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 4)

                let comments = flattenedComments
                ForEach(comments) { comment in
                    if comment.isMoreNode {
                        moreCommentsRow(comment)
                    } else {
                        OctonautCommentRow(
                            comment: comment,
                            postAuthor: currentPost.author,
                            onCollapse: {
                                withAnimation(.snappy(duration: 0.2)) {
                                    store.toggleComment(id: comment.id)
                                }
                            }, onVote: { performCommentVote(commentID: comment.id, value: $0) },
                            onReply: {
                                beginReply(to: IDNormalization.fullname(comment.id, kind: "t1"))
                            })
                    }
                }
                if comments.isEmpty {
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "No comments", systemImage: "bubble.left.and.bubble.right",
                            description: Text("There are no comments to show.")
                        )
                        Button("Add the first comment") {
                            beginReply(to: currentPost.fullname)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Post")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        store.markSeen(postID: currentPost.id)
                    } label: {
                        Label(currentPost.isSeen ? "Mark Unseen" : "Mark Seen", systemImage: "eye")
                    }
                    if currentPost.hasMedia {
                        Button {
                            isMediaViewerPresented = true
                        } label: {
                            Label("Open Media", systemImage: "photo")
                        }
                    }
                    Button {
                        UIApplication.shared.open(currentPost.shareURL)
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    ShareLink(item: currentPost.shareURL) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        beginCrosspost()
                    } label: {
                        Label("Crosspost", systemImage: "arrow.triangle.branch")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $composerTarget) { target in
            ComposerView(kind: .comment, store: store, targetID: target.id) {
                Task {
                    await store.loadPostDetail(for: target.post, sort: commentSort, forceRefresh: true)
                }
            }
        }
        .sheet(isPresented: $showingLogin) {
            RedditLoginView(accounts: dependencies.accounts)
        }
        .sheet(item: $crosspostPost) { post in
            CrosspostComposerView(post: post)
        }
        .fullScreenCover(isPresented: $isMediaViewerPresented) {
            OctonautMediaViewer(
                post: currentPost, initialPage: selectedMediaPage,
                onSave: { performSave(postID: currentPost.id) },
                onOpenPost: { dismissMediaViewerAndStay() })
        }
        .task(id: "\(post.id):\(commentSort):\(store.accountContextKey)") {
            await store.loadPostDetail(for: post, sort: commentSort)
        }
        .task(id: post.id) {
            await store.recordPostViewed()
        }
    }

    private var postSummaryEligible: Bool {
        SummaryEligibility.post(title: currentPost.title, body: currentPost.body)
    }

    private func beginCrosspost() {
        guard dependencies.accounts.selectedAccount?.health == .healthy else {
            showingLogin = true
            return
        }
        crosspostPost = currentPost
    }

    @ViewBuilder
    private func moreCommentsRow(_ comment: CommentCardModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "ellipsis.bubble")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Load \(comment.moreCount ?? 0) more comments")
                    .font(.subheadline.weight(.semibold))
                if store.moreFailedIDs.contains(comment.id) {
                    Text("The child comments could not be loaded. Try again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if store.moreLoadingIDs.contains(comment.id) {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, min(CGFloat(comment.depth) * 8, 48) + 12)
        .padding(.trailing)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await store.loadMoreComments(comment.id, for: currentPost, sort: commentSort) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Load \(comment.moreCount ?? 0) more comments")
    }

    private func dismissMediaViewerAndStay() {
        isMediaViewerPresented = false
    }

    private func performVote(postID: String, value: Int) {
        guard dependencies.accounts.selectedAccount?.health == .healthy,
            let accountID = dependencies.accounts.selectedAccountID
        else {
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

    private func performSave(postID: String) {
        guard dependencies.accounts.selectedAccount?.health == .healthy,
            let accountID = dependencies.accounts.selectedAccountID
        else {
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

    private func beginReply(to targetID: String) {
        guard dependencies.accounts.selectedAccount?.health == .healthy else {
            showingLogin = true
            return
        }
        composerTarget = CommentComposerTarget(id: targetID, post: currentPost)
    }

    private func performCommentVote(commentID: String, value: Int) {
        guard dependencies.accounts.selectedAccount?.health == .healthy,
            let accountID = dependencies.accounts.selectedAccountID
        else {
            showingLogin = true
            return
        }
        let token = dependencies.accounts.token(for: accountID)
        Task {
            do {
                try await store.performCommentVote(id: commentID, value: value, accountID: accountID)
            } catch let error as RedditClientError where error == .authenticationRequired {
                guard dependencies.accounts.isCurrent(token) else { return }
                await dependencies.accounts.markNeedsLogin(accountID)
            } catch {}
        }
    }

}

private struct CommentComposerTarget: Identifiable {
    let id: String
    let post: PostCardModel
}

@MainActor
struct GalleryView: View {
    let source: GallerySource
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter

    @Environment(AppDependencies.self) private var dependencies
    @State private var selectedItem: GalleryMediaItem?
    /// A per-visit override of the blur preferences, so the toolbar button can
    /// unblur this grid without changing the saved setting.
    @State private var revealsSensitiveMedia = false
    @State private var networkStatus = OctonautNetworkStatus.shared
    @State private var containerWidth: CGFloat = 0
    /// The laid-out columns, rebuilt only when something that can change them
    /// changes -- not on every body evaluation.
    @State private var columns: [[GalleryMediaItem]] = []
    /// The column each tile was given, kept so it keeps it.
    @State private var columnByItem: [String: Int] = [:]
    @State private var laidOutColumnCount = 0
    /// A profile section keeps its own rows: Saved and Upvoted are fetched
    /// through the user endpoint and never land in `store.posts`.
    @State private var sectionPosts: [PostCardModel] = []
    @State private var sectionNextPage: String?
    @State private var sectionState: OctonautLoadState = .idle
    @State private var isLoadingMore = false

    private var blursSensitiveMedia: Bool {
        dependencies.settings.blurNSFWMedia || dependencies.settings.blurSpoilers
    }

    private var items: [GalleryMediaItem] {
        switch source {
        case .feed(let descriptor):
            GalleryMediaItem.items(from: store.posts.filter {
                descriptor.kind != .community
                    || $0.community.caseInsensitiveCompare(descriptor.name) == .orderedSame
            })
        case .userSection:
            GalleryMediaItem.items(from: sectionPosts)
        }
    }

    private var loadState: OctonautLoadState {
        switch source {
        case .feed: store.feedState
        case .userSection: sectionState
        }
    }

    private var nextPageCursor: String? {
        switch source {
        case .feed(let descriptor): store.galleryPageCursor(for: descriptor)
        case .userSection: sectionNextPage
        }
    }

    private func load(forceRefresh: Bool) async {
        switch source {
        case .feed(let descriptor):
            await store.refreshPosts(for: descriptor, forceRefresh: forceRefresh)
        case .userSection(let username, let section):
            if sectionPosts.isEmpty { sectionState = .loading }
            do {
                let page = try await store.fetchUserSection(
                    section, username: username, forceRefresh: forceRefresh)
                sectionPosts = page.posts
                sectionNextPage = page.nextPage
                sectionState = page.posts.isEmpty ? .empty : .loaded
            } catch {
                sectionState = .failed(error.localizedDescription)
            }
        }
    }

    private func loadMore() async {
        switch source {
        case .feed(let descriptor):
            await store.loadMorePosts(for: descriptor)
        case .userSection(let username, let section):
            guard let after = sectionNextPage, !isLoadingMore else { return }
            isLoadingMore = true
            defer { isLoadingMore = false }
            do {
                let page = try await store.fetchUserSection(
                    section, username: username, after: after)
                // The cursor can have moved on while this was in flight.
                guard !Task.isCancelled, sectionNextPage == after else { return }
                let known = Set(sectionPosts.map(\.id))
                sectionPosts.append(contentsOf: page.posts.filter { !known.contains($0.id) })
                sectionNextPage = page.nextPage
            } catch is CancellationError {
                // Emphatically not the end of the listing.
                //
                // This is triggered from a `.task(id:)` on the row below the
                // grid, and that row leaves the lazy stack's realised range the
                // moment a page is appended above it -- so SwiftUI cancels the
                // task as a matter of course. Treating that as a failure and
                // dropping the cursor stopped Saved and Upvoted dead after the
                // first page, under a message saying there was nothing more.
                return
            } catch {
                // A real failure: keep what arrived and stop paging until the
                // reader pulls to refresh.
                sectionNextPage = nil
            }
        }
    }

    /// Whether video tiles may play where they sit, which is the reader's
    /// autoplay setting answered for this connection -- the same question the
    /// feed rows ask.
    private var autoplaysInPlace: Bool {
        dependencies.settings.autoplayVideo.shouldAutoplay(
            isConnectedViaWiFi: networkStatus.isConnectedViaWiFi)
    }

    private var columnCount: Int {
        let minimumTileWidth: CGFloat = 170
        guard containerWidth > 0 else { return 2 }
        return max(2, Int((containerWidth - Self.gridPadding + Self.tileSpacing)
            / (minimumTileWidth + Self.tileSpacing)))
    }

    private static let tileSpacing: CGFloat = 4
    private static let gridPadding: CGFloat = 8

    /// Places any tile that does not yet have a column, and leaves every tile
    /// that does exactly where it is.
    ///
    /// Two separate things were wrong before. The columns were recomputed from
    /// scratch inside `body`, so a tile already on screen could be handed a
    /// different column by the next pass -- not resized, *relocated*, taking
    /// everything below it in both columns with it. And the inputs it was
    /// recomputed from all move while the reader is looking: the list grows
    /// with pagination, the width arrives late, and ratios firm up as images
    /// are measured. Logging it on device showed 13 to 24 tiles changing
    /// column on every single pass.
    ///
    /// So placement is a decision made once per tile and then kept. New tiles
    /// are still placed shortest-column-first, against heights accumulated
    /// from the tiles already there, which is what keeps the columns level.
    private func rebuildColumns() {
        let count = columnCount
        guard containerWidth > 0, count > 0 else { return }
        let tileWidth = max(
            1,
            (containerWidth - Self.gridPadding - Self.tileSpacing * CGFloat(count - 1)) / CGFloat(count))

        var assignment = columnByItem
        // A different number of columns is a different layout; nothing can be
        // carried over.
        if count != laidOutColumnCount { assignment.removeAll() }

        var built = Array(repeating: [GalleryMediaItem](), count: count)
        var heights = Array(repeating: CGFloat(0), count: count)
        for item in items {
            let column: Int
            if let existing = assignment[item.id], existing < count {
                column = existing
            } else {
                let shortest = heights.min() ?? 0
                column = heights.indices.first { heights[$0] <= shortest + Self.tileSpacing } ?? 0
                assignment[item.id] = column
            }
            built[column].append(item)
            heights[column] += tileWidth / max(item.aspectRatio, 0.05) + Self.tileSpacing
        }
        columnByItem = assignment
        laidOutColumnCount = count
        columns = built
    }

    /// Changes when the grid genuinely has different tiles to show. Ratios
    /// firming up deliberately do not appear here: a tile that learns its
    /// shape should resize where it stands, never move.
    private var itemsKey: String {
        "\(items.count):\(items.first?.id ?? "")"
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack(alignment: .top, spacing: Self.tileSpacing) {
                    ForEach(columns.indices, id: \.self) { column in
                        LazyVStack(spacing: Self.tileSpacing) {
                            ForEach(columns[column]) { item in
                                GalleryMediaTile(
                                    item: item,
                                    blursNSFW: dependencies.settings.blurNSFWMedia && !revealsSensitiveMedia,
                                    blursSpoilers: dependencies.settings.blurSpoilers && !revealsSensitiveMedia,
                                    autoplays: autoplaysInPlace
                                ) { selectedItem = item }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, Self.gridPadding / 2)

                if case .failed(let message) = loadState {
                    VStack(spacing: 12) {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                        Button("Try again") {
                            Task { await load(forceRefresh: true) }
                        }
                    }
                    .padding()
                } else if loadState == .loading || loadState == .idle {
                    ProgressView("Loading gallery").padding()
                } else if let cursor = nextPageCursor {
                    ProgressView("Loading more")
                        .padding()
                        .task(id: cursor) { await loadMore() }
                } else if items.isEmpty {
                    ContentUnavailableView("No media posts", systemImage: "photo.on.rectangle.angled",
                        description: Text("This feed has no displayable images or videos."))
                        .padding(.top, 60)
                } else {
                    Text("You've reached the end.")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard width != containerWidth else { return }
            containerWidth = width
            rebuildColumns()
        }
        .onChange(of: itemsKey) { _, _ in rebuildColumns() }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if blursSensitiveMedia {
                    Button {
                        revealsSensitiveMedia.toggle()
                    } label: {
                        Label("Sensitive media blur", systemImage: revealsSensitiveMedia ? "eye" : "eye.slash")
                    }
                    .accessibilityLabel("Sensitive media blur")
                    .accessibilityValue(revealsSensitiveMedia ? "Off" : "On")
                    .accessibilityHint(revealsSensitiveMedia ? "Blur sensitive images" : "Show sensitive images")
                }
            }
        }
        .task { await load(forceRefresh: false) }
        .refreshable { await load(forceRefresh: true) }
        .fullScreenCover(item: $selectedItem) { item in
            OctonautMediaViewer(post: item.post, initialPage: item.page, initiallyRevealed: revealsSensitiveMedia, onOpenPost: {
                selectedItem = nil
                router.push(.post(item.post))
            })
        }
    }
}
