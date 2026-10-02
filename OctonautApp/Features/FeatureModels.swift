import Foundation
import Observation

extension PostMedia {
    fileprivate var thumbnailURL: URL? {
        switch self {
        case .image(_, let thumbnail, _, _, _): return thumbnail
        case .video(_, _, let thumbnail, _, _, _): return thumbnail
        case .gallery(let items): return items.first?.thumbnailURL
        case .link(_, let metadata): return metadata?.imageURL
        case .none, .poll, .unsupported: return nil
        }
    }

    /// Each gallery image's aspect ratio, positionally matched to
        /// `galleryURLs`.
    ///
    /// `media_metadata` publishes `s.x`/`s.y` per image and the decoder has
    /// always read them into `GalleryItem`, but only the URLs were passed on.
    /// So every page of a gallery reached the grid shapeless and was laid out
    /// at the default until its bytes arrived -- which is most of what was
    /// moving tiles between columns.
    fileprivate var galleryAspectRatios: [CGFloat?] {
        if case .gallery(let items) = self {
            return items.map { item in
                guard let width = item.width, let height = item.height,
                      width > 0, height > 0 else { return nil }
                return CGFloat(width) / CGFloat(height)
            }
        }
        return []
    }

    fileprivate var galleryURLs: [URL] {
        if case .gallery(let items) = self { return items.map(\.url) }
        if let primaryURL { return [primaryURL] }
        return []
    }

    /// Reddit's smaller copies, one list per entry of `galleryURLs` and in the
    /// same order, so a page index addresses both.
    fileprivate var imageVariants: [[ImageVariant]] {
        switch self {
        case .gallery(let items): return items.map(\.variants)
        case .image(_, _, _, _, let variants): return [variants]
        case .none, .video, .link, .poll, .unsupported: return []
        }
    }

    fileprivate var audioURL: URL? {
        if case .video(_, let audio, _, _, _, _) = self { return audio }
        return nil
    }

    /// The aspect ratio Reddit publishes alongside the media.
    ///
    /// Worth carrying because it removes the only reason a row has to read
    /// the asset before it can lay out, and because an HLS playlist has no
    /// asset tracks to read: `loadTracks(withMediaType: .video)` returns
    /// nothing on one, so measuring it would letterbox every portrait video
    /// into 16:9.
    ///
    /// Images carry dimensions too -- `preview.images[].source` -- and the
    /// decoder has always read them. Reading only the video case here is
    /// what left the gallery grid sizing its tiles from whatever had finished
    /// downloading.
    fileprivate var aspectRatio: CGFloat? {
        let dimensions: (Int?, Int?)
        switch self {
        case .video(_, _, _, _, let width, let height): dimensions = (width, height)
        case .image(_, _, let width, let height, _): dimensions = (width, height)
        default: return nil
        }
        guard let width = dimensions.0, let height = dimensions.1,
              width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }
}

// MARK: - Presentation models

/// These small presentation models are deliberately independent from Reddit DTOs.
/// The Domain layer can map its Post/Comment/Community values into them, while
/// previews and the initial app shell remain usable without a network client.
struct PostCardModel: Identifiable, Hashable, Sendable {
    let id: String
    var community: String
    var author: String
    var authorFlair: Flair?
    var title: String
    var body: String {
        didSet {
            bodyPreview = body.isEmpty ? "" : RedditPostMarkdown.previewText(from: body)
        }
    }
    var bodyPreview: String
    var flair: Flair?
    var score: Int
    var comments: Int
    var age: String
    var vote: Int
    var isSaved: Bool
    var isNSFW: Bool
    var isSpoiler: Bool
    var isSticky: Bool
    var isVideo: Bool
    var hasMedia: Bool
    var mediaTitle: String
    var shareURL: URL
    var mediaURL: URL?
    var thumbnailURL: URL?
    var mediaKind: String
    var galleryURLs: [URL]
    /// Positionally matched to `galleryURLs`; empty for non-gallery posts.
    var galleryAspectRatios: [CGFloat?] = []
    var audioURL: URL?
    /// Reddit's own dimensions for the video, when it publishes them.
    var mediaAspectRatio: CGFloat?
    /// Reddit's smaller copies of each image, parallel to `galleryURLs`.
    ///
    /// `galleryURLs` stays what it always was -- the full-size images, which
    /// is what the viewer, a save and a share all want. These are what the
    /// feed and the gallery grid should be drawing from instead, and are
    /// empty for a post Reddit published no ladder for.
    var imageVariants: [[ImageVariant]] = []

#if DEBUG
    static let screenshotCat = PostCardModel(
        id: "t3_screenshot-cat", community: "aww", author: "sunny_window",
        title: "Found the warmest spot in the house",
        body: "", score: 2_418, comments: 126, age: "2h", vote: 0,
        isSaved: false, isNSFW: false, isSpoiler: false,
        isSticky: false, isVideo: false, hasMedia: true, mediaTitle: "Image",
        shareURL: URL(string: "https://www.reddit.com/r/aww/comments/screenshotcat")!,
        mediaURL: URL(string: "octonaut-screenshot://cat")!,
        mediaKind: "image"
    )

    static let screenshotCoast = PostCardModel(
        id: "t3_screenshot-coast", community: "photography", author: "trailwalker",
        title: "A quiet walk above the coast",
        body: "", score: 1_306, comments: 84, age: "4h", vote: 0,
        isSaved: true, isNSFW: false, isSpoiler: false,
        isSticky: false, isVideo: false, hasMedia: true, mediaTitle: "Image",
        shareURL: URL(string: "https://www.reddit.com/r/photography/comments/screenshotcoast")!,
        mediaURL: URL(string: "octonaut-screenshot://coast")!,
        mediaKind: "image"
    )

    static let screenshotGallery = PostCardModel(
        id: "t3_screenshot-gallery", community: "photography", author: "trailwalker",
        title: "A sunny afternoon, two favourite views",
        body: "", score: 1_306, comments: 84, age: "4h", vote: 0,
        isSaved: false, isNSFW: false, isSpoiler: false,
        isSticky: false, isVideo: false, hasMedia: true, mediaTitle: "Gallery",
        shareURL: URL(string: "https://www.reddit.com/r/photography/comments/screenshotgallery")!,
        mediaURL: URL(string: "octonaut-screenshot://coast")!,
        mediaKind: "gallery",
        galleryURLs: [URL(string: "octonaut-screenshot://coast")!, URL(string: "octonaut-screenshot://cat")!]
    )
#endif

    var isSensitive: Bool { isNSFW || isSpoiler }

    /// Sensitivity filtered through the two blur preferences. `isSensitive`
    /// stays unconditional so accessibility labels and badges can still
    /// describe the post when blurring is switched off.
    func isSensitive(blurringNSFW: Bool, blurringSpoilers: Bool) -> Bool {
        (isNSFW && blurringNSFW) || (isSpoiler && blurringSpoilers)
    }

    /// Reddit's full-size image for one page of this post.
    ///
    /// What a save, a share and the media viewer on an unmetered connection
    /// all want. A post with a single image is page zero of a gallery of one.
    func fullResolutionImageURL(page: Int = 0) -> URL? {
        if galleryURLs.indices.contains(page) { return galleryURLs[page] }
        return page == 0 ? mediaURL : nil
    }

    /// The image to fetch when it is about to be drawn `points` wide.
    ///
    /// This is REDDIT-MAP-003's "preview resolution close to display pixels,
    /// accounting for scale". A feed card, a compact row's thumbnail and a
    /// gallery tile are three very different sizes, and all three were
    /// fetching the same full-size file.
    ///
    /// Falls back to the full-size URL when Reddit published no ladder for
    /// this image, which is the old behaviour and still correct.
    func imageURL(page: Int = 0, displayWidth points: CGFloat, scale: CGFloat) -> URL? {
        guard let fullResolution = fullResolutionImageURL(page: page) else { return nil }
        guard imageVariants.indices.contains(page) else { return fullResolution }
        let pixels = Int((points * max(scale, 1)).rounded(.up))
        return imageVariants[page].covering(pixels)?.url ?? fullResolution
    }

    /// The image the full-screen viewer should fetch.
    ///
    /// Full resolution on Wi-Fi: opening the viewer is a deliberate act, the
    /// image can be zoomed into, and an unmetered connection is not the place
    /// to be stingy about it.
    ///
    /// On a metered connection Reddit's largest pre-made copy is used instead.
    /// It is around 1080 pixels wide, which still exceeds what the screen can
    /// show unzoomed, and it avoids spending someone's data allowance on an
    /// uploader's untouched original.
    func viewerImageURL(page: Int = 0, isConnectedViaWiFi: Bool) -> URL? {
        guard let fullResolution = fullResolutionImageURL(page: page) else { return nil }
        guard !isConnectedViaWiFi, imageVariants.indices.contains(page) else {
            return fullResolution
        }
        return imageVariants[page].largest?.url ?? fullResolution
    }

    var fullname: String { IDNormalization.fullname(id, kind: "t3") }
    var prefersMediaFirstPresentation: Bool {
        let mediaLedKinds = ["image", "gallery", "video", "gif", "embeddedVideo"]
        let visibleBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasMedia
            && mediaLedKinds.contains(mediaKind)
            && (mediaURL != nil || !galleryURLs.isEmpty)
            && visibleBody.count <= 280
            && visibleBody.components(separatedBy: .newlines).count <= 3
    }

    init(
        id: String,
        community: String,
        author: String,
        authorFlair: Flair? = nil,
        title: String,
        body: String,
        flair: Flair? = nil,
        score: Int,
        comments: Int,
        age: String,
        vote: Int,
        isSaved: Bool,
        isNSFW: Bool,
        isSpoiler: Bool,
        isSticky: Bool,
        isVideo: Bool,
        hasMedia: Bool,
        mediaTitle: String,
        shareURL: URL,
        mediaURL: URL? = nil,
        thumbnailURL: URL? = nil,
        mediaKind: String = "none",
        galleryURLs: [URL] = [],
        galleryAspectRatios: [CGFloat?] = [],
        audioURL: URL? = nil,
        mediaAspectRatio: CGFloat? = nil,
        imageVariants: [[ImageVariant]] = [],
        bodyPreview: String? = nil
    ) {
        self.id = id
        self.community = community
        self.author = author
        self.authorFlair = authorFlair
        self.title = title
        self.body = body
        self.flair = flair
        self.score = score
        self.comments = comments
        self.age = age
        self.vote = vote
        self.isSaved = isSaved
        self.isNSFW = isNSFW
        self.isSpoiler = isSpoiler
        self.isSticky = isSticky
        self.isVideo = isVideo
        self.hasMedia = hasMedia
        self.mediaTitle = mediaTitle
        self.shareURL = shareURL
        self.mediaURL = mediaURL
        self.thumbnailURL = thumbnailURL
        self.mediaKind = mediaKind
        self.galleryURLs = galleryURLs
        self.galleryAspectRatios = galleryAspectRatios
        self.audioURL = audioURL
        self.mediaAspectRatio = mediaAspectRatio
        self.imageVariants = imageVariants
        self.bodyPreview = bodyPreview ?? (body.isEmpty ? "" : RedditPostMarkdown.previewText(from: body))
    }

    init(post: Post) {
        self.init(
            id: post.id,
            community: post.community.name,
            author: post.author?.username ?? "",
            authorFlair: post.authorFlair,
            title: post.title,
            body: Self.displayBody(for: post),
            flair: post.flair,
            score: post.score ?? 0,
            comments: post.commentCount,
            age: post.createdAt.formatted(.relative(presentation: .named)),
            vote: post.vote.direction,
            isSaved: post.isSaved,
            isNSFW: post.isNSFW,
            isSpoiler: post.isSpoiler,
            isSticky: post.isSticky,
            isVideo: ["video", "gif", "embeddedVideo"].contains(post.media.kind),
            hasMedia: post.media.kind != "none",
            mediaTitle: post.media.kind.capitalized,
            shareURL: post.permalink,
            mediaURL: post.media.primaryURL,
            thumbnailURL: post.media.thumbnailURL,
            mediaKind: post.media.kind,
            galleryURLs: post.media.galleryURLs,
            galleryAspectRatios: post.media.galleryAspectRatios,
            audioURL: post.media.audioURL,
            mediaAspectRatio: post.media.aspectRatio,
            imageVariants: post.media.imageVariants
        )
    }

