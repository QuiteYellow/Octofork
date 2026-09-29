import Foundation
import ImageIO
import UIKit

private actor OctonautImageDataCache {
    static let shared = OctonautImageDataCache()

    private let cache: URLCache
    private let session: URLSession
    private var inFlight: [URL: Task<Data, Error>] = [:]

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

    func data(for url: URL) async throws -> Data {
        if let task = inFlight[url] {
            return try await task.value
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad

        if let cached = cache.cachedResponse(for: request) {
            return cached.data
        }

        let task = Task { [session, cache] in
            let (data, response) = try await session.data(for: request)
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
        inFlight[url] = task

        do {
            let data = try await task.value
            inFlight[url] = nil
            return data
        } catch {
            inFlight[url] = nil
            throw error
        }
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

    static func image(for url: URL) async throws -> UIImage {
        if let image = cachedImage(for: url) {
            return image
        }

        let data = try await OctonautImageDataCache.shared.data(for: url)
        guard !Task.isCancelled else { throw CancellationError() }
        let image = try await decoded(data: data, maxPixelSize: defaultMaxPixelSize)
        guard !Task.isCancelled else { throw CancellationError() }
        decodedImages.setObject(image, forKey: url as NSURL, cost: image.decodedByteCount)
        return image
    }

    private static func decoded(data: Data, maxPixelSize: Int) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
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
