import Foundation
import ImageIO
import UIKit

/// Why an image is being loaded, and therefore what it is allowed to compete
/// with.
///
/// `REDDIT-ERROR-003` asks for concurrency to be bounded by work type, and for
/// visible reads to be favoured over prefetch. Without a distinction at this
/// level the image twenty rows ahead and the image under the reader's thumb
/// are indistinguishable requests.
enum OctonautImageLoadPriority: Sendable {
    /// A row on screen, or media the reader has just opened.
    case visible
    /// A row the reader has not reached.
    case prefetch

    /// The HTTP/2 stream weight. Reddit's image hosts multiplex every image
    /// onto one connection, so this -- rather than the order the requests were
    /// made in -- decides which of them gets the bandwidth.
    var httpPriority: Float {
        switch self {
        case .visible: URLSessionTask.highPriority
        case .prefetch: URLSessionTask.lowPriority
        }
    }

    /// The priority the downsampling decode runs at. The decode is the more
    /// expensive half of preparing an image, and for a prefetch there is
    /// nobody waiting on it.
    var decodePriority: TaskPriority {
        switch self {
        case .visible: .userInitiated
        case .prefetch: .utility
        }
    }
}

/// Stamps an HTTP priority onto a session task at the moment it is created.
///
/// `URLSession`'s async `data(for:)` never hands back its task, so creation is
/// the only reachable moment. `@unchecked Sendable` only because `NSObject` is
/// not `Sendable`: the single stored property is an immutable `Float`.
private final class OctonautImageRequestPriority: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let visible = OctonautImageRequestPriority(OctonautImageLoadPriority.visible.httpPriority)
    static let prefetch = OctonautImageRequestPriority(OctonautImageLoadPriority.prefetch.httpPriority)

    private let priority: Float

    init(_ priority: Float) {
        self.priority = priority
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        task.priority = priority
    }
}

private actor OctonautImageDataCache {
    static let shared = OctonautImageDataCache()

    private let cache: URLCache
    private let session: URLSession
    private var inFlight: [URL: Task<Data, Error>] = [:]
    /// The subset of `inFlight` that no visible row is waiting on, and which a
    /// memory warning may therefore cancel.
    private var warming: Set<URL> = []

    init() {
        let cache = URLCache(
            memoryCapacity: 64 * 1_024 * 1_024,
            diskCapacity: 500 * 1_024 * 1_024,
            diskPath: "OctonautImages"
        )
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        self.cache = cache
        self.session = URLSession(configuration: configuration)
    }

    /// The actor's only job is the in-flight table: one request per URL, however
    /// many rows ask for it. Everything that blocks -- the cache lookup, the
    /// transfer, the write back -- happens in `load`, which is `nonisolated` and
    /// so runs off this actor.
    func data(for url: URL, priority: OctonautImageLoadPriority) async throws -> Data {
        if let task = inFlight[url] {
            // A visible read that lands on a warming request adopts it, so a
            // memory warning cannot cancel the download out from under a row
            // that is now waiting for it.
            if priority == .visible { warming.remove(url) }
            return try await task.value
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad

        let delegate = priority == .prefetch
            ? OctonautImageRequestPriority.prefetch
            : OctonautImageRequestPriority.visible
        let task = Task { [session, cache] in
            try await Self.load(
                request: request,
                session: session,
                cache: cache,
                delegate: delegate
            )
        }
        inFlight[url] = task
        if priority == .prefetch { warming.insert(url) }

        do {
            let data = try await task.value
            forget(url)
            return data
        } catch {
            forget(url)
            throw error
        }
    }

    /// Cancels the downloads no row is waiting for.
    ///
    /// `PERF-003` requires a memory warning to cancel prefetch. A response in
    /// flight holds its bytes in memory until it completes, so a screenful of
    /// warming images is exactly the wrong thing to be holding when the system
    /// asks for memory back.
    func cancelWarming() {
        for url in warming {
            inFlight.removeValue(forKey: url)?.cancel()
        }
        warming.removeAll()
    }

    private func forget(_ url: URL) {
        inFlight[url] = nil
        warming.remove(url)
    }

    /// `nonisolated` on purpose, and the whole point of this type's shape.
    ///
    /// An unstructured `Task` started inside an actor inherits that actor's
    /// isolation, so a body like this one written inline runs *on* the actor:
    /// `URLCache.cachedResponse(for:)` reads the disk and
    /// `storeCachedResponse(_:for:)` writes it, both synchronously, on the one
    /// executor every image in the app funnels through. One image's disk access
    /// then delays every other image's request, including the one the reader is
    /// looking at. A `nonisolated` async function is the hop off.
    private nonisolated static func load(
        request: URLRequest,
        session: URLSession,
        cache: URLCache,
        delegate: any URLSessionTaskDelegate
    ) async throws -> Data {
        if let cached = cache.cachedResponse(for: request) {
            return cached.data
        }

        let (data, response) = try await session.data(for: request, delegate: delegate)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }

        // Reddit's image hosts do not always return cache headers that are
        // useful to an app feed. Store a replaceable local copy explicitly.
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: data, storagePolicy: .allowed),
            for: request
        )
        return data
    }

    func configure(diskCapacityMB: Int) {
        cache.diskCapacity = max(diskCapacityMB, 1) * 1_024 * 1_024
    }

    func diskUsage() -> Int {
        cache.currentDiskUsage
    }

    func removeAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        warming.removeAll()
        cache.removeAllCachedResponses()
    }
}