    private static func displayBody(for post: Post) -> String {
        guard let body = post.body?.plainText else { return "" }

        if post.media.kind == "embeddedVideo" || post.media.kind == "video",
           let mediaURL = post.media.primaryURL,
           let range = body.range(of: mediaURL.absoluteString) {
            return body.replacingCharacters(in: range, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard post.media.kind == "image", let mediaURL = post.media.primaryURL else {
            return body
        }

        let visibleLines = body.components(separatedBy: .newlines).filter { line in
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
            return URL(string: candidate) != mediaURL
        }
        return visibleLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates the small amount of identity needed to render a detail route
    /// before the Reddit transport has returned the full post. The detail
    /// task replaces this placeholder with the decoded post when available.
    init(deepLinkURL: URL) {
        let components = deepLinkURL.pathComponents
        let commentsIndex = components.firstIndex {
            $0.caseInsensitiveCompare("comments") == .orderedSame
        }
        let id =
            commentsIndex.flatMap { index in
                components.indices.contains(index + 1) ? components[index + 1] : nil
            } ?? components.last(where: { $0 != "/" && !$0.isEmpty }) ?? deepLinkURL.absoluteString
        let communityIndex = components.firstIndex { $0.caseInsensitiveCompare("r") == .orderedSame }
        let community =
            communityIndex.flatMap { index in
                components.indices.contains(index + 1) ? components[index + 1] : nil
            } ?? "reddit"

        self.init(
            id: id,
            community: community,
            author: "",
            title: "Loading post…",
            body: "",
            score: 0,
            comments: 0,
            age: "",
            vote: 0,
            isSaved: false,
                        isNSFW: false,
            isSpoiler: false,
            isSticky: false,
            isVideo: false,
            hasMedia: false,
            mediaTitle: "",
            shareURL: deepLinkURL
        )
    }

    static let sample = PostCardModel(
        id: "t3_sample-1",
        community: "apple",
        author: "example_author",
        title: "What small iOS detail makes your day better?",
        body:
            "A place for practical tips, thoughtful discussion, and the little details that make an app feel native.",
        score: 1_284,
        comments: 218,
        age: "3h",
        vote: 1,
        isSaved: false,
                isNSFW: false,
        isSpoiler: false,
        isSticky: false,
        isVideo: false,
        hasMedia: false,
        mediaTitle: "",
        shareURL: URL(string: "https://www.reddit.com/r/apple/comments/sample")!
    )

    static let mediaSample = PostCardModel(
        id: "t3_sample-2",
        community: "iphone",
        author: "pixel_wrangler",
        title: "A quiet desk setup for a focused afternoon",
        body: "",
        score: 864,
        comments: 74,
        age: "5h",
        vote: 0,
        isSaved: true,
                isNSFW: false,
        isSpoiler: false,
        isSticky: false,
        isVideo: false,
        hasMedia: true,
        mediaTitle: "Image preview",
        shareURL: URL(string: "https://www.reddit.com/r/iphone/comments/sample2")!
    )
}

struct CommunityCardModel: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var iconURL: URL?
    var memberCount: Int?
    var isSubscribed: Bool
    var isFavorite: Bool

    init(
        name: String,
        iconURL: URL? = nil,
        memberCount: Int? = nil,
        isSubscribed: Bool = false,
        isFavorite: Bool = false
    ) {
        self.id = name.lowercased()
        self.name = name
        self.iconURL = iconURL
        self.memberCount = memberCount
        self.isSubscribed = isSubscribed
        self.isFavorite = isFavorite
    }

    init(community: Community) {
        self.init(
            name: community.reference.name, iconURL: community.reference.iconURL,
            memberCount: community.subscribers,
            isSubscribed: community.isSubscribed, isFavorite: community.isFavorite)
    }
}

/// One letter's worth of subscribed communities, as the subscriptions list
/// shows them and as the trailing A-Z index points at them.
struct CommunityIndexSection: Identifiable, Hashable, Sendable {
    /// "A" through "Z", or "#" for the names that do not begin with a letter.
    /// Doubles as the section header and the index label, so the strip and the
    /// headers cannot disagree.
    let id: String
    let communities: [CommunityCardModel]

    var title: String { id }
}

actor SubscribedCommunitiesCache {
    static let shared = SubscribedCommunitiesCache()

    struct Value: Sendable {
        let communities: [Community]
        let isFresh: Bool
    }

    private struct Entry: Codable {
        let storedAt: Date
        let communities: [Community]
    }

    private let directoryURL: URL
    private let freshness: TimeInterval = 15 * 60

    init(fileManager: FileManager = .default) {
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = cachesURL.appendingPathComponent("OctonautSubscribedCommunities", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func value(for account: AccountID, now: Date = .now) -> Value? {
        guard let data = try? Data(contentsOf: fileURL(for: account)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        return Value(
            communities: entry.communities,
            isFresh: now.timeIntervalSince(entry.storedAt) < freshness
        )
    }

    func store(_ communities: [Community], for account: AccountID, now: Date = .now) {
        let entry = Entry(storedAt: now, communities: communities)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: account), options: .atomic)
    }

    func remove(for account: AccountID) {
        try? FileManager.default.removeItem(at: fileURL(for: account))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directoryURL)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for account: AccountID) -> URL {
        directoryURL.appendingPathComponent(account.rawValue.uuidString.lowercased()).appendingPathExtension("json")
    }
}

actor UserProfileCache {
    static let shared = UserProfileCache()

    struct Value: Sendable {
        let profile: UserProfile
        let posts: [Post]
        let comments: [UserComment]
        let isFresh: Bool
    }

    private struct Entry: Codable {
        let storedAt: Date
        let profile: UserProfile
        let posts: [Post]
        let comments: [UserComment]
    }

    private let directoryURL: URL
    private let freshness: TimeInterval

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        freshness: TimeInterval = 60 * 60
    ) {
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directoryURL = directoryURL
            ?? cachesURL.appendingPathComponent("OctonautUserProfiles", isDirectory: true)
        self.freshness = freshness
        try? fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
    }

    func value(
        for username: String,
        account: AccountID?,
        now: Date = .now
    ) -> Value? {
        guard let data = try? Data(contentsOf: fileURL(for: username, account: account)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        return Value(
            profile: entry.profile,
            posts: entry.posts,
            comments: entry.comments,
            isFresh: now.timeIntervalSince(entry.storedAt) < freshness
        )
    }

    func store(
        profile: UserProfile,
        posts: [Post],
        comments: [UserComment],
        for username: String,
        account: AccountID?,
        now: Date = .now
    ) {
        let entry = Entry(storedAt: now, profile: profile, posts: posts, comments: comments)
        let scopeDirectory = scopeDirectoryURL(for: account)
        try? FileManager.default.createDirectory(at: scopeDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: username, account: account), options: .atomic)
    }

    func remove(for account: AccountID) {
        try? FileManager.default.removeItem(at: scopeDirectoryURL(for: account))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directoryURL)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for username: String, account: AccountID?) -> URL {
        let normalizedUsername = username.lowercased().map { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
                ? character : "_"
        }
        return scopeDirectoryURL(for: account)
            .appendingPathComponent(String(normalizedUsername))
            .appendingPathExtension("json")
    }

    private func scopeDirectoryURL(for account: AccountID?) -> URL {
        directoryURL.appendingPathComponent(account?.description ?? "anonymous", isDirectory: true)
    }
}

struct CommentCardModel: Identifiable, Hashable, Sendable {
    let id: String
    var author: String
    var authorFlair: Flair?
    var body: String
    var score: Int
    var age: String
    var vote: Int
    var depth: Int
    var isModerator: Bool
    var isCollapsed: Bool
    var children: [CommentCardModel]
    var isMoreNode: Bool
    var isDeleted: Bool
    var moreCount: Int?
    var moreFailed: Bool
    var moreParentFullname: String?
    var moreChildIDs: [String]

    func isOriginalPoster(postAuthor: String) -> Bool {
        guard !author.isEmpty, !postAuthor.isEmpty else { return false }
        return author.caseInsensitiveCompare(postAuthor) == .orderedSame
    }

    init(
        id: String,
        author: String,
        authorFlair: Flair? = nil,
        body: String,
        score: Int,
        age: String,
        vote: Int,
        depth: Int,
        isModerator: Bool,
        isCollapsed: Bool,
        children: [CommentCardModel],
        isMoreNode: Bool = false,
        isDeleted: Bool = false,
        moreCount: Int? = nil,
        moreFailed: Bool = false,
        moreParentFullname: String? = nil,
        moreChildIDs: [String] = []
    ) {
        self.id = id
        self.author = author
        self.authorFlair = authorFlair
        self.body = body
        self.score = score
        self.age = age
        self.vote = vote
        self.depth = depth
        self.isModerator = isModerator
        self.isCollapsed = isCollapsed
        self.children = children
        self.isMoreNode = isMoreNode
        self.isDeleted = isDeleted
        self.moreCount = moreCount
        self.moreFailed = moreFailed
        self.moreParentFullname = moreParentFullname
        self.moreChildIDs = moreChildIDs
    }

    init(comment: CommentNode, depth: Int = 0, isCollapsed: Bool = false) {
        self.init(
            id: comment.id,
            author: comment.author?.username ?? "",
            authorFlair: comment.authorFlair,
            body: comment.body?.plainText ?? "",
            score: comment.score ?? 0,
            age: comment.createdAt.formatted(.relative(presentation: .named)),
            vote: comment.vote.direction,
            depth: depth,
            isModerator: comment.isDistinguished,
            isCollapsed: isCollapsed,
            children: comment.children.map { child in
                switch child {
                case .comment(let node): return CommentCardModel(comment: node, depth: depth + 1)
                case .more(let more): return CommentCardModel.more(more, depth: depth + 1)
                case .deleted(let deleted): return CommentCardModel.deleted(deleted, depth: depth + 1)
                }
            }
        )
    }

    static func more(_ node: MoreCommentsNode, depth: Int) -> CommentCardModel {
        CommentCardModel(
            id: node.id, author: "", body: "", score: 0, age: "", vote: 0, depth: depth,
            isModerator: false, isCollapsed: false, children: [], isMoreNode: true,
            moreCount: node.count ?? node.childIDs.count,
            moreParentFullname: node.parentFullname,
            moreChildIDs: node.childIDs)
    }

    static func deleted(_ node: DeletedCommentNode, depth: Int) -> CommentCardModel {
        CommentCardModel(
            id: node.id, author: "", body: node.reason.isEmpty ? "[deleted]" : node.reason, score: 0,
            age: "", vote: 0, depth: depth, isModerator: false, isCollapsed: false, children: [],
            isDeleted: true)
    }

    static let samples: [CommentCardModel] = [
        CommentCardModel(
            id: "t1_comment-1", author: "swift_reader",
            body:
                "The little haptic when a copy action succeeds is one of my favourites. It is quick and never gets in the way.",
            score: 523, age: "2h", vote: 1, depth: 0, isModerator: false, isCollapsed: false,
            children: [
                CommentCardModel(
                    id: "t1_comment-1a", author: "native_by_design",
                    body: "Good haptics are almost invisible until an app leaves them out.", score: 83,
                    age: "1h", vote: 0, depth: 1, isModerator: false, isCollapsed: false, children: [])
            ]),
        CommentCardModel(
            id: "t1_comment-2", author: "AutoModerator",
            body: "This is an automated message. Please read the community rules before participating.",
            score: 1, age: "5h", vote: 0, depth: 0, isModerator: true, isCollapsed: true, children: []),
        CommentCardModel(
            id: "t1_comment-3", author: "paperback",
            body:
                "For me it is being able to keep a draft around when I leave a sheet. Small, but it makes reading and replying feel connected.",
            score: 271, age: "4h", vote: 0, depth: 0, isModerator: false, isCollapsed: false, children: []
        ),
    ]
}

struct UserCommentCardModel: Identifiable, Hashable, Sendable {
    let id: String
    var author: String
    var body: String
    var score: Int
    var age: String
    var vote: Int
    var postTitle: String
    var postURL: URL?
    var community: String

    init(comment: UserComment) {
        id = comment.id
        author = comment.author?.username ?? "[deleted]"
        body = comment.body?.plainText ?? "[deleted]"
        score = comment.score ?? 0
        age = comment.createdAt.formatted(.relative(presentation: .named))
        vote = comment.vote.direction
        postTitle = comment.postTitle ?? "Reddit post"
        postURL = comment.postPermalink
        community = comment.community?.name ?? "reddit"
    }
}

