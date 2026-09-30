import SwiftUI

/// Aspect ratios measured from images that arrived without published
/// dimensions, remembered for as long as the app runs.
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

    /// The copy to draw in a grid tile.
    ///
    /// This was `url` -- Reddit's full-size image -- so a screenful of tiles
    /// fetched a screenful of uploaders' originals to draw each one a couple
    /// of hundred points wide. `url` itself is untouched, and is still what
    /// opening the tile hands to the viewer.
    ///
    /// One property rather than a per-view choice, because `aspectRatio` keys
    /// remembered shapes by this URL: a tile that measured one copy and drew
    /// another would look its ratio up under a key nothing had stored.
    @MainActor var previewURL: URL? {
        guard !isVideo else { return post.thumbnailURL }
        return post.imageURL(
            page: page,
            displayWidth: OctonautImageDisplayWidth.galleryTile,
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
        if let url = previewURL, let remembered = GalleryTileRatios.ratio(for: url) {
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

@MainActor
struct GalleryMediaTile: View {
    let item: GalleryMediaItem
    var blursNSFW = true
    var blursSpoilers = true
    /// Whether this tile may play its video where it is. The grid decides,
    /// from the reader's autoplay setting and the connection.
    var autoplays = false
    let onOpen: () -> Void
    @State private var image: UIImage?
    @State private var failed = false
    /// Any part of the tile on screen, and still there a moment later. Gates
    /// mounting the player.
    ///
    /// The delay is the whole point. Mounting was gated on a sliver of the
    /// tile appearing, which during a scroll is every tile the thumb passes:
    /// measured on device, 6 to 17 `AVPlayer`s created per second, each one
    /// discarded before it had drawn anything. Creating them is the expensive
    /// half, so the grid was paying for players nobody saw. A tile the reader
    /// is scrolling past no longer reaches this; one they stop on reaches it
    /// in a sixth of a second, which is not a wait anyone notices.
    @State private var isOnScreen = false
    @State private var mountDelay: Task<Void, Never>?

    private static let mountDwell = Duration.milliseconds(160)
    /// Most of the tile on screen. Gates playing it, so a grid never has more
    /// than a couple of videos running at once.
    @State private var isWellOnScreen = false

    private var isBlurred: Bool {
        item.post.isSensitive(blurringNSFW: blursNSFW, blurringSpoilers: blursSpoilers)
    }

    /// A video tile shows the video itself, never a still of it -- the same
    /// as a feed row. Behind a blur it shows nothing but the blur.
    private var showsPlayer: Bool {
        item.isVideo && isOnScreen && !isBlurred
    }

    /// Mounted is not playing. The player exists as soon as the tile is on
    /// screen, so the first frame is there to look at, but it only runs when
    /// the reader has asked for autoplay and the tile is properly in view.
    private var playsInPlace: Bool {
        showsPlayer && autoplays && isWellOnScreen
    }

    /// Long enough to read as a fade, short enough not to lag behind a
    /// thumb. Matched in both directions so a tile that loads while scrolling
    /// past does not flash.
    private static let fade: Animation = .easeOut(duration: 0.22)

    var body: some View {
        Button(action: onOpen) {
            Color(uiColor: .secondarySystemBackground)
                // The item's ratio, never the loaded image's. Sizing from the
                // image meant every tile was square until its bytes arrived
                // and then jumped to its real shape, dragging the column with
                // it -- the popping this grid was known for.
                .aspectRatio(item.aspectRatio, contentMode: .fit)
                .overlay { content.animation(Self.fade, value: image == nil) }
                .clipped()
                .overlay(alignment: .bottomTrailing) { badge }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.post.isSensitive ? "Sensitive media. " : "")\(item.post.title), image \(item.page + 1) of \(max(1, item.post.galleryURLs.count))")
        .accessibilityHint("Opens the full screen media viewer")
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            mountDelay?.cancel()
            guard visible else {
                isOnScreen = false
                return
            }
            mountDelay = Task {
                try? await Task.sleep(for: Self.mountDwell)
                guard !Task.isCancelled else { return }
                isOnScreen = true
            }
        }
        .onScrollVisibilityChange(threshold: 0.6) { visible in
            isWellOnScreen = visible
        }
        .onDisappear {
            mountDelay?.cancel()
            isOnScreen = false
            isWellOnScreen = false
        }
        .task(id: item.previewURL) {
            // Deliberately not clearing `image` here. Scrolling away unmounts
            // the tile and takes its state with it, which is what actually
            // frees the bitmap -- so clearing on the way back in freed
            // nothing and only guaranteed a spinner between two identical
            // pictures, cache hit or not.
            failed = false
            // A video tile loads no still at all. Fetching Reddit's poster and
            // then swapping it for the player is what made video tiles flash;
            // the player shows black and then its own first frame, which is
            // how the feed rows have always done it.
            guard !item.isVideo, let url = item.previewURL else { return }
            do {
                let result = try await OctonautImageCache.image(for: url)
                guard !Task.isCancelled else { return }
                // Measured once, so a tile that has been off screen and back
                // still knows its shape while its image is being fetched.
                // Images only: what a video tile loads here is a poster, and
                // a poster's shape is not the tile's.
                if !item.isVideo, result.size.height > 0 {
                    GalleryTileRatios.remember(result.size.width / result.size.height, for: url)
                }
                withAnimation(Self.fade) { image = result }
            } catch is CancellationError {
                return
            } catch {
                failed = true
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if showsPlayer {
            OctonautVideoPlayer(
                url: item.url,
                audioURL: item.post.audioURL,
                muted: true,
                autoplay: playsInPlace,
                loops: true,
                aspectRatioHint: item.aspectRatio
            )
        } else if item.isVideo {
            // Off screen, or blurred. Black at the video's own shape, which is
            // what the player puts up while it builds -- so arriving on screen
            // changes what is in the box, never the size of it.
            Color.black
        } else if let image {
            poster(image)
                .transition(.opacity)
        } else if failed || item.previewURL == nil {
            Image(systemName: "photo.slash")
                .font(.title2).foregroundStyle(.secondary)
        } else {
            ProgressView()
                .transition(.opacity)
        }
    }

    /// The image, drawn to the tile's shape.
    ///
    /// Filling crops nothing in practice: the tile is already this image's own
    /// shape, either from the dimensions Reddit published or from the one
    /// measurement this image needed. Only a later page of a multi-image
    /// gallery, which has no published dimensions of its own, is ever cropped
    /// -- and only until it has been measured once.
    private func poster(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .blur(radius: isBlurred ? 24 : 0)
    }

    @ViewBuilder
    private var badge: some View {
        if (item.isVideo && !playsInPlace) || isBlurred {
            // Still worth marking a mounted-but-paused video: the first frame
            // alone does not say it is a video.
            Image(systemName: isBlurred ? "eye.slash.fill" : "play.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(6)
        }
    }
}
