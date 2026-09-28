import Foundation
import Observation

enum SearchLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
}

@MainActor
@Observable
final class SearchFeatureModel {
    @ObservationIgnored private let reddit: any RedditClient
    @ObservationIgnored private var postsAfter: String?
    @ObservationIgnored private var communitiesAfter: String?
    @ObservationIgnored private var requestGeneration = 0

    var posts: [PostCardModel] = []
    var communities: [CommunityCardModel] = []
    var trendingCommunities: [CommunityCardModel] = []
    var users: [UserProfile] = []
    var state: SearchLoadState = .idle
    var trendingState: SearchLoadState = .idle
    var activeScope: FeatureSearchScope = .posts
    var activeQuery = ""
    var paginationError: String?

    /// The signed-in account, kept current by the view.
    ///
    /// Search used to send every request anonymously. Reddit answers an
    /// anonymous request for these listings with a 403 and an HTML block
    /// page, so Discover and every search scope failed for a reader who was
    /// signed in and whose feed was loading perfectly well.
    @ObservationIgnored var accountID: AccountID?

    init(reddit: any RedditClient, accountID: AccountID? = nil) {
        self.reddit = reddit
        self.accountID = accountID
    }

    func loadTrendingCommunities(forceRefresh: Bool = false) async {
        if !forceRefresh, trendingState == .loading || trendingState == .loaded { return }
        trendingState = .loading
        do {
            let listing = try await reddit.trendingCommunities(
                limit: 25,
                account: accountID,
                // A reader-initiated retry bypasses both the response cache
                // and the client's anonymous back-off: they are watching, and
                // the block it is waiting out may already have lifted.
                responseCachePolicy: forceRefresh ? .reloadIgnoringCache : .useCache
            )
            guard !Task.isCancelled else { return }
            trendingCommunities = listing.items.map(CommunityCardModel.init)
            paginationError = nil
            trendingState = trendingCommunities.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            trendingState = trendingCommunities.isEmpty ? .idle : .loaded
            return
        } catch {
            // A list already on screen is better than an error where the list
            // was. The failure still reaches the reader through the retry
            // affordance, without throwing away what they were reading.
            guard trendingCommunities.isEmpty else {
                trendingState = .loaded
                paginationError = error.localizedDescription
                return
            }
            trendingState = .failed(error.localizedDescription)
        }
    }

    func submit(query: String, scope: FeatureSearchScope) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeQuery = query
        activeScope = scope
        requestGeneration &+= 1
        let generation = requestGeneration
        postsAfter = nil
        communitiesAfter = nil
        paginationError = nil
        guard query.count >= 2 else {
            posts = []
            communities = []
            users = []
            state = query.isEmpty ? .idle : .empty
            return
        }
        state = .loading
        do {
            switch scope {
            case .posts:
                let listing = try await reddit.search(RedditSearchRequest(query: query, sort: .hot), account: accountID)
                guard generation == requestGeneration else { return }
                paginationError = nil
                posts = listing.items.map(PostCardModel.init)
                postsAfter = listing.after
                communities = []
                users = []
                state = posts.isEmpty ? .empty : .loaded
            case .communities:
                let listing = try await reddit.communities(RedditCommunitySearchRequest(query: query), account: accountID)
                guard generation == requestGeneration else { return }
                paginationError = nil
                communities = listing.items.map(CommunityCardModel.init)
                communitiesAfter = listing.after
                posts = []
                users = []
                state = communities.isEmpty ? .empty : .loaded
            case .users:
                let listing = try await reddit.users(RedditUserSearchRequest(query: query), account: accountID)
                guard generation == requestGeneration else { return }
                paginationError = nil
                posts = []
                communities = []
                users = listing.items
                state = users.isEmpty ? .empty : .loaded
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard state == .loaded, activeQuery.count >= 2 else { return }
        let generation = requestGeneration
        do {
            switch activeScope {
            case .posts:
                guard let postsAfter else { return }
                let listing = try await reddit.search(
                    RedditSearchRequest(query: activeQuery, sort: .hot, after: postsAfter),
                    account: accountID
                )
                guard generation == requestGeneration else { return }
                let existing = Set(posts.map(\.id))
                posts.append(contentsOf: listing.items.filter { !existing.contains($0.id) }.map(PostCardModel.init))
                self.postsAfter = listing.after
            case .communities:
                guard let communitiesAfter else { return }
                let listing = try await reddit.communities(
                    RedditCommunitySearchRequest(query: activeQuery, after: communitiesAfter),
                    account: accountID
                )
                guard generation == requestGeneration else { return }
                let existing = Set(communities.map(\.id))
                communities.append(contentsOf: listing.items.filter { !existing.contains($0.id) }.map(CommunityCardModel.init))
                self.communitiesAfter = listing.after
            case .users:
                return
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            paginationError = error.localizedDescription
        }
    }
}