struct InboxCardModel: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case reply, mention, message }
    let id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var preview: String
    var author: String
    var age: String
    var score: Int?
    var isUnread: Bool
    var postURL: URL? = nil
}

struct AccountCardModel: Identifiable, Hashable, Sendable {
    let id: String
    var username: String
    var accountAge: String
    var postKarma: Int
    var commentKarma: Int
    var isActive: Bool
    var needsLogin: Bool

    init(
        id: String,
        username: String,
        accountAge: String,
        postKarma: Int,
        commentKarma: Int,
        isActive: Bool,
        needsLogin: Bool
    ) {
        self.id = id
        self.username = username
        self.accountAge = accountAge
        self.postKarma = postKarma
        self.commentKarma = commentKarma
        self.isActive = isActive
        self.needsLogin = needsLogin
    }

    init(account: Account, isActive: Bool = false) {
        self.init(
            id: account.id.rawValue.uuidString, username: account.username,
            accountAge: account.createdAt.formatted(.relative(presentation: .named)), postKarma: 0,
            commentKarma: 0, isActive: isActive, needsLogin: account.health == .needsLogin)
    }
}

struct FeedDescriptorModel: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case home, popular, all, community, multireddit, custom }
    var kind: Kind
    var name: String
    var customFeedID: UUID? = nil
    var communities: [String] = []

    static let home = FeedDescriptorModel(kind: .home, name: "Home")
    static let popular = FeedDescriptorModel(kind: .popular, name: "Popular")
    static let all = FeedDescriptorModel(kind: .all, name: "All")
}

enum ComposerKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case post
    case comment
    case message
    case edit

    var id: String { rawValue }
    var title: String {
        switch self {
        case .post: "New Post"
        case .comment: "Reply"
        case .message: "New Message"
        case .edit: "Edit"
        }
    }
}

enum SettingsDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general, theme, appearance, intelligence, account, dataUse, statistics, advanced, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .theme: "Theme"
        case .appearance: "Appearance"
        case .intelligence: "Intelligence"
        case .account: "Account"
        case .dataUse: "Data Use"
        case .statistics: "Statistics"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }
}

/// Reddit's saved, upvoted, downvoted, and hidden listings hold posts and
/// comments together. A screen showing one of them picks a side.
enum UserSectionContent: String, CaseIterable, Identifiable, Hashable, Sendable {
    case posts = "Posts"
    case comments = "Comments"
    var id: String { rawValue }
}

/// One page of a user-section listing. The screen that asked for it owns the
/// rows, so pushing one section on top of another cannot cross the two.
struct UserSectionPage: Sendable {
    var posts: [PostCardModel] = []
    var comments: [UserCommentCardModel] = []
    var nextPage: String?
}

enum FeatureSearchScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case posts = "Posts"
    case communities = "Communities"
    case users = "Users"
    var id: String { rawValue }
}

enum FeatureRoute: Hashable {
    case feed(FeedDescriptorModel)
    case post(PostCardModel)
    case postURL(URL)
    case community(String)
    case search(String)
    case conversation(String)
    case account(String)
    case userSection(username: String, section: UserSection)
    case settings(SettingsDestination)
    case composer(ComposerKind)
    case gallery(FeedDescriptorModel)
    case gallerySection(username: String, section: UserSection)
    case mediaURL(URL)
    case web(URL)
}

/// Converts URLs received from Share sheets, universal links, and copied
/// Reddit links into feature routes. Keeping this parser pure makes it safe to
/// use from the app shell and straightforward to test without a network call.
enum OctonautFeatureURLRouter {
    private static let redditHosts: Set<String> = [
        "reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "m.reddit.com",
    ]
    private static let mediaHosts: Set<String> = [
        "i.redd.it", "preview.redd.it", "external-preview.redd.it", "v.redd.it",
    ]

    static func route(_ url: URL) -> FeatureRoute? {
        guard let host = url.host?.lowercased() else { return nil }

        if url.scheme?.lowercased() == "octonaut" {
            let path = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            switch host {
            case "feed":
                switch path.first?.lowercased() {
                case "home": return .feed(.home)
                case "all": return .feed(.all)
                default: return .feed(.popular)
                }
            case "community":
                guard let name = path.first else { return nil }
                return .community(name)
            case "post":
                guard let identifier = path.first else { return nil }
                return .postURL(URL(string: "https://www.reddit.com/comments/\(identifier)")!)
            case "user":
                guard let username = path.first else { return nil }
                return .account(username)
            case "search":
                let query =
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
                        $0.name == "q"
                    })?.value
                    ?? path.first
                    ?? ""
                return .search(query)
            case "settings":
                return .settings(.general)
            default:
                return nil
            }
        }

        if host == "redd.it" {
            guard let identifier = url.pathComponents.last(where: { $0 != "/" && !$0.isEmpty }) else {
                return nil
            }
            return .postURL(URL(string: "https://www.reddit.com/comments/\(identifier)") ?? url)
        }

        if mediaHosts.contains(host) {
            return .mediaURL(url)
        }

        guard redditHosts.contains(host) else { return nil }
        let components = url.pathComponents
        let lowercased = components.map { $0.lowercased() }

        if let commentsIndex = lowercased.firstIndex(of: "comments"),
            components.indices.contains(commentsIndex + 1)
        {
            return .postURL(url)
        }

        if let galleryIndex = lowercased.firstIndex(of: "gallery"),
            components.indices.contains(galleryIndex + 1)
        {
            return .postURL(url)
        }

        if let communityIndex = lowercased.firstIndex(of: "r"),
            components.indices.contains(communityIndex + 1)
        {
            let name = components[communityIndex + 1]
            guard !name.isEmpty else { return .web(url) }
            return .community(name)
        }

        return .web(url)
    }
}

enum FeatureSheet: Identifiable, Hashable {
    case quickCommunitySearch
    case quickAccountSwitcher
    case composer(ComposerKind, community: String?)

    var id: String {
        switch self {
        case .quickCommunitySearch: "quick-community-search"
        case .quickAccountSwitcher: "quick-account-switcher"
        case .composer(let kind, let community): "composer-\(kind.rawValue)-\(community ?? "none")"
        }
    }
}

@MainActor
@Observable
final class OctonautFeatureStore {
    private let screenshotMode: Bool
    private struct FeedCacheEntry {
        let posts: [PostCardModel]
        let filteredPostCount: Int
        let nextPage: String?
        let filterRevision: Int
        let storedAt: Date
    }
    private struct DetailCacheKey: Hashable {
        let postID: String
        let sort: String
        let accountID: AccountID?
    }
    private struct DetailCacheEntry {
        let post: PostCardModel
        let comments: [CommentCardModel]
        let storedAt: Date
        /// The setting the comments were built under.
        ///
        /// Collapsing is decided once, while the tree is built, so a cached
        /// thread carries whatever the setting said at the time. Without this
        /// stamp, turning the setting off and reopening a thread read from the
        /// cache served it still collapsed -- the same trap the feed cache's
        /// `filterRevision` exists to close.
        let collapsedAutoModerator: Bool
    }

    /// A feed's rows depend on the selected sort as much as on the feed
    /// itself, so the sort belongs in the cache key. Keying on the descriptor
    /// alone served Top rows to a reader who had since switched to New.
    private struct FeedCacheKey: Hashable {
        let descriptor: FeedDescriptorModel
        let sort: PostSort
        let topTime: TopTime?
    }

    @ObservationIgnored private let reddit: (any RedditClient)?
    @ObservationIgnored private let authenticated: (any AuthenticatedRedditService)?
    @ObservationIgnored private let intelligence: (any IntelligenceService)?
    @ObservationIgnored private let settings: SettingsStore?
    @ObservationIgnored private let persistence: (any PersistenceStore)?
    @ObservationIgnored private let semanticFilter: SemanticFilterEngine?
    /// The selected account is optional because public feeds and previews do
    /// not need credentials. The app can update this value when its account
    /// coordinator changes selection.
    private var accountID: AccountID?
    private var accountGeneration: UInt = 0
    private var nextPage: String?
    @ObservationIgnored private var feedRequestID = UUID()
    @ObservationIgnored private var detailRequestID = UUID()
    @ObservationIgnored private var loadedFeed: FeedDescriptorModel?
    @ObservationIgnored private var feedCache: [FeedCacheKey: FeedCacheEntry] = [:]
    @ObservationIgnored private let feedCacheFreshness: TimeInterval = 15 * 60
    /// Every post the reader has finished with. The single source of truth:
    /// nothing else stores a copy of it.
    ///
    /// Read once from the record and then kept current by `setSeen`
    /// (`loadSeenPostIDs` walks the whole table, so asking per page was work
    /// the feed did not need), and observed, so that marking a post read
    /// re-renders whatever is showing it -- the feed, search results, a
    /// profile, the post itself -- without any of them holding a flag that
    /// can fall out of step.
    ///
    /// Both references settled here too: Hydra reads its `SeenPosts` table
    /// while rendering each post, and Winston's `Post` is a reference type
    /// shared by every view, so neither ever has a second copy to keep
    /// correct. Ours was a `Bool` copied into `posts`, into every cached
    /// feed, into `detailPost`, into `userProfilePosts` and into the search
    /// model -- five truths, of which two were ever stamped.
    private(set) var seenPostIDs: Set<String> = []
    @ObservationIgnored private var hasLoadedSeenPostIDs = false
    /// The feed whose remembered sort has already been resolved, so arriving
    /// at a feed reads the record once rather than on every appearance -- and
    /// so a sort chosen while reading is not immediately overwritten by the
    /// stored one.
    @ObservationIgnored private var sortResolvedForFeedKey: String?

    /// The filter revision the loaded posts were actually filtered under.
    ///
    /// Not the same thing as the revision in force now. Stamping the current
    /// one onto a list produced under an older one is what let a mutation --
    /// a vote, a save, a post marked read -- write the pre-toggle list into
    /// the cache under the post-toggle revision, where a later refresh
    /// accepted it as a hit and served filtered-out posts straight back.
    @ObservationIgnored private var loadedFilterRevision = 0
    @ObservationIgnored private var detailCache: [DetailCacheKey: DetailCacheEntry] = [:]
    @ObservationIgnored private let detailCacheFreshness: TimeInterval = 10 * 60
    @ObservationIgnored private let detailCacheCapacity = 20
    @ObservationIgnored private var visibleDetailKey: DetailCacheKey?
    @ObservationIgnored private var communitiesRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var communitiesRefreshID: UUID?
    var posts: [PostCardModel] = [
        .sample,
        .mediaSample,
        PostCardModel(
            id: "t3_sample-3", community: "swift", author: "concurrency",
            title: "Swift 6 migration: what did you change first?",
            body:
                "A practical discussion about strict concurrency, actors, and the changes that paid off.",
            score: 642, comments: 96, age: "7h", vote: 0, isSaved: false, isNSFW: false,
            isSpoiler: false, isSticky: false, isVideo: false, hasMedia: false, mediaTitle: "",
            shareURL: URL(string: "https://www.reddit.com/r/swift/comments/sample3")!),
        PostCardModel(
            id: "t3_sample-4", community: "technology", author: "daylight_savings",
            title: "What are you reading this week?",
            body: "Share a useful paper, book, or long-form article.", score: 414, comments: 61,
            age: "9h", vote: -1, isSaved: false, isNSFW: false, isSpoiler: false,
            isSticky: true, isVideo: false, hasMedia: false, mediaTitle: "",
            shareURL: URL(string: "https://www.reddit.com/r/technology/comments/sample4")!),
    ]
    /// Sample rows, for previews. A live store empties these in `init`.
    static let previewCommunities: [CommunityCardModel] = [
        CommunityCardModel(name: "apple", memberCount: 5_100_000, isSubscribed: true, isFavorite: true),
        CommunityCardModel(name: "swift", memberCount: 260_000, isSubscribed: true),
        CommunityCardModel(
            name: "iphone", memberCount: 4_300_000, isSubscribed: true, isFavorite: true),
        CommunityCardModel(name: "technology", memberCount: 16_000_000),
    ]

