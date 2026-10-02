import Foundation

struct DisplayableError: Error, Codable, Hashable, Sendable, LocalizedError {
    let title: String
    let message: String
    let recoverySuggestion: String?
    let isRetryable: Bool

    init(
        title: String = "Something went wrong",
        message: String,
        recoverySuggestion: String? = nil,
        isRetryable: Bool = true
    ) {
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.isRetryable = isRetryable
    }

    init(error: any Error) {
        if let displayable = error as? DisplayableError {
            self = displayable
        } else {
            self.init(message: error.localizedDescription)
        }
    }

    var errorDescription: String? { message }
}

enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading(previous: Value?)
    case loaded(Value, refreshedAt: Date)
    case failed(DisplayableError, previous: Value?)

    var value: Value? {
        switch self {
        case .idle, .loading(previous: nil), .failed(_, previous: nil): return nil
        case .loading(previous: let value), .failed(_, previous: let value): return value
        case .loaded(let value, _): return value
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

struct Listing<Element: Sendable>: Sendable {
    var items: [Element]
    var after: String?
    var before: String?
    var receivedAt: Date

    init(items: [Element], after: String? = nil, before: String? = nil, receivedAt: Date = .now) {
        self.items = items
        self.after = after
        self.before = before
        self.receivedAt = receivedAt
    }
}

struct RichText: Codable, Hashable, Sendable {
    struct Span: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable {
            case bold
            case italic
            case code
            case quote
            case heading
            case strikethrough
        }

        let range: Range<Int>
        let kind: Kind
    }

    struct Link: Codable, Hashable, Sendable, Identifiable {
        let id: UUID
        let range: Range<Int>
        let url: URL

        init(id: UUID = UUID(), range: Range<Int>, url: URL) {
            self.id = id
            self.range = range
            self.url = url
        }
    }

    var plainText: String
    var spans: [Span]
    var links: [Link]

    init(plainText: String, spans: [Span] = [], links: [Link] = []) {
        self.plainText = plainText
        self.spans = spans
        self.links = links
    }
}

enum EmbeddedVideoURL {
    static func embedURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              host == "streamable.com" || host == "www.streamable.com" else {
            return nil
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard let videoID = pathComponents.last, !videoID.isEmpty else { return nil }
        if pathComponents.first?.lowercased() == "s" { return url }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        components?.host = "streamable.com"
        components?.path = "/s/\(videoID)"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}

struct CommunityReference: Codable, Hashable, Sendable, Identifiable {
    let name: String
    var displayName: String
    var iconURL: URL?

    var id: String { IDNormalization.community(name) }

    init(name: String, displayName: String? = nil, iconURL: URL? = nil) {
        self.name = IDNormalization.community(name)
        self.displayName = displayName ?? "r/\(IDNormalization.community(name))"
        self.iconURL = iconURL
    }
}

struct UserReference: Codable, Hashable, Sendable, Identifiable {
    let username: String
    var displayName: String { "u/\(username)" }
    var id: String { username.lowercased() }
}

struct Flair: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var text: String
    var backgroundColor: String?
    var textColor: String?
    var emojiURLs: [URL]

    init(
        id: String,
        text: String,
        backgroundColor: String? = nil,
        textColor: String? = nil,
        emojiURLs: [URL] = []
    ) {
        self.id = id
        self.text = text
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.emojiURLs = emojiURLs
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, backgroundColor, textColor, emojiURLs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        backgroundColor = try container.decodeIfPresent(String.self, forKey: .backgroundColor)
        textColor = try container.decodeIfPresent(String.self, forKey: .textColor)
        emojiURLs = try container.decodeIfPresent([URL].self, forKey: .emojiURLs) ?? []
    }
}

enum VoteState: String, Codable, Hashable, Sendable {
    case upvoted
    case downvoted
    case none
    case unknown

    var direction: Int {
        switch self {
        case .upvoted: return 1
        case .downvoted: return -1
        case .none, .unknown: return 0
        }
    }
}

/// One of the copies Reddit has already made of an image.
///
/// Reddit publishes a ladder of these beside every preview -- roughly 108,
/// 216, 320, 640, 960 and 1080 pixels wide -- and beside every gallery entry.
/// They exist on Reddit's CDN whether or not anyone asks for them, so using
/// one costs nothing that fetching the original does not cost more of.
struct ImageVariant: Codable, Hashable, Sendable {
    let url: URL
    let width: Int
    let height: Int
}

extension Array where Element == ImageVariant {
    /// The copy to fetch for an image that will be drawn `pixels` wide.
    ///
    /// REDDIT-MAP-003 asks for "a preview resolution close to display pixels,
    /// accounting for scale". Close, and deliberately not "at least": Reddit's
    /// ladder stops near 1080 pixels, which is narrower than a current phone's
    /// full-bleed width once the display scale is applied. A strict
    /// at-least-this-wide rule would therefore match nothing on the one image
    /// that matters most -- the feed's own -- and fall back to the uploader's
    /// original, which is the behaviour this exists to replace.
    ///
    /// So the top of the ladder is used when nothing covers the request. A
    /// photograph drawn from a 1080-pixel copy into 1206 device pixels is not
    /// tellable apart at arm's length, and the original behind it is routinely
    /// several megabytes.
    ///
    /// Returns nil only when Reddit published no ladder at all, which leaves
    /// the caller holding its own full-size URL.
    func covering(_ pixels: Int) -> ImageVariant? {
        guard !isEmpty else { return nil }
        let ascending = sorted { $0.width < $1.width }
        return ascending.first { $0.width >= pixels } ?? ascending.last
    }

    /// The largest copy Reddit made, for when the original is too expensive
    /// to be worth its extra detail.
    var largest: ImageVariant? {
        self.max { $0.width < $1.width }
    }
}

struct GalleryItem: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let url: URL
    var thumbnailURL: URL?
    var width: Int?
    var height: Int?
    var caption: String?
    /// Reddit's smaller copies of this entry, if it published any.
    var variants: [ImageVariant] = []
}