/// The widths, in points, that the app draws Reddit images at.
///
/// Both the row that shows an image and the preloader that warms it ahead of
/// the row choose their copy from these, so the two always agree and the
/// prefetch is never spent on a URL the row will not ask for.
///
/// They are constants rather than measurements on purpose. Reddit's ladder
/// tops out near 1080 pixels, so every full-width row on every current device
/// -- 320 points at 3x and 680 points at 2x alike -- resolves to the same top
/// rung, and measuring would separate values that cannot select differently.
/// What the numbers have to get right is the order of magnitude, so that a
/// 70-point thumbnail stops fetching a copy sized for a full-bleed card.
enum OctonautImageDisplayWidth {
    /// A full-bleed image in a feed or post-detail row.
    static let card: CGFloat = 430
    /// The square preview on a compact row. Matches its 70-point frame.
    static let compactThumbnail: CGFloat = 70
    /// One tile of the gallery grid, at its narrowest.
    static let galleryTile: CGFloat = 180

    /// The width to choose a copy for one page of a post's inline media.
    ///
    /// The inline strip shows two images side by side when there is more than
    /// one. Note that this is the width a copy is *chosen* for, not the width
    /// it is *drawn* at -- the strip lays out from real geometry. Keeping the
    /// two separate is deliberate: the preloader has no geometry, and a
    /// prefetch that picked a copy two pixels away from the row's choice
    /// would fetch the image twice instead of once.
    static func inlinePage(count: Int) -> CGFloat {
        count > 1 ? card / 2 : card
    }
}

@MainActor
extension OctonautImageDisplayWidth {
    /// The display scale for code with no SwiftUI environment to read it from
    /// -- the preloader, which has to pick the same copy a view will.
    ///
    /// Views use `@Environment(\.displayScale)` instead, which is the same
    /// number and survives being rendered somewhere unusual.
    static var currentScale: CGFloat {
        let scale = UITraitCollection.current.displayScale
        return scale > 0 ? scale : 3
    }
}

@MainActor
enum OctonautImageCache {
    /// Reddit's preview hosts routinely serve 3000-4000px sources. Decoding one
    /// at full size costs roughly 24MB of RAM, and because `UIImage(data:)`
    /// defers the decode to draw time on the main thread, that cost lands in the
    /// middle of a scroll. Downsampling to a cap that still covers a zoomed
    /// full-screen view keeps the feed smooth without a visible quality loss.
    static let defaultMaxPixelSize = 2048