    /// The subscribed communities, and the A-Z sections derived from them.
    ///
    /// The sections are kept rather than computed on demand: the
    /// subscriptions list reads them on every body evaluation, and grouping
    /// and sorting several hundred communities there would be work repeated
    /// for every scroll and every unrelated state change. Writing through
    /// this property is the one place they are rebuilt, so everything that
    /// changes the list -- a refresh, a favourite toggled, an account
    /// switched, a cached page applied -- updates both.
    var communities: [CommunityCardModel] {
        get { communitiesStorage }
        set {
            communitiesStorage = newValue
            communitySections = OctonautFeatureStore.indexedSections(of: newValue)
        }
    }
    private var communitiesStorage: [CommunityCardModel] = OctonautFeatureStore.previewCommunities
    private(set) var communitySections: [CommunityIndexSection] =
        OctonautFeatureStore.indexedSections(of: OctonautFeatureStore.previewCommunities)
    var inbox: [InboxCardModel] = [
        InboxCardModel(
            id: "inbox-1", kind: .reply, title: "Re: What small iOS detail makes your day better?",
            subtitle: "r/apple • swift_reader",
            preview: "The little haptic when a copy action succeeds is one of my favourites.",
            author: "swift_reader", age: "2h", score: 523, isUnread: true),
        InboxCardModel(
            id: "inbox-2", kind: .mention, title: "You were mentioned in a comment",
            subtitle: "r/swift • native_by_design",
            preview: "I agree with @example_author on this approach.", author: "native_by_design",
            age: "5h", score: 83, isUnread: true),
        InboxCardModel(
            id: "inbox-3", kind: .message, title: "Welcome to the community", subtitle: "mod_team",
            preview: "Thanks for joining. Please take a moment to read the rules.", author: "mod_team",
            age: "1d", score: nil, isUnread: false),
    ]
    var accounts: [AccountCardModel] = [
        AccountCardModel(
            id: "account-1", username: "example_author", accountAge: "6 years", postKarma: 12_480,
            commentKarma: 48_320, isActive: true, needsLogin: false)
    ]
    var comments = CommentCardModel.samples
    var feedState: OctonautLoadState = .loaded
    /// Whether the feed is paging on to find a post the reader has not read.
    ///
    /// Separate from `feedState` because the feed is drawn inside an
    /// `OctonautStateView` keyed on that: setting it to `.loading` to show
    /// the row at the end of the list would replace the whole list with a
    /// spinner, taking away the posts the reader is looking at. Which is why
    /// nothing reaches that row as it stands: every assignment of `.loading`
    /// empties `posts` in the same turn, so the row's own condition --
    /// loading with posts still on screen -- cannot hold.
    private(set) var isPagingForNewPosts = false
    var communitiesState: OctonautLoadState = .loaded
    var inboxState: OctonautLoadState = .loaded
    var searchText = ""
    var selectedSort: PostSort = .best
    var selectedTopTime: TopTime = .day
    var detailState: OctonautLoadState = .idle
    var detailPost: PostCardModel?
    var moreLoadingIDs: Set<String> = []
    var moreFailedIDs: Set<String> = []
    var filteredPostCount = 0
    /// Posts marked seen since the tally was last cleared. Drives the feed
    /// accessory's running count, so it is deliberately a session value and
    /// is never persisted.
    private(set) var postsReadSinceReset = 0
    /// Posts the reader has cleared out of the feed.
    ///
    /// Recorded, not session state: pressing the control is the reader saying
    /// "take these away", and they should stay away -- across a refresh, and
    /// across quitting the app. Independent of the hide-on-refresh setting,
    /// which is about read posts in general rather than the ones explicitly
    /// dismissed.
    private(set) var postsClearedFromFeed: Set<String> = []

    /// Posts marked seen since the reader last acted on the tally.
    ///
    /// Hiding is applied when the feed is rendered, so without this a post
    /// would vanish the instant scrolling marked it -- rows disappearing from
    /// under the reader's thumb, taking the scroll position with them. These
    /// stay on screen until the reader clears them or refreshes, which is
    /// what the accessory's "you have read twelve of these, tap to clear
    /// them out" already promises.
    private(set) var postsKeptVisibleWhileReading: Set<String> = []
    var userProfile: UserProfile?
    var userProfilePosts: [PostCardModel] = []
    var userProfileComments: [UserCommentCardModel] = []
    var userProfileState: OctonautLoadState = .idle
    var loadedUserProfileUsername = ""
    var loadedUserProfileAccountContext = ""
    /// The tail of the seen-record write queue.
    ///
    /// Every write to the record goes through here, in order. They used to be
    /// separate detached tasks, which meant a mark could land *after* a clear
    /// that was issued later: the in-memory set was empty, so the screen
    /// looked cleared, while the row went back into the table and came back
    /// greyed out on the next launch.
    @ObservationIgnored private var seenWriteQueue: Task<Void, Never>?

    /// The last failure while writing the seen record, if there was one.
    /// Every one of these used to be swallowed by `try?`, so a record that
    /// was not being written looked exactly like one that was.
    private(set) var seenRecordError: String?