struct Poll: Codable, Hashable, Sendable, Identifiable {
    struct Option: Codable, Hashable, Sendable, Identifiable {
        let id: String
        let text: String
        var voteCount: Int?
    }

    let id: String
    let options: [Option]
    var totalVoteCount: Int?
    var userChoice: String?
}

struct LinkMetadata: Codable, Hashable, Sendable {
    var title: String?
    var description: String?
    var siteName: String?
    var imageURL: URL?
    var canonicalURL: URL?

    init(title: String? = nil, description: String? = nil, siteName: String? = nil, imageURL: URL? = nil, canonicalURL: URL? = nil) {
        self.title = title
        self.description = description
        self.siteName = siteName
        self.imageURL = imageURL
        self.canonicalURL = canonicalURL
    }
}

enum PostMedia: Codable, Hashable, Sendable {
    case none
    /// `url` is always Reddit's full-size image. `variants` are its smaller
    /// copies, which is what anything drawing the image at a known size
    /// should be choosing from.
    case image(url: URL, thumbnailURL: URL?, width: Int?, height: Int?, variants: [ImageVariant] = [])
    case gallery(items: [GalleryItem])
    case video(url: URL, audioURL: URL?, thumbnailURL: URL?, isGIF: Bool, width: Int?, height: Int?)
    case link(url: URL, metadata: LinkMetadata?)
    case poll(Poll)
    case unsupported(permalink: URL?, kind: String?)

    var kind: String {
        switch self {
        case .none: return "none"
        case .image: return "image"
        case .gallery: return "gallery"
        case .video(_, _, _, let isGIF, _, _): return isGIF ? "gif" : "video"
        case .link(let url, _):
            return EmbeddedVideoURL.embedURL(for: url) == nil ? "link" : "embeddedVideo"
        case .poll: return "poll"
        case .unsupported: return "unsupported"
        }
    }

    var primaryURL: URL? {
        switch self {
        case .none, .poll: return nil
        case .image(let url, _, _, _, _), .video(let url, _, _, _, _, _), .link(let url, _): return url
        case .gallery(let items): return items.first?.url
        case .unsupported(let permalink, _): return permalink
        }
    }
}

struct CrosspostReference: Codable, Hashable, Sendable {
    let postID: String
    let permalink: URL
    let community: CommunityReference
    let title: String
}

struct Post: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let fullname: String
    let permalink: URL
    let community: CommunityReference
    let author: UserReference?
    var authorFlair: Flair?
    var title: String
    var body: RichText?
    var flair: Flair?
    var createdAt: Date
    var score: Int?
    var commentCount: Int
    var vote: VoteState
    var isSaved: Bool
    var isHidden: Bool
    var isNSFW: Bool
    var isSpoiler: Bool
    var isLocked: Bool
    var isArchived: Bool
    var isSticky: Bool
    var media: PostMedia
    var crosspost: CrosspostReference?

    init(
        id: String,
        fullname: String? = nil,
        permalink: URL,
        community: CommunityReference,
        author: UserReference? = nil,
        authorFlair: Flair? = nil,
        title: String,
        body: RichText? = nil,
        flair: Flair? = nil,
        createdAt: Date = .now,
        score: Int? = nil,
        commentCount: Int = 0,
        vote: VoteState = .unknown,
        isSaved: Bool = false,
        isHidden: Bool = false,
        isNSFW: Bool = false,
        isSpoiler: Bool = false,
        isLocked: Bool = false,
        isArchived: Bool = false,
        isSticky: Bool = false,
        media: PostMedia = .none,
        crosspost: CrosspostReference? = nil
    ) {
        self.id = id
        self.fullname = fullname ?? IDNormalization.fullname(id, kind: "t3")
        self.permalink = permalink
        self.community = community
        self.author = author
        self.authorFlair = authorFlair
        self.title = title
        self.body = body
        self.flair = flair
        self.createdAt = createdAt
        self.score = score
        self.commentCount = commentCount
        self.vote = vote
        self.isSaved = isSaved
        self.isHidden = isHidden
        self.isNSFW = isNSFW
        self.isSpoiler = isSpoiler
        self.isLocked = isLocked
        self.isArchived = isArchived
        self.isSticky = isSticky
        self.media = media
        self.crosspost = crosspost
    }
}

