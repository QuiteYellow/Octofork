import SwiftUI

/// Aspect ratios measured from images that arrived without published
/// dimensions, remembered for as long as the app runs.
///
/// Keyed by the post's canonical media URL, deliberately not by the URL of
/// the copy that was measured. A tile asks Reddit for a copy sized to the
/// column it landed in, so the copy changes when the reader pinches -- and
/// keyed by the copy, every tile that had measured its own shape would look
/// that shape up under a key nothing had stored, fall back to the default
/// ratio, and reflow the grid on every zoom. The shape of a picture is a
/// property of the picture, not of which rung of the ladder it arrived on.
///
/// A tile drops its image when it scrolls out of view -- that is what keeps a
/// long grid cheap -- so without somewhere to keep the shape, a tile coming
/// back would forget how tall it was, fall back to the default ratio, and
/// shove everything below it. Remembering the ratio rather than the image
/// keeps the unloading and loses the reflow: a few bytes per tile against a
/// decoded bitmap.
@MainActor
enum GalleryTileRatios {
    private static var ratios: [URL: CGFloat] = [:]

    static func ratio(for url: URL) -> CGFloat? { ratios[url] }

    static func remember(_ ratio: CGFloat, for url: URL) {
        guard ratio.isFinite, ratio > 0 else { return }
        ratios[url] = ratio
    }
}

/// Where a gallery's posts come from.
///
/// Saved and Upvoted are lists the reader built deliberately, which makes them
/// exactly the kind of thing worth seeing as pictures rather than rows -- but
/// they load through the profile section endpoint, not the feed one, and they
/// never reach `store.posts`.
enum GallerySource: Hashable {
    case feed(FeedDescriptorModel)
    case userSection(username: String, section: UserSection)

    var title: String {
        switch self {
        case .feed: "Gallery"
        case .userSection(_, let section): "\(section.title) Gallery"
        }
    }
}

struct GalleryMediaItem: Identifiable {
    let post: PostCardModel
    let page: Int
    let url: URL

    var id: String { "\(post.id):\(page)" }
    var isVideo: Bool { post.isVideo || ["video", "gif", "embeddedVideo"].contains(post.mediaKind) }

    /// The copy to draw in a grid tile `displayWidth` points wide.
    ///
    /// This was `url` -- Reddit's full-size image -- so a screenful of tiles
    /// fetched a screenful of uploaders' originals to draw each one a couple
    /// of hundred points wide. `url` itself is untouched, and is still what
    /// opening the tile hands to the viewer.
    ///
    /// It was also a property, at one fixed width, and the comment here said
    /// why: `aspectRatio` keyed remembered shapes by this URL, so a tile that
    /// measured one copy and drew another would look its ratio up under a key
    /// nothing had stored. `GalleryTileRatios` is keyed by `url` now, which
    /// no width can change, which is what frees this to follow the column the
    /// tile actually landed in -- and it has to follow it: at one column a
    /// tile is nearly the width of the screen, and the copy chosen for a
    /// two-column grid is visibly soft blown up that far.
    ///
    /// The request is capped at `galleryTile`, which is the top of Reddit's
    /// pre-made ladder. See that constant for what asking for more costs.
    @MainActor func previewURL(displayWidth: CGFloat) -> URL? {
        guard !isVideo else { return post.thumbnailURL }
        return post.imageURL(
            page: page,
            displayWidth: min(displayWidth, OctonautImageDisplayWidth.galleryTile),
            scale: OctonautImageDisplayWidth.currentScale
        ) ?? url
    }

    /// The kinds the grid is for. Deliberately the same list
    /// `prefersMediaFirstPresentation` uses, because it answers the same
    /// question: is this post led by a picture or a video?
    ///
    /// `hasMedia` is not that question. It is `kind != "none"`, which a link
    /// post satisfies on the strength of its thumbnail -- which is how link
    /// previews were getting into a grid meant for images and video.
    static let displayableKinds: Set<String> = ["image", "gallery", "video", "gif", "embeddedVideo"]

    /// Reddit publishes dimensions for images and video, so a tile almost
    /// always knows its shape before it has fetched anything. Only the later
    /// pages of a multi-image gallery fall through: the post carries one set
    /// of preview dimensions, and they describe the first image.
    static let fallbackAspectRatio: CGFloat = 4.0 / 5.0

    /// Video that arrives without dimensions. Landscape, because a video with
    /// nothing published about it is far more often 16:9 than portrait.
    static let videoFallbackAspectRatio: CGFloat = 16.0 / 9.0

    /// The shapes a tile is allowed to take, from 9:16 to 16:9.
    ///
    /// Nothing else bounds a tile's height: Reddit carries infographics and
    /// comic strips at ratios like 1:8, and at a column width of ~195pt one
    /// of those renders as a 1,500pt bar down one side of the grid. It also
    /// wrecks the column balancing, whose worst case is the height of the
    /// tallest single tile -- so leaving this open cost both a sane grid and
    /// level columns. Anything outside the range is cropped to fill, which is
    /// what a grid of thumbnails is for; the full shape is one tap away.
    static let allowedRatios: ClosedRange<CGFloat> = (9.0 / 16.0)...(16.0 / 9.0)

    static func clamped(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio, allowedRatios.lowerBound), allowedRatios.upperBound)
    }

    /// The shape to lay this tile out at, both before its image arrives and
    /// after the image has been dropped again.
    @MainActor var aspectRatio: CGFloat {
        // A video is laid out at the video's shape, never at its poster's.
        // The poster Reddit ships is `thumbnail`, which is a small crop of
        // its own proportions -- so measuring it and keeping the answer made
        // the tile change height the moment the still arrived, and then
        // letterboxed the video inside a box that was the wrong shape.
        if isVideo {
            if let published = post.mediaAspectRatio, published > 0 {
                return Self.clamped(published)
            }
            return Self.videoFallbackAspectRatio
        }
        if let remembered = GalleryTileRatios.ratio(for: url) {
            return Self.clamped(remembered)
        }
        // A gallery publishes a size per image, so every page knows its own
        // shape -- not just the first.
        if post.galleryAspectRatios.indices.contains(page),
           let published = post.galleryAspectRatios[page], published > 0 {
            return Self.clamped(published)
        }
        if page == 0, let published = post.mediaAspectRatio, published > 0 {
            return Self.clamped(published)
        }
        return Self.fallbackAspectRatio
    }

    static func items(from posts: [PostCardModel]) -> [Self] {
        posts
            .filter { $0.hasMedia && displayableKinds.contains($0.mediaKind) }
            .flatMap { post in
                let urls = post.galleryURLs.isEmpty ? [post.mediaURL].compactMap { $0 } : post.galleryURLs
                return urls.enumerated().map { Self(post: post, page: $0.offset, url: $0.element) }
            }
    }
}