    @discardableResult
    private func enqueueSeenWrite(
        _ work: @escaping @Sendable (any PersistenceStore) async throws -> Void
    ) -> Task<Void, Never>? {
        guard let persistence else { return nil }
        let previous = seenWriteQueue
        let task = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await work(persistence)
            } catch {
                self?.seenRecordError = error.localizedDescription
            }
        }
        seenWriteQueue = task
        return task
    }

    /// Whether the reader has finished with this post. Ask here; do not keep
    /// the answer.
    func isSeen(_ postID: String) -> Bool {
        seenPostIDs.contains(postID)
    }

    /// What the feed should show: everything fetched, minus what the reader
    /// has finished with, when they have asked for that.
    ///
    /// Derived rather than filtered at load time. Filtering on the way in
    /// made the contents of the feed depend on when a post was marked
    /// relative to when its page was fetched, so acting on the toggle meant
    /// refetching -- which can fail, can be served from a cache, and can
    /// leave read posts on screen when it does either. Derived, the toggle
    /// cannot fail: it is the same list, read through a different predicate.
    var visiblePosts: [PostCardModel] {
        posts.filter { post in
            // Cleared by the control: gone, regardless of the setting.
            if postsClearedFromFeed.contains(post.id) { return false }
            // Otherwise read posts stay, greyed, unless the reader has asked
            // for them to disappear on their own -- and even then, one marked
            // while scrolling stays until they act, so a row never vanishes
            // from under the thumb that is scrolling it.
            guard settings?.hideSeenPosts == true else { return true }
            return !seenPostIDs.contains(post.id) || postsKeptVisibleWhileReading.contains(post.id)
        }
    }

    var unreadCount: Int { inbox.filter(\.isUnread).count }
    var accountContextKey: String {
        "\(accountID?.description ?? "anonymous"):\(accountGeneration)"
    }

    /// Adapter initializer for the Domain layer. Live clients can feed their
    /// decoded values here without making SwiftUI views know about DTOs.
    init(
        domainPosts: [Post] = [],
        domainComments: [CommentTreeNode] = [],
        domainCommunities: [Community] = [],
        domainAccounts: [Account] = [],
        reddit: (any RedditClient)? = nil,
        authenticated: (any AuthenticatedRedditService)? = nil,
        accountID: AccountID? = nil,
        intelligence: (any IntelligenceService)? = nil,
        settings: SettingsStore? = nil,
        persistence: (any PersistenceStore)? = nil,
        screenshotMode: Bool = false
    ) {
        self.screenshotMode = screenshotMode
        self.reddit = reddit
        self.authenticated = authenticated
        self.accountID = accountID
        self.intelligence = intelligence
        self.settings = settings
        self.persistence = persistence
        self.semanticFilter = intelligence.map(SemanticFilterEngine.init(service:))
        if let settings {
            // `default` asks Reddit for its own order, which the sort control
            // has no row for. Best is the row it lands on.
            selectedSort = settings.defaultPostSort == .default ? .best : settings.defaultPostSort
            selectedTopTime = settings.defaultTopTime
        }
        if reddit != nil {
            // Live stores start empty. Sample rows are reserved for previews.
            if domainPosts.isEmpty { posts = [] }
            if domainComments.isEmpty { comments = [] }
            if domainCommunities.isEmpty { communities = [] }
        }
        if reddit != nil, domainAccounts.isEmpty {
            accounts = []
            inbox = []
        }
        if !domainPosts.isEmpty { posts = domainPosts.map(PostCardModel.init) }
        if !domainComments.isEmpty {
            comments = domainComments.compactMap { node in
                guard case .comment(let comment) = node else { return nil }
                return CommentCardModel(comment: comment)
            }
        }
        if !domainCommunities.isEmpty { communities = domainCommunities.map(CommunityCardModel.init) }
        if !domainAccounts.isEmpty {
            accounts = domainAccounts.enumerated().map { index, account in
                AccountCardModel(account: account, isActive: index == 0)
            }
            self.accountID = accountID ?? domainAccounts.first?.id
        }
        if screenshotMode {
#if DEBUG
            posts = [.screenshotCat, .screenshotCoast, .sample]
            comments = [
                CommentCardModel(
                    id: "t1_coast-1", author: "morning_light",
                    body: "The colours are lovely. That path looks peaceful.",
                    score: 284, age: "1h", vote: 1, depth: 0, isModerator: false,
                    isCollapsed: false, children: []
                ),
                CommentCardModel(
                    id: "t1_coast-2", author: "sea_air",
                    body: "I would happily spend an afternoon walking there.",
                    score: 96, age: "48m", vote: 0, depth: 0, isModerator: false,
                    isCollapsed: false, children: []
                )
            ]
#endif
        }
    }

    /// Keeps the feature store aligned with the account coordinator. The
    /// coordinator remains the source of truth; this value binds feed reads
    /// to the selected session and lets stale responses be discarded.
    func synchronizeAccount(id: AccountID?, generation: UInt, accounts domainAccounts: [Account]) {
        if screenshotMode { return }
        let selectionChanged = accountID != id || accountGeneration != generation
        accountID = id
        accountGeneration = generation
        accounts = domainAccounts.map { AccountCardModel(account: $0, isActive: $0.id == id) }

        guard selectionChanged else { return }
        communitiesRefreshTask?.cancel()
        communitiesRefreshTask = nil
        communitiesRefreshID = nil
        feedCache.removeAll()
        detailCache.removeAll()
        visibleDetailKey = nil
        nextPage = nil
        loadedFeed = nil
        detailPost = nil
        detailState = .idle
        moreLoadingIDs.removeAll()
        moreFailedIDs.removeAll()
        comments.removeAll()
        inbox.removeAll()
        communities.removeAll()
        communitiesState = id == nil ? .empty : .idle
        inboxState = id == nil ? .empty : .idle
        if reddit != nil {
            posts.removeAll()
            feedState = .idle
        }
    }

    private func isCurrentAccount(_ id: AccountID?, generation: UInt) -> Bool {
        accountID == id && accountGeneration == generation
    }

    /// Invalidate pending work before changing the visible selection.
    func clearVisibleFeed(isLoading: Bool = true) {
        feedRequestID = UUID()
        loadedFeed = nil
        posts = []
        nextPage = nil
        filteredPostCount = 0
        feedState = isLoading ? .loading : .idle
        clearPostDetail()
    }

    func clearPostDetail() {
        saveVisibleDetail()
        detailRequestID = UUID()
        visibleDetailKey = nil
        detailPost = nil
        comments = []
        moreLoadingIDs.removeAll()
        moreFailedIDs.removeAll()
        detailState = .idle
    }

    func refreshPosts(for descriptor: FeedDescriptorModel = .popular, forceRefresh: Bool = false) async {
        if screenshotMode { return }
        // Before any posts are assigned, including from the cache: the first
        // frame must already know what has been read.
        _ = await seenPostIDSet()
        // And before the cache key is computed, since the key carries the sort.
        await resolveStoredSort(for: descriptor)
        let requestID = UUID()
        feedRequestID = requestID
        let filterRevision = Int(settings?.filterRevision ?? 0)
        let cacheKey = feedCacheKey(for: descriptor)
        var hasWarmContent = loadedFeed == descriptor && !posts.isEmpty
        if forceRefresh {
            // An explicit refresh is the reader acting, so posts they have
            // already read stop being held on screen.
            postsKeptVisibleWhileReading.removeAll()
        }
        if !forceRefresh,
           let cached = feedCache[cacheKey],
           cached.filterRevision == filterRevision {
            loadedFilterRevision = cached.filterRevision
            posts = cached.posts
            filteredPostCount = cached.filteredPostCount
            nextPage = cached.nextPage
            loadedFeed = descriptor
            feedState = posts.isEmpty ? .empty : .loaded
            hasWarmContent = !posts.isEmpty
            if Date.now.timeIntervalSince(cached.storedAt) < feedCacheFreshness {
                return
            }
        }

        feedState = hasWarmContent ? .loaded : .loading
        if !hasWarmContent {
            posts = []
            loadedFeed = nil
            nextPage = nil
            filteredPostCount = 0
        }
        guard let reddit else {
            try? await Task.sleep(for: .milliseconds(240))
            guard feedRequestID == requestID, !Task.isCancelled else { return }
            feedState = posts.isEmpty ? .empty : .loaded
            return
        }

        let selectedAccountID = accountID
        let selectedGeneration = accountGeneration
        do {
            let page = try await loadFilteredPage(
                from: reddit,
                feed: domainFeed(for: descriptor),
                after: nil,
                accountScope: selectedAccountID.map(AccountScope.account) ?? .anonymous,
                account: selectedAccountID,
                responseCachePolicy: forceRefresh ? .reloadIgnoringCache : .useCache
            )
            guard feedRequestID == requestID, !Task.isCancelled, isCurrentAccount(selectedAccountID, generation: selectedGeneration)
            else { return }
            loadedFilterRevision = filterRevision
            posts = page.cards
            filteredPostCount = page.removedCount
            nextPage = page.after
            loadedFeed = descriptor
            feedState = posts.isEmpty ? .empty : .loaded
            feedCache[cacheKey] = FeedCacheEntry(
                posts: posts,
                filteredPostCount: filteredPostCount,
                nextPage: nextPage,
                filterRevision: filterRevision,
                storedAt: .now
            )
        } catch is CancellationError {
            return
        } catch {
            guard feedRequestID == requestID, isCurrentAccount(selectedAccountID, generation: selectedGeneration) else { return }
            nextPage = nil
            feedState = hasWarmContent ? .loaded : .failed(error.localizedDescription)
        }
    }

    func refreshCommunities(forceRefresh: Bool = false) async {
        if screenshotMode { return }
        if !forceRefresh, let communitiesRefreshTask {
            await communitiesRefreshTask.value
            return
        }

        if forceRefresh {
            communitiesRefreshTask?.cancel()
        }

        let refreshID = UUID()
        communitiesRefreshID = refreshID
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performCommunitiesRefresh(forceRefresh: forceRefresh)
            if self.communitiesRefreshID == refreshID {
                self.communitiesRefreshTask = nil
                self.communitiesRefreshID = nil
            }
        }
        communitiesRefreshTask = task
        await task.value
    }

    private func performCommunitiesRefresh(forceRefresh: Bool) async {
        guard let reddit else {
            communitiesState = communities.isEmpty ? .empty : .loaded
            return
        }
        guard let selectedAccountID = accountID else {
            communities = []
            communitiesState = .empty
            return
        }

        let selectedGeneration = accountGeneration
        let favorites = localFavoriteCommunityNames(accountID: selectedAccountID)
        if communities.isEmpty {
            communities = favorites.sorted().map {
                CommunityCardModel(name: $0, isSubscribed: true, isFavorite: true)
            }
        }

        if !forceRefresh {
            let cached = await SubscribedCommunitiesCache.shared.value(for: selectedAccountID)
            guard !Task.isCancelled,
                  isCurrentAccount(selectedAccountID, generation: selectedGeneration)
            else { return }
            if let cached {
                applyCommunities(cached.communities, favorites: favorites)
                communitiesState = communities.isEmpty ? .empty : .loaded
                if cached.isFresh { return }
            }
        }

        guard !Task.isCancelled,
              isCurrentAccount(selectedAccountID, generation: selectedGeneration)
        else { return }
        communitiesState = .loading
        do {
            var values: [Community] = []
            var after: String?
            var seenCursors = Set<String>()
            repeat {
                let page = try await reddit.subscribedCommunities(after: after, account: selectedAccountID)
                guard !Task.isCancelled,
                    isCurrentAccount(selectedAccountID, generation: selectedGeneration)
                else { return }
                values.append(contentsOf: page.items)
                guard let next = page.after, seenCursors.insert(next).inserted else {
                    after = nil
                    break
                }
                after = next
            } while after != nil

            applyCommunities(values, favorites: favorites)
            await SubscribedCommunitiesCache.shared.store(values, for: selectedAccountID)
            communitiesState = communities.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccount(selectedAccountID, generation: selectedGeneration) else { return }
            communitiesState = .failed(error.localizedDescription)
        }
    }

    /// Groups the subscription rows for the A-Z index.
    ///
    /// Favourites are left out: they have their own section above, and a
    /// community listed there must not appear a second time under its letter.
    /// Only letters that have a community get a section, so the index strip
    /// never points at an empty one. `#` comes first, ahead of A.
    static func indexedSections(of values: [CommunityCardModel]) -> [CommunityIndexSection] {
        var buckets: [String: [CommunityCardModel]] = [:]
        for community in values where !community.isFavorite {
            buckets[indexSectionID(for: community.name), default: []].append(community)
        }
        return buckets
            .map { id, members in
                CommunityIndexSection(
                    id: id,
                    // Sorted on the same bare name the section was chosen
                    // by. Sorting on the raw name instead put a prefixed
                    // "r/analog" after "Apple" inside section A, ordered by a
                    // prefix the grouping had already discarded.
                    communities: members.sorted {
                        bareName($0.name).localizedCaseInsensitiveCompare(bareName($1.name))
                            == .orderedAscending
                    })
            }
            .sorted { left, right in
                // "#" collects everything that is not a letter and leads the
                // alphabet, rather than sitting wherever "#" happens to fall
                // in a string comparison.
                if left.id == nonLetterSectionID { return true }
                if right.id == nonLetterSectionID { return false }
                return left.id.localizedCompare(right.id) == .orderedAscending
            }
    }

    /// The single section that collects names not starting with a letter. It
    /// sorts ahead of A.
    static let nonLetterSectionID = "#"

    /// The section a community belongs under: its first letter, upper-cased.
    /// A digit, an underscore or an empty name goes to `#` -- between them
    /// that is the rest of what Reddit allows in a community name.
    static func indexSectionID(for name: String) -> String {
        guard let first = bareName(name).first, first.isLetter else { return nonLetterSectionID }
        return first.uppercased()
    }

    /// A community name without an `r/` prefix, which most of them do not
    /// carry -- the row adds it when it draws -- but a name typed into a
    /// custom feed or read from an older cache can.
    static func bareName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["/r/", "r/"] where trimmed.lowercased().hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }
        return trimmed
    }

    private func applyCommunities(_ values: [Community], favorites: Set<String>) {
        var seenIDs = Set<String>()
        communities =
            values
            .sorted {
                $0.reference.name.localizedCaseInsensitiveCompare($1.reference.name) == .orderedAscending
            }
            .filter { seenIDs.insert($0.id).inserted }
            .map { community in
                var model = CommunityCardModel(community: community)
                model.isSubscribed = true
                model.isFavorite = favorites.contains(model.id)
                return model
            }
    }

    func refreshInbox() async {
        guard reddit == nil else {
            inbox = []
            inboxState = .empty
            return
        }
        inboxState = .loading
        try? await Task.sleep(for: .milliseconds(240))
        guard !Task.isCancelled else { return }
        inboxState = inbox.isEmpty ? .empty : .loaded
    }

    func loadUserProfile(username: String, forceRefresh: Bool = false) async {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty else {
            userProfileState = .failed("A username is required.")
            return
        }
        let selectedAccountID = accountID
        let selectedGeneration = accountGeneration
        let currentAccountContext = accountContextKey
        let isSameProfile =
            loadedUserProfileUsername.caseInsensitiveCompare(normalizedUsername) == .orderedSame
            && loadedUserProfileAccountContext == currentAccountContext
        loadedUserProfileUsername = normalizedUsername
        loadedUserProfileAccountContext = currentAccountContext

        if !forceRefresh,
           let cached = await UserProfileCache.shared.value(
               for: normalizedUsername,
               account: selectedAccountID
           ),
           !Task.isCancelled,
           isCurrentAccount(selectedAccountID, generation: selectedGeneration),
           loadedUserProfileUsername.caseInsensitiveCompare(normalizedUsername) == .orderedSame {
            applyUserProfileCache(cached)
            if cached.isFresh { return }
        } else if !isSameProfile || userProfile == nil {
            userProfile = nil
            userProfilePosts.removeAll()
            userProfileComments.removeAll()
            userProfileState = .loading
        }

        guard let reddit else {
            userProfile = UserProfile(
                reference: UserReference(username: normalizedUsername),
                avatarURL: nil,
                createdAt: .now.addingTimeInterval(-6 * 365 * 24 * 60 * 60),
                karma: 60_800,
                about: RichText(plainText: "A fixture profile for offline previews."),
                isBlocked: false,
                isFollowing: false
            )
            userProfilePosts = posts.filter {
                $0.author.caseInsensitiveCompare(normalizedUsername) == .orderedSame
            }
            userProfileComments = []
            userProfileState = .loaded
            return
        }

        let hasCachedContent = userProfile != nil
        if !hasCachedContent { userProfileState = .loading }
        do {
            async let profileRequest = reddit.userProfile(normalizedUsername, account: selectedAccountID)
            async let postsRequest = reddit.listing(
                ListingRequest(
                    feed: FeedDescriptor(
                        destination: .user(username: normalizedUsername, section: .submitted),
                        sort: .new
                    ),
                    limit: 50,
                    accountScope: selectedAccountID.map(AccountScope.account) ?? .anonymous,
                    responseCachePolicy: forceRefresh ? .reloadIgnoringCache : .useCache
                ),
                account: selectedAccountID
            )
            async let commentsRequest = reddit.userComments(
                normalizedUsername, section: .comments, after: nil, account: selectedAccountID)
            let (profile, submitted, comments) = try await (profileRequest, postsRequest, commentsRequest)
            guard !Task.isCancelled,
                isCurrentAccount(selectedAccountID, generation: selectedGeneration),
                loadedUserProfileUsername == normalizedUsername
            else { return }
            userProfile = profile
            userProfilePosts = submitted.items.map(PostCardModel.init)
            userProfileComments = comments.items.map(UserCommentCardModel.init)
            userProfileState = .loaded
            await UserProfileCache.shared.store(
                profile: profile,
                posts: submitted.items,
                comments: comments.items,
                for: normalizedUsername,
                account: selectedAccountID
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccount(selectedAccountID, generation: selectedGeneration) else { return }
            if !hasCachedContent {
                userProfileState = .failed(error.localizedDescription)
            }
        }
    }

    /// Reads one page of a profile section such as Saved or Upvoted. The page
    /// is returned rather than stored: each pushed section screen keeps its own
    /// rows, so opening Upvoted from Saved cannot overwrite what is behind it.
    ///
    /// Feed filters are deliberately not applied. A keyword or blocked-community
    /// rule exists to shape a feed, and silently dropping a post the reader
    /// saved on purpose would be a worse answer than showing it.
    func fetchUserSection(
        _ section: UserSection,
        username: String,
        content: UserSectionContent = .posts,
        after: String? = nil,
        forceRefresh: Bool = false
    ) async throws -> UserSectionPage {
        guard let reddit else { return UserSectionPage() }
        let scope = accountID.map(AccountScope.account) ?? .anonymous
        switch content {
        case .posts:
            let listing = try await reddit.listing(
                ListingRequest(
                    feed: FeedDescriptor(
                        destination: .user(username: username, section: section),
                        sort: .new
                    ),
                    limit: 35,
                    after: after,
                    accountScope: scope,
                    responseCachePolicy: forceRefresh ? .reloadIgnoringCache : .useCache
                ),
                account: accountID
            )
            return UserSectionPage(
                posts: listing.items.map(PostCardModel.init),
                nextPage: listing.after == after ? nil : listing.after
            )
        case .comments:
            let listing = try await reddit.userComments(
                username, section: section, after: after, account: accountID)
            return UserSectionPage(
                comments: listing.items.map(UserCommentCardModel.init),
                nextPage: listing.after == after ? nil : listing.after
            )
        }
    }

    private func applyUserProfileCache(_ cached: UserProfileCache.Value) {
        userProfile = cached.profile
        userProfilePosts = cached.posts.map(PostCardModel.init)
        userProfileComments = cached.comments.map(UserCommentCardModel.init)
        userProfileState = .loaded
    }

    @discardableResult
    func loadPostDetail(
        for post: PostCardModel,
        sort: String = "Best",
        preservingVisibleComments: Bool = false,
        forceRefresh: Bool = false
    ) async -> Bool {
        if screenshotMode {
            detailPost = post
            detailState = .loaded
            return true
        }
        let key = DetailCacheKey(postID: post.id, sort: sort.lowercased(), accountID: accountID)
        saveVisibleDetail()
        if !forceRefresh, let cached = detailCache[key],
           cached.collapsedAutoModerator == collapsesAutoModeratorComments,
           Date.now.timeIntervalSince(cached.storedAt) < detailCacheFreshness {
            detailRequestID = UUID()
            detailPost = cached.post
            comments = cached.comments
            visibleDetailKey = key
            moreLoadingIDs.removeAll()
            moreFailedIDs.removeAll()
            detailState = .loaded
            return true
        }
        detailCache.removeValue(forKey: key)
        let requestID = UUID()
        detailRequestID = requestID
        visibleDetailKey = nil
        if !preservingVisibleComments {
            detailState = .loading
            detailPost = post
        }
        guard let reddit else {
            try? await Task.sleep(for: .milliseconds(180))
            guard detailRequestID == requestID, !Task.isCancelled else { return false }
            detailState = .loaded
            return true
        }
        if !preservingVisibleComments {
            comments = []
        }

        let selectedAccountID = accountID
        let selectedGeneration = accountGeneration
        do {
            let thread = try await reddit.post(
                post.shareURL,
                sort: CommentSort(rawValue: sort.lowercased()),
                account: selectedAccountID
            )
            guard detailRequestID == requestID, !Task.isCancelled, isCurrentAccount(selectedAccountID, generation: selectedGeneration)
            else { return false }
            detailPost = PostCardModel(post: thread.post)
            comments = thread.comments.map { node in
                switch node {
                case .comment(let comment):
                    return CommentCardModel(
                        comment: comment, isCollapsed: collapsesOnArrival(comment, depth: 0))
                case .more(let more): return CommentCardModel.more(more, depth: 0)
                case .deleted(let deleted): return CommentCardModel.deleted(deleted, depth: 0)
                }
            }
            moreFailedIDs.removeAll()
            detailState = .loaded
            visibleDetailKey = key
            detailCache[key] = DetailCacheEntry(
                post: detailPost ?? post, comments: comments, storedAt: .now,
                collapsedAutoModerator: collapsesAutoModeratorComments)
            trimDetailCache()
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard detailRequestID == requestID, isCurrentAccount(selectedAccountID, generation: selectedGeneration) else { return false }
            if !preservingVisibleComments {
                detailState = .failed(error.localizedDescription)
            }
            return false
        }
    }

    func loadMoreComments(_ commentID: String, for post: PostCardModel, sort: String = "Best") async {
        guard !moreLoadingIDs.contains(commentID) else { return }
        guard let placeholder = comment(withID: commentID, in: comments),
              placeholder.isMoreNode,
              let parentFullname = placeholder.moreParentFullname,
              !placeholder.moreChildIDs.isEmpty else {
            moreFailedIDs.insert(commentID)
            return
        }
        let requestID = detailRequestID
        moreLoadingIDs.insert(commentID)
        moreFailedIDs.remove(commentID)
        defer { if detailRequestID == requestID { moreLoadingIDs.remove(commentID) } }

        guard let reddit else {
            try? await Task.sleep(for: .milliseconds(180))
            guard detailRequestID == requestID else { return }
            moreFailedIDs.insert(commentID)
            return
        }

        let requestedChildIDs = Array(placeholder.moreChildIDs.prefix(100))
        let remainingChildIDs = Array(placeholder.moreChildIDs.dropFirst(requestedChildIDs.count))
        let selectedAccountID = accountID
        let selectedGeneration = accountGeneration
        do {
            let nodes = try await reddit.moreComments(
                postFullname: post.fullname,
                parentFullname: parentFullname,
                childIDs: requestedChildIDs,
                sort: CommentSort(rawValue: sort),
                account: selectedAccountID
            )
            guard detailRequestID == requestID, !Task.isCancelled,
                  isCurrentAccount(selectedAccountID, generation: selectedGeneration) else { return }

            var replacements = nodes.map { node -> CommentCardModel in
                switch node {
                case .comment(let comment):
                    return CommentCardModel(
                        comment: comment, depth: placeholder.depth,
                        isCollapsed: collapsesOnArrival(comment, depth: placeholder.depth))
                case .more(let more):
                    return CommentCardModel.more(more, depth: placeholder.depth)
                case .deleted(let deleted):
                    return CommentCardModel.deleted(deleted, depth: placeholder.depth)
                }
            }
            if !remainingChildIDs.isEmpty {
                let remainingCount = max(
                    remainingChildIDs.count,
                    (placeholder.moreCount ?? placeholder.moreChildIDs.count) - requestedChildIDs.count
                )
                replacements.append(
                    .more(
                        MoreCommentsNode(
                            id: "\(commentID)-\(remainingChildIDs[0])",
                            parentFullname: parentFullname,
                            childIDs: remainingChildIDs,
                            count: remainingCount
                        ),
                        depth: placeholder.depth
                    )
                )
            }
            replaceComment(withID: commentID, in: &comments, with: replacements)
            saveVisibleDetail()
        } catch is CancellationError {
            return
        } catch {
            guard detailRequestID == requestID, isCurrentAccount(selectedAccountID, generation: selectedGeneration) else { return }
            moreFailedIDs.insert(commentID)
        }
    }

    private func comment(
        withID id: String,
        in values: [CommentCardModel]
    ) -> CommentCardModel? {
        for value in values {
            if value.id == id { return value }
            if let nested = comment(withID: id, in: value.children) { return nested }
        }
        return nil
    }

    private func saveVisibleDetail() {
        guard let key = visibleDetailKey, let detailPost,
              let existing = detailCache[key],
              Date.now.timeIntervalSince(existing.storedAt) < detailCacheFreshness else { return }
        detailCache[key] = DetailCacheEntry(
            post: detailPost, comments: comments, storedAt: existing.storedAt,
            collapsedAutoModerator: existing.collapsedAutoModerator)
    }

    private func trimDetailCache() {
        if detailCache.count > detailCacheCapacity {
            for key in detailCache.sorted(by: { $0.value.storedAt < $1.value.storedAt })
                .prefix(detailCache.count - detailCacheCapacity).map(\.key) {
                detailCache.removeValue(forKey: key)
            }
        }
    }

    private func replaceComment(
        withID id: String,
        in values: inout [CommentCardModel],
        with replacements: [CommentCardModel]
    ) {
        for index in values.indices {
            if values[index].id == id {
                values.replaceSubrange(index...index, with: replacements)
                return
            }
            replaceComment(withID: id, in: &values[index].children, with: replacements)
        }
    }

    func nextPageCursor(for descriptor: FeedDescriptorModel) -> String? {
        guard loadedFeed == descriptor else { return nil }
        return nextPage
    }

    @ObservationIgnored private var isLoadingNextPage = false

    func loadMorePosts(
        for descriptor: FeedDescriptorModel = .popular,
        pageLimits: [Int]? = nil
    ) async {
        if screenshotMode { return }
        guard feedState == .loaded || feedState == .empty, !isLoadingNextPage else { return }
        let requestID = feedRequestID
        isLoadingNextPage = true
        defer { isLoadingNextPage = false }
        guard let reddit else {
            try? await Task.sleep(for: .milliseconds(180))
            guard feedRequestID == requestID, !Task.isCancelled else { return }
            let nextIndex = posts.count
            let copies = posts.prefix(2).map { post in
                PostCardModel(
                    id: "\(post.id)-\(nextIndex)", community: post.community, author: post.author,
                    authorFlair: post.authorFlair, title: post.title, body: post.body,
                    flair: post.flair, score: post.score,
                    comments: post.comments,
                    age: post.age, vote: post.vote, isSaved: post.isSaved,
                    isNSFW: post.isNSFW, isSpoiler: post.isSpoiler, isSticky: post.isSticky,
                    isVideo: post.isVideo, hasMedia: post.hasMedia, mediaTitle: post.mediaTitle,
                    shareURL: post.shareURL, mediaURL: post.mediaURL, thumbnailURL: post.thumbnailURL,
                    mediaKind: post.mediaKind, galleryURLs: post.galleryURLs, audioURL: post.audioURL)
            }
            posts.append(contentsOf: copies)
            return
        }

        guard loadedFeed == descriptor, let nextPage else { return }
        let selectedAccountID = accountID
        let selectedGeneration = accountGeneration
        do {
            let page = try await loadFilteredPage(
                from: reddit,
                feed: domainFeed(for: descriptor),
                after: nextPage,
                accountScope: selectedAccountID.map(AccountScope.account) ?? .anonymous,
                account: selectedAccountID,
                responseCachePolicy: .useCache,
                limits: pageLimits ?? Self.filteredPageLimits
            )
            guard feedRequestID == requestID, !Task.isCancelled, loadedFeed == descriptor, self.nextPage == nextPage, isCurrentAccount(selectedAccountID, generation: selectedGeneration)
            else { return }
            let existing = Set(posts.map(\.id))
            posts.append(contentsOf: page.cards.filter { !existing.contains($0.id) })
            filteredPostCount += page.removedCount
            self.nextPage = page.after
            feedState = posts.isEmpty ? .empty : .loaded
            feedCache[feedCacheKey(for: descriptor)] = FeedCacheEntry(
                posts: posts,
                filteredPostCount: filteredPostCount,
                nextPage: self.nextPage,
                filterRevision: loadedFilterRevision,
                storedAt: .now
            )
        } catch is CancellationError {
            return
        } catch {
            guard feedRequestID == requestID, isCurrentAccount(selectedAccountID, generation: selectedGeneration) else { return }
            feedState = .failed(error.localizedDescription)
        }
    }

    private func seenPostIDSet() async -> Set<String> {
        if hasLoadedSeenPostIDs { return seenPostIDs }
        guard let persistence else { return [] }
        // Merged, not assigned. Anything marked while this load was in flight
        // is already in the set and its write may not have landed yet, so
        // overwriting would quietly un-read those posts.
        seenPostIDs.formUnion((try? await persistence.loadSeenPostIDs()) ?? [])
        // Clearing is meant to last, so what was cleared is read back too.
        postsClearedFromFeed.formUnion((try? await persistence.loadClearedPostIDs()) ?? [])
        hasLoadedSeenPostIDs = true
        return seenPostIDs
    }

    private func makeCards(from values: [Post]) -> [PostCardModel] {
        values.map(PostCardModel.init)
    }

    private struct FilteredPage {
        var cards: [PostCardModel] = []
        var removedCount = 0
        var after: String?
    }

    /// Page sizes to try in turn. FUN-LIST-004 allows up to two more pages
    /// after an empty one, so three in total. Reddit caps a listing at 100.
    private static let filteredPageLimits = [35, 60, 100]

    /// The page size asked for while catching up past posts the reader has
    /// already read. Nearly all of it will be hidden the moment it is drawn,
    /// so the round trip is the cost that matters -- take as much as Reddit
    /// will give at once rather than paying a request per 35.
    private static let catchUpPageLimits = [100]

    /// Fetches until a page survives filtering. A page can be filtered away
    /// entirely -- easiest to do with "hide seen" on -- and an empty result
    /// used to end the feed for good, because the row whose appearance asks
    /// for the next page never rendered. Widening each retry is how Hydra's
    /// reader escapes the same trap.
    private func loadFilteredPage(
        from reddit: any RedditClient,
        feed: FeedDescriptor,
        after: String?,
        accountScope: AccountScope,
        account: AccountID?,
        responseCachePolicy: ListingRequest.ResponseCachePolicy,
        limits: [Int]? = nil
    ) async throws -> FilteredPage {
        var page = FilteredPage(after: after)
        for limit in limits ?? Self.filteredPageLimits {
            try Task.checkCancellation()
            let listing = try await reddit.listing(
                ListingRequest(
                    feed: feed,
                    limit: limit,
                    after: page.after,
                    accountScope: accountScope,
                    responseCachePolicy: responseCachePolicy
                ),
                account: account
            )
            // A cursor Reddit hands back unchanged is the end of the listing.
            let nextCursor = listing.after == page.after ? nil : listing.after
            // An empty response is the end of the feed, not a filter wipeout.
            // Retrying would only ask for the same nothing again.
            if listing.items.isEmpty {
                page.after = nextCursor
                break
            }
            let filtered = await applyFilters(to: listing.items)
            page.removedCount += filtered.removedCount
            page.after = nextCursor
            if !filtered.posts.isEmpty {
                page.cards = makeCards(from: filtered.posts)
                break
            }
            if nextCursor == nil { break }
        }
        return page
    }

    private func applyFilters(to values: [Post]) async -> (posts: [Post], removedCount: Int) {
        // Seen posts are not dropped here, and nothing is stamped onto the
        // cards: what the reader has finished with is answered by `isSeen`
        // wherever a post is drawn. Warming the set still matters, so that
        // the first frame after a load already knows.
        _ = await seenPostIDSet()

        let keywordTerms =
            UserDefaults.standard.string(forKey: "filters.keywordTerms")?.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty } ?? []
        let blockedCommunities = Set(
            (UserDefaults.standard.string(forKey: "filters.blockedCommunities") ?? "")
                .split(separator: ",")
                .map { IDNormalization.community(String($0)) }
                .filter { !$0.isEmpty })
        let deterministic = DeterministicPostFilter.apply(
            values,
            configuration: DeterministicFilterConfiguration(
                blockedCommunities: blockedCommunities,
                keywordRules: keywordTerms.isEmpty ? [] : [KeywordFilterRule(terms: keywordTerms)]
            )
        )

        guard UserDefaults.standard.bool(forKey: "filters.semantic.enabled"),
            let semanticFilter,
            let instruction = UserDefaults.standard.string(forKey: "filters.semantic.instruction"),
            !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return (deterministic.visible, deterministic.removedCount)
        }

        let rule = SemanticRule(
            id: "default",
            instruction: instruction,
            revision: Int(settings?.filterRevision ?? 0)
        )
        let decisions = await semanticFilter.classify(posts: deterministic.visible, rule: rule)
        let hiddenIDs = Set(decisions.filter(\.shouldHide).map(\.itemID))
        let visible = deterministic.visible.filter { !hiddenIDs.contains($0.id) }
        return (visible, values.count - visible.count)
    }

    /// Updates the account used by subsequent reads. Callers should refresh
    /// the visible feed or detail after changing it.
    func setAccountID(_ accountID: AccountID?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        accountGeneration &+= 1
        feedCache.removeAll()
        detailCache.removeAll()
        visibleDetailKey = nil
        nextPage = nil
        loadedFeed = nil
        detailPost = nil
        detailState = .idle
        comments.removeAll()
        inbox.removeAll()
        inboxState = accountID == nil ? .empty : .idle
    }

    private func domainFeed(for descriptor: FeedDescriptorModel) -> FeedDescriptor {
        let destination: FeedDestination
        switch descriptor.kind {
        case .home: destination = .home
        case .popular: destination = .popular
        case .all: destination = .all
        case .custom: destination = .combined(descriptor.communities)
        case .community: destination = .community(descriptor.name)
        case .multireddit: destination = .url(URL(string: "https://www.reddit.com")!)
        }
        let sort = effectiveSort(for: descriptor)
        return FeedDescriptor(
            destination: destination,
            sort: sort,
            topTime: sort.acceptsTopTime ? selectedTopTime : nil
        )
    }

    /// The sort a feed actually reads with. A combined feed has no Best route
    /// on Reddit, so Best falls back to Hot there; the sort control reads this
    /// too, so the checkmark never claims a sort the request did not use.
    func effectiveSort(for descriptor: FeedDescriptorModel) -> PostSort {
        descriptor.kind == .custom && selectedSort == .best ? .hot : selectedSort
    }

    /// Reddit only honours a time range on Top and Controversial.
    var effectiveTopTime: TopTime? {
        selectedSort.acceptsTopTime ? selectedTopTime : nil
    }

    /// The account a preference belongs to. Deliberately not
    /// `accountContextKey`, which carries a session generation: that changes
    /// within a run and would orphan every record written before it.
    private var feedPreferenceAccountScope: String {
        accountID?.description ?? "anonymous"
    }

    /// The key a feed's sort is remembered under, or nil when it is not
    /// remembered at all.
    ///
    /// The two settings decide which feeds take part: communities under
    /// "Remember sort per community", multireddits and custom feeds under
    /// "Remember sort per multireddit". Home, Popular and All are shared
    /// listings rather than somewhere the reader keeps a standing
    /// preference, so they are not covered by either.
    private func feedPreferenceKey(for descriptor: FeedDescriptorModel) -> String? {
        guard let settings else { return nil }
        switch descriptor.kind {
        case .community:
            guard settings.rememberSortPerCommunity else { return nil }
            return "community:\(IDNormalization.community(descriptor.name))"
        case .multireddit:
            guard settings.rememberSortPerMultireddit else { return nil }
            return "multireddit:\(IDNormalization.community(descriptor.name))"
        case .custom:
            guard settings.rememberSortPerMultireddit else { return nil }
            return "custom:\(descriptor.customFeedID?.uuidString ?? descriptor.name)"
        case .home, .popular, .all:
            return nil
        }
    }

    /// Whether the reader has asked for sort to be remembered anywhere.
    ///
    /// With both settings off, sort stays what it has always been: one value
    /// that follows the reader between feeds for the session. Turning either
    /// on makes sort a property of the feed, which means a feed with no
    /// record of its own opens at the default rather than inheriting
    /// whatever the last feed was sorted by.
    private var remembersSortAnywhere: Bool {
        (settings?.rememberSortPerCommunity ?? false) || (settings?.rememberSortPerMultireddit ?? false)
    }

    private var defaultSort: PostSort {
        let configured = settings?.defaultPostSort ?? .best
        return configured == .default ? .best : configured
    }

    /// Applies the sort this feed was last read with, on arrival.
    private func resolveStoredSort(for descriptor: FeedDescriptorModel) async {
        guard remembersSortAnywhere else { return }
        let key = feedPreferenceKey(for: descriptor) ?? "shared:\(descriptor.kind.rawValue)"
        guard sortResolvedForFeedKey != key else { return }
        sortResolvedForFeedKey = key

        guard feedPreferenceKey(for: descriptor) != nil else {
            // A feed that is not remembered opens at the default rather than
            // inheriting the last feed's sort.
            selectedSort = defaultSort
            selectedTopTime = settings?.defaultTopTime ?? selectedTopTime
            return
        }
        guard let stored = try? await persistence?.loadFeedPreference(
            feedKey: key, accountScope: feedPreferenceAccountScope
        ) else {
            selectedSort = defaultSort
            selectedTopTime = settings?.defaultTopTime ?? selectedTopTime
            return
        }
        selectedSort = stored.sort
        selectedTopTime = stored.topTime ?? selectedTopTime
    }

    private func rememberSort(for descriptor: FeedDescriptorModel) {
        guard let key = feedPreferenceKey(for: descriptor), let persistence else { return }
        sortResolvedForFeedKey = key
        let preference = FeedSortPreference(
            sort: selectedSort,
            topTime: selectedSort.acceptsTopTime ? selectedTopTime : nil
        )
        Task {
            try? await persistence.saveFeedPreference(
                preference, feedKey: key, accountScope: feedPreferenceAccountScope
            )
        }
    }

    private func feedCacheKey(for descriptor: FeedDescriptorModel) -> FeedCacheKey {
        let sort = effectiveSort(for: descriptor)
        return FeedCacheKey(
            descriptor: descriptor,
            sort: sort,
            topTime: sort.acceptsTopTime ? selectedTopTime : nil
        )
    }

    /// Applies a sort chosen from the feed control. The visible rows are
    /// dropped first so a list can never show two sorts at once, then the
    /// reload runs through the cache: flipping back to a sort read moments
    /// ago is instant.
    func applySort(_ sort: PostSort, topTime: TopTime? = nil, for descriptor: FeedDescriptorModel) async {
        let resolvedTopTime = topTime ?? selectedTopTime
        guard selectedSort != sort || (sort.acceptsTopTime && selectedTopTime != resolvedTopTime) else { return }
        selectedSort = sort
        selectedTopTime = resolvedTopTime
        rememberSort(for: descriptor)
        posts = []
        nextPage = nil
        filteredPostCount = 0
        loadedFeed = nil
        feedState = .loading
        await refreshPosts(for: descriptor)
    }

    func vote(postID: String, value: Int) {
        if let index = posts.firstIndex(where: { $0.id == postID }) {
            let oldVote = posts[index].vote
            posts[index].vote = value
            posts[index].score += value - oldVote
        }
        if detailPost?.id == postID {
            let oldDetailVote = detailPost?.vote ?? 0
            detailPost?.vote = value
            detailPost?.score += value - oldDetailVote
        }
        updateLoadedFeedCache()
    }

    /// Applies a vote immediately, then sends it for the selected account.
    /// The previous value is restored when Reddit rejects the mutation.
    func performVote(postID: String, value: Int, accountID: AccountID) async throws {
        guard self.accountID == accountID else { return }
        let oldVote: Int
        if let index = posts.firstIndex(where: { $0.id == postID }) {
            oldVote = posts[index].vote
        } else if let detailPost, detailPost.id == postID {
            oldVote = detailPost.vote
        } else {
            return
        }
        let generation = accountGeneration
        vote(postID: postID, value: value)
        do {
            let action = RedditAction.vote(
                fullname: IDNormalization.fullname(postID, kind: "t3"), direction: value)
            if let authenticated {
                _ = try await authenticated.perform(action, accountID: accountID)
            } else if let reddit {
                _ = try await reddit.perform(action, account: accountID)
            }
        } catch {
            if isCurrentAccount(accountID, generation: generation) {
                vote(postID: postID, value: oldVote)
            }
            throw error
        }
    }

    func save(postID: String) {
        if let index = posts.firstIndex(where: { $0.id == postID }) {
            posts[index].isSaved.toggle()
        }
        if detailPost?.id == postID { detailPost?.isSaved.toggle() }
        updateLoadedFeedCache()
    }

    /// Applies a save change immediately, then sends it for the selected
    /// account. The previous value is restored when Reddit rejects it.
    func performSave(postID: String, accountID: AccountID) async throws {
        guard self.accountID == accountID else { return }
        let oldSaved: Bool
        if let index = posts.firstIndex(where: { $0.id == postID }) {
            oldSaved = posts[index].isSaved
        } else if let detailPost, detailPost.id == postID {
            oldSaved = detailPost.isSaved
        } else {
            return
        }
        let generation = accountGeneration
        save(postID: postID)
        do {
            let action = RedditAction.save(
                fullname: IDNormalization.fullname(postID, kind: "t3"), saved: !oldSaved)
            if let authenticated {
                _ = try await authenticated.perform(action, accountID: accountID)
            } else if let reddit {
                _ = try await reddit.perform(action, account: accountID)
            }
        } catch {
            if isCurrentAccount(accountID, generation: generation) {
                save(postID: postID)
            }
            throw error
        }
    }

    /// Sets the saved flag for a post the visible feed may not hold, such as a
    /// row in the Saved list. `performSave` reads the current value out of the
    /// feed and does nothing when the post is absent, so an explicit target is
    /// needed there.
    func setSaved(_ saved: Bool, postID: String, accountID: AccountID) async throws {
        guard self.accountID == accountID else { return }
        let generation = accountGeneration
        applySavedFlag(saved, postID: postID)
        do {
            let action = RedditAction.save(
                fullname: IDNormalization.fullname(postID, kind: "t3"), saved: saved)
            if let authenticated {
                _ = try await authenticated.perform(action, accountID: accountID)
            } else if let reddit {
                _ = try await reddit.perform(action, account: accountID)
            }
        } catch {
            if isCurrentAccount(accountID, generation: generation) {
                applySavedFlag(!saved, postID: postID)
            }
            throw error
        }
    }

    private func applySavedFlag(_ saved: Bool, postID: String) {
        if let index = posts.firstIndex(where: { $0.id == postID }) {
            posts[index].isSaved = saved
        }
        if detailPost?.id == postID { detailPost?.isSaved = saved }
        updateLoadedFeedCache()
    }

    /// Sets the seen flag outright. Scrolling past a post and "Mark Visible
    /// Seen" both want a setter, not a flip: the bulk action used to run
    /// through `markSeen` and so un-marked every post already read.
    /// - Parameter keepingVisible: whether these posts should stay on screen
    ///   until the reader clears the tally. True for reading: a row must not
    ///   vanish from under the thumb that is scrolling it. False for a
    ///   deliberate bulk action -- "Mark Visible Seen" is the reader saying
    ///   they are done with these, so holding them on screen afterwards makes
    ///   the menu item look like it did nothing.
    func setSeen(_ isSeen: Bool, postIDs: [String], keepingVisible: Bool = true) {
        let changed = postIDs.filter { seenPostIDs.contains($0) != isSeen }
        guard !changed.isEmpty else { return }
        if isSeen {
            seenPostIDs.formUnion(changed)
            postsReadSinceReset += changed.count
            // Only what actually changed. Adding the whole batch pinned posts
            // the reader had already dealt with back onto the screen, which is
            // how "Mark Visible Seen" could put read posts back in the feed.
            if keepingVisible {
                postsKeptVisibleWhileReading.formUnion(changed)
            } else {
                postsKeptVisibleWhileReading.subtract(changed)
            }
        } else {
            seenPostIDs.subtract(changed)
            postsReadSinceReset = max(0, postsReadSinceReset - changed.count)
            postsKeptVisibleWhileReading.subtract(changed)
            // Marking something unread undoes having cleared it away.
            postsClearedFromFeed.subtract(changed)
            enqueueSeenWrite { try await $0.setPostsCleared(changed, cleared: false) }
        }
        updateLoadedFeedCache()
        enqueueSeenWrite { store in
            for postID in changed {
                if isSeen {
                    try await store.markPostSeen(postID, seenAt: .now)
                } else {
                    try await store.removePostSeen(postID)
                }
            }
        }
    }

    func setSeen(_ isSeen: Bool, postID: String, keepingVisible: Bool = true) {
        setSeen(isSeen, postIDs: [postID], keepingVisible: keepingVisible)
    }

    /// How many posts the record holds. Shown in Settings, where the number
    /// is the answer to "why did that old post come back?" -- the record is
    /// capped at 5,000 and drops the oldest first.
    var seenPostCount: Int { seenPostIDs.count }

    /// Forgets every post the reader has finished with.
    ///
    /// The set is the only truth, so emptying it un-dims and un-hides
    /// everything on screen in the same frame -- there are no copies left to
    /// go looking for.
    func clearSeenPosts() async {
        seenPostIDs.removeAll()
        postsClearedFromFeed.removeAll()
        postsKeptVisibleWhileReading.removeAll()
        postsReadSinceReset = 0
        hasLoadedSeenPostIDs = true
        seenRecordError = nil
        updateLoadedFeedCache()
        // Awaited, and behind everything already queued: marks made moments
        // earlier must be applied and then deleted, not applied afterwards.
        // When this returns, the record really is empty.
        await enqueueSeenWrite { try await $0.clearSeenPosts() }?.value
    }

    /// Takes every read post out of the feed and starts the count again.
    ///
    /// This is what the feed control does, and it is an action rather than a
    /// switch: press it and the greyed posts go, press it again and the ones
    /// read since go too. It does not turn anything on or off, so pressing
    /// twice never puts back what the first press removed.
    func clearReadPostsFromFeed() {
        let cleared = posts.map(\.id).filter { seenPostIDs.contains($0) }
        postsKeptVisibleWhileReading.removeAll()
        postsReadSinceReset = 0
        guard !cleared.isEmpty else { return }
        postsClearedFromFeed.formUnion(cleared)
        enqueueSeenWrite { try await $0.setPostsCleared(cleared, cleared: true) }
    }

    /// Whether there is anything for the control to clear.
    var hasReadPostsInFeed: Bool {
        visiblePosts.contains { seenPostIDs.contains($0.id) }
    }

    /// Keeps paging while every fetched post is hidden.
    ///
    /// Hiding when the feed renders means a whole page can be hidden, and
    /// then no row exists to ask for the next one -- the trap the load-time
    /// filter had, relocated. FUN-LIST-004's two extra pages bound it, and a
    /// listing that has ended stops it outright.
    func loadMorePostsUntilSomethingIsVisible(for descriptor: FeedDescriptorModel) async {
        guard visiblePosts.isEmpty, !posts.isEmpty else { return }
        await loadMorePostsUntilSomethingNewIsVisible(for: descriptor)
    }

    /// Pages until the feed gains a row. This is what the rows near the end
    /// of the list ask for.
    ///
    /// A page can arrive in full and still put nothing on screen. Every post
    /// in it is already read and hide-seen is on; every post in it was
    /// cleared by the read-posts control, which hides regardless of that
    /// setting; or every post is a duplicate of one the feed already holds,
    /// which a listing sorted by anything live hands back routinely. In all
    /// three the store looks healthy afterwards -- `posts` grew or the cursor
    /// moved, the state is `.loaded` -- while the list is unchanged, so the
    /// `onAppear` that asks for the next page never fires again and the feed
    /// is finished for good. Leaving and coming back does not clear it: the
    /// cache restores the same tail, and the empty-feed loop above does not
    /// apply because the feed is not empty. Paging on from the gallery does,
    /// which is the shape of the bug as reported -- the gallery draws
    /// `posts`, not `visiblePosts`, and pages from a cursor rather than a row.
    ///
    /// FUN-LIST-004 counts hide-seen among the filters a wiped-out page must
    /// be retried for, and bounds that at two further pages. That bound
    /// belongs to the fetch-time filters it was written for and does not
    /// govern this. Measured on device: a refresh taken after reading around
    /// 150 posts clears `postsKeptVisibleWhileReading`, so everything just
    /// read hides at once and four consecutive pages of 35 came back with
    /// nothing visible in them. How far the feed has to page is whatever the
    /// reader has read since the listing last moved on, which no small
    /// constant bounds -- so the budget here is large enough to cross a
    /// normal reading session, and the pages asked for are the biggest
    /// Reddit will give, because nearly all of what arrives will be hidden.
    ///
    /// What stops it is the listing itself: a cursor Reddit hands back
    /// unchanged ends it outright, on the first attempt as readily as the
    /// last.
    func loadMorePostsUntilSomethingNewIsVisible(for descriptor: FeedDescriptorModel) async {
        let countBefore = visiblePosts.count
        guard nextPage != nil else { return }
        isPagingForNewPosts = true
        defer { isPagingForNewPosts = false }
        var attempts = 0
        while attempts < Self.catchUpPageBudget, nextPage != nil, visiblePosts.count == countBefore {
            attempts += 1
            let cursorBefore = nextPage
            // The first ask is an ordinary page: usually it lands something
            // and nothing more is needed. Only once one has been swallowed
            // whole is this a catch-up, and worth the larger request.
            await loadMorePosts(
                for: descriptor, pageLimits: attempts == 1 ? nil : Self.catchUpPageLimits)
            // Nothing moved: the request was dropped or the listing ended.
            // Asking again would only repeat it.
            if nextPage == cursorBefore { return }
        }
    }

    /// One ordinary page, then five of a hundred: around five hundred posts
    /// already read, which covers a long session's reading without turning
    /// one flick of the thumb into an unbounded run of requests.
    private static let catchUpPageBudget = 6

    /// Flips the flag, for the explicit "Mark Seen"/"Mark Unseen" actions.
    func markSeen(postID: String) {
        setSeen(!seenPostIDs.contains(postID), postID: postID)
    }

    func recordPostViewed() async {
        guard settings?.collectLocalUsageStatistics != false, let persistence else { return }
        try? await persistence.incrementStatistic(.postsViewed, by: 1)
    }

    func recordCommunityVisit(_ community: String) async {
        guard settings?.collectLocalUsageStatistics != false, let persistence else { return }
        try? await persistence.recordCommunityVisit(community)
    }

    func recordFeedScroll(points: Int) async {
        guard points > 0, settings?.collectLocalUsageStatistics != false, let persistence else { return }
        try? await persistence.incrementStatistic(.feedScrollPoints, by: points)
    }

    /// Whether the reader has asked for the AutoModerator comment to arrive
    /// collapsed. Read once per tree rather than per comment.
    private var collapsesAutoModeratorComments: Bool {
        settings?.collapseAutoModeratorComments ?? false
    }

    /// Whether this comment should arrive collapsed.
    ///
    /// Top-level only, and matched on the author name -- which is what both
    /// references do (Hydra in `formatComments`, Winston in the comment row's
    /// `onAppear`). Reddit's own bot posts under exactly "AutoModerator"; the
    /// comparison is case-insensitive because nothing is gained by being
    /// strict about a name the reader never types.
    ///
    /// Decided here, where the tree is built, rather than when a row appears.
    /// A row-level rule has to remember whether it has already run, or it
    /// collapses the comment again every time the reader expands it and
    /// scrolls away -- which is why Winston needs its `commentViewLoaded`
    /// guard. Deciding once removes the state instead of guarding it.
    private func collapsesOnArrival(_ comment: CommentNode, depth: Int) -> Bool {
        guard collapsesAutoModeratorComments, depth == 0 else { return false }
        guard let author = comment.author?.username else { return false }
        return author.caseInsensitiveCompare("AutoModerator") == .orderedSame
    }

    func toggleFavorite(communityID: String) {
        guard let index = communities.firstIndex(where: { $0.id == communityID }) else { return }
        communities[index].isFavorite.toggle()
        guard let accountID else { return }
        let favorites = communities.filter(\.isFavorite).map(\.id).sorted()
        UserDefaults.standard.set(favorites, forKey: favoriteCommunitiesKey(accountID: accountID))
    }

    func toggleSubscribe(communityID: String) {
        guard let index = communities.firstIndex(where: { $0.id == communityID }) else { return }
        communities[index].isSubscribed.toggle()
    }

    private func updateLoadedFeedCache() {
        guard let loadedFeed else { return }
        let key = feedCacheKey(for: loadedFeed)
        feedCache[key] = FeedCacheEntry(
            posts: posts,
            filteredPostCount: filteredPostCount,
            nextPage: nextPage,
            // The revision these posts were filtered under, not whichever is
            // in force now: a mutation must not re-stamp a list as though it
            // had been filtered by the current settings.
            filterRevision: loadedFilterRevision,
            storedAt: feedCache[key]?.storedAt ?? .now
        )
    }

    func markRead(itemID: String) {
        guard let index = inbox.firstIndex(where: { $0.id == itemID }) else { return }
        inbox[index].isUnread = false
    }

    func markAllRead() {
        for index in inbox.indices { inbox[index].isUnread = false }
    }

    func toggleComment(id: String) {
        func updated(_ values: [CommentCardModel]) -> [CommentCardModel] {
            values.map { comment in
                var comment = comment
                if comment.id == id {
                    comment.isCollapsed.toggle()
                } else {
                    comment.children = updated(comment.children)
                }
                return comment
            }
        }
        comments = updated(comments)
    }

    func voteComment(id: String, value: Int) {
        func update(_ values: inout [CommentCardModel]) {
            for index in values.indices {
                if values[index].id == id {
                    let oldVote = values[index].vote
                    values[index].vote = value
                    values[index].score += value - oldVote
                    return
                }
                update(&values[index].children)
            }
        }
        update(&comments)
    }

    func performCommentVote(id: String, value: Int, accountID: AccountID) async throws {
        guard self.accountID == accountID, let oldVote = commentVote(id: id, in: comments) else {
            return
        }
        let generation = accountGeneration
        voteComment(id: id, value: value)
        do {
            let action = RedditAction.vote(
                fullname: IDNormalization.fullname(id, kind: "t1"), direction: value)
            if let authenticated {
                _ = try await authenticated.perform(action, accountID: accountID)
            } else if let reddit {
                _ = try await reddit.perform(action, account: accountID)
            }
        } catch {
            if isCurrentAccount(accountID, generation: generation) {
                voteComment(id: id, value: oldVote)
            }
            throw error
        }
    }

    private func commentVote(id: String, in values: [CommentCardModel]) -> Int? {
        for value in values {
            if value.id == id { return value.vote }
            if let nested = commentVote(id: id, in: value.children) { return nested }
        }
        return nil
    }

    private func localFavoriteCommunityNames(accountID: AccountID) -> Set<String> {
        Set(
            (UserDefaults.standard.stringArray(forKey: favoriteCommunitiesKey(accountID: accountID)) ?? [])
                .map(IDNormalization.community))
    }

    private func favoriteCommunitiesKey(accountID: AccountID) -> String {
        "communities.favorites.\(accountID.description)"
    }

    static let preview = OctonautFeatureStore()
}