struct MoreCommentsNode: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let parentFullname: String
    let childIDs: [String]
    var count: Int?
}

struct DeletedCommentNode: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let parentFullname: String
    var reason: String
}

struct CommentNode: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let fullname: String
    let parentFullname: String
    var author: UserReference?
    var authorFlair: Flair? = nil
    var body: RichText?
    var createdAt: Date
    var score: Int?
    var vote: VoteState
    var isSaved: Bool
    var isLocked: Bool
    var isDistinguished: Bool
    var children: [CommentTreeNode]
}

/// A comment returned from a user's profile listing. Reddit includes the
/// parent post metadata on this endpoint, which lets the profile screen open
/// the related post directly.
struct UserComment: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let fullname: String
    let parentFullname: String
    var author: UserReference?
    var body: RichText?
    var createdAt: Date
    var score: Int?
    var vote: VoteState
    var isSaved: Bool
    var isLocked: Bool
    var isDistinguished: Bool
    var postTitle: String?
    var postPermalink: URL?
    var community: CommunityReference?

    init(
        id: String,
        fullname: String? = nil,
        parentFullname: String = "",
        author: UserReference? = nil,
        body: RichText? = nil,
        createdAt: Date = .now,
        score: Int? = nil,
        vote: VoteState = .unknown,
        isSaved: Bool = false,
        isLocked: Bool = false,
        isDistinguished: Bool = false,
        postTitle: String? = nil,
        postPermalink: URL? = nil,
        community: CommunityReference? = nil
    ) {
        self.id = id
        self.fullname = fullname ?? IDNormalization.fullname(id, kind: "t1")
        self.parentFullname = parentFullname
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.score = score
        self.vote = vote
        self.isSaved = isSaved
        self.isLocked = isLocked
        self.isDistinguished = isDistinguished
        self.postTitle = postTitle
        self.postPermalink = postPermalink
        self.community = community
    }
}

enum CommentTreeNode: Codable, Hashable, Sendable, Identifiable {
    case comment(CommentNode)
    case more(MoreCommentsNode)
    case deleted(DeletedCommentNode)

    var id: String {
        switch self {
        case .comment(let node): return node.id
        case .more(let node): return node.id
        case .deleted(let node): return node.id
        }
    }
}

struct PostThread: Codable, Hashable, Sendable, Identifiable {
    let post: Post
    var comments: [CommentTreeNode]
    var id: String { post.id }
}

struct Community: Codable, Hashable, Sendable, Identifiable {
    let reference: CommunityReference
    var title: String?
    var description: RichText?
    var subscribers: Int?
    var isSubscribed: Bool
    var isFavorite: Bool
    var isQuarantined: Bool
    var isPrivate: Bool
    var isBanned: Bool
    var rules: [Rule]
    var moderators: [UserReference]
    var id: String { reference.id }
}

struct Rule: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var shortName: String
    var description: RichText?
    var kind: String?
}

struct WikiPage: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let community: CommunityReference
    let path: String
    var title: String
    var body: RichText
    var revision: String?
}

struct UserProfile: Codable, Hashable, Sendable, Identifiable {
    let reference: UserReference
    var avatarURL: URL?
    var createdAt: Date?
    var karma: Int?
    var about: RichText?
    var isBlocked: Bool
    var isFollowing: Bool
    var id: String { reference.id }
}

struct InboxItem: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let fullname: String
    var subject: String
    var body: RichText?
    var author: UserReference?
    var community: CommunityReference?
    var postPermalink: URL?
    var createdAt: Date
    var isRead: Bool
    var kind: String
}

struct Message: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var conversationID: String?
    var sender: UserReference?
    var recipient: UserReference?
    var subject: String
    var body: RichText
    var createdAt: Date
    var isRead: Bool
}

struct Multireddit: Codable, Hashable, Sendable, Identifiable {
    let owner: String
    let name: String
    var displayName: String
    var description: RichText?
    var communities: [CommunityReference]
    var isOwner: Bool
    var id: String { "\(owner.lowercased())/\(name.lowercased())" }
}