    private static let decodedImages: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()

    static func image(
        for url: URL,
        priority: OctonautImageLoadPriority = .visible
    ) async throws -> UIImage {
        if let image = cachedImage(for: url) {
            return image
        }

        let data = try await OctonautImageDataCache.shared.data(for: url, priority: priority)
        guard !Task.isCancelled else { throw CancellationError() }
        let image = try await decoded(
            data: data,
            maxPixelSize: defaultMaxPixelSize,
            priority: priority.decodePriority
        )
        guard !Task.isCancelled else { throw CancellationError() }
        decodedImages.setObject(image, forKey: url as NSURL, cost: image.decodedByteCount)
        return image
    }

    /// Starts dropping decoded images whenever the system reports pressure.
    ///
    /// Registered once at launch rather than lazily, so that the response does
    /// not depend on some view having happened to touch the cache first. Calling
    /// it again is harmless.
    static func beginRespondingToMemoryWarnings() {
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { respondToMemoryWarning() }
        }
    }

    private static var memoryWarningObserver: (any NSObjectProtocol)?

    /// Drops every decoded image and cancels the downloads no row is waiting
    /// for.
    ///
    /// `PERF-003` requires a memory warning to cancel prefetch and discard
    /// decoded off-screen images. A visible row holds its own strong reference
    /// to the image it drew, so emptying this cache blanks nothing on screen --
    /// what it gives back is the rows that have scrolled away.
    static func respondToMemoryWarning() {
        decodedImages.removeAllObjects()
        cancelWarmingDownloads()
    }

    /// Stops the downloads that only a prefetch is waiting for, leaving every
    /// visible read in flight. Separate from `respondToMemoryWarning()` because
    /// Low Power Mode has to stop warming without throwing away images the
    /// reader can see.
    static func cancelWarmingDownloads() {
        Task { await OctonautImageDataCache.shared.cancelWarming() }
    }

    private static func decoded(
        data: Data,
        maxPixelSize: Int,
        priority: TaskPriority
    ) async throws -> UIImage {
        try await Task.detached(priority: priority) {
            try decodeOffMainThread(data: data, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Produces a fully decoded, downsampled image so the render pass has no
    /// work left to do. `kCGImageSourceShouldCacheImmediately` forces the
    /// decode here, on this background thread, rather than at draw time.
    nonisolated private static func decodeOffMainThread(
        data: Data,
        maxPixelSize: Int
    ) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw URLError(.cannotDecodeContentData)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else {
            // Some formats refuse the thumbnail path; keep the original decode.
            guard let image = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            return image
        }

        return UIImage(cgImage: cgImage)
    }

    static func cachedImage(for url: URL) -> UIImage? {
#if DEBUG
        if url.scheme == "octonaut-screenshot", let name = url.host,
           let path = Bundle.main.path(forResource: name, ofType: "png") {
            return UIImage(contentsOfFile: path)
        }
#endif
        return decodedImages.object(forKey: url as NSURL)
    }

    static func configure(diskCapacityMB: Int) async {
        await OctonautImageDataCache.shared.configure(diskCapacityMB: diskCapacityMB)
    }

    static func diskUsage() async -> Int {
        await OctonautImageDataCache.shared.diskUsage()
    }

    static func removeAll() async {
        decodedImages.removeAllObjects()
        await OctonautImageDataCache.shared.removeAll()
    }
}

private extension UIImage {
    /// `NSCache` budgets against whatever cost it is handed. Charging the
    /// compressed byte count for a decoded bitmap understates the real
    /// footprint by roughly 50x, so the cache overshoots its limit, hits system
    /// memory pressure, and gets purged wholesale mid-scroll.
    var decodedByteCount: Int {
        guard let cgImage else { return 1 }
        return max(cgImage.bytesPerRow * cgImage.height, 1)
    }
}
