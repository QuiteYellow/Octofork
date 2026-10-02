import AVKit
import Foundation
import Network
import Observation
import Photos
import SwiftUI
import UIKit
import WebKit

private struct OctonautExportableMedia: Identifiable {
    let id = UUID()
    let url: URL
}

private struct OctonautFileExporter: UIViewControllerRepresentable {
    let fileURL: URL
    let onSaved: () -> Void
    var onDismiss: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onSaved: onSaved, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSaved: () -> Void
        let onDismiss: (() -> Void)?

        init(onSaved: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
            self.onSaved = onSaved
            self.onDismiss = onDismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            onSaved()
            onDismiss?()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss?()
        }
    }
}

private actor OctonautMediaSaveCoordinator {
    enum SaveError: LocalizedError {
        case downloadFailed
        case photoAccessDenied

        var errorDescription: String? {
            switch self {
            case .downloadFailed: return "The media could not be downloaded."
            case .photoAccessDenied: return "Allow Octonaut to add media to Photos in Settings, then try again."
            }
        }
    }

    private let fileManager = FileManager.default

    func downloadImage(from sourceURL: URL) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: sourceURL)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw SaveError.downloadFailed
        }

        let fileExtension = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        let outputURL = fileManager.temporaryDirectory
            .appending(path: "OctonautImage-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try fileManager.moveItem(at: temporaryURL, to: outputURL)
        return outputURL
    }

    func saveToPhotos(fileURL: URL, isVideo: Bool) async throws {
        try await saveToPhotos(fileURLs: [fileURL], isVideo: isVideo)
    }

    func saveToPhotos(fileURLs: [URL], isVideo: Bool) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw SaveError.photoAccessDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            for fileURL in fileURLs {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: isVideo ? .video : .photo, fileURL: fileURL, options: nil)
            }
        }
    }
}

/// Why a player does or does not carry its post's audio.
///
/// Reddit serves DASH video and audio as separate files, and every step of
/// merging them can fail in a way that still produces a playable asset -- just
/// a silent one. Recording the outcome makes a failed mux distinguishable from
/// a video that genuinely has no sound.
enum OctonautMuxOutcome: Equatable, Sendable {
    /// No separate audio to merge: a GIF, or a self-contained file.
    case notApplicable
    case merged
    case videoOnly(reason: String)

    var failureReason: String? {
        if case .videoOnly(let reason) = self { return reason }
        return nil
    }
}

/// The default `soloAmbient` category interrupts other audio even when a feed
/// player is muted. Playback with mixing keeps other apps audible while feed
/// videos run and lets full screen video audio work with the silent switch on.
/// Every `AVAudioSession` call is a synchronous XPC round trip to
/// mediaserverd. Making those from the main thread on each viewer open and
/// close does not merely stall the UI -- under the churn of scrolling, opening
/// and dismissing repeatedly it takes the media server down with it, and once
/// that happens every AVPlayer in the process is dead and playback cannot
/// recover without relaunching:
///
///   AVAudioSession_iOS.mm:990  Invalid XPC connection, probably media server died
///   PlayerRemoteXPC signalled err=-12860 (repeatedly, thereafter)
///
/// So the work happens on a private serial queue, the category is set once
/// rather than per playback, activations are counted instead of toggled, and a
/// deactivation is allowed to settle first -- a quick dismiss-then-reopen never
/// reaches the session at all.
final class OctonautAudioSession: @unchecked Sendable {
    static let shared = OctonautAudioSession()

    /// All mutable state below is confined to this queue, which is what makes
    /// the unchecked `Sendable` conformance sound.
    private let queue = DispatchQueue(label: "com.octonaut.audio-session", qos: .userInitiated)
    private var isCategoryConfigured = false
    private var activations = 0
    private var pendingDeactivation: DispatchWorkItem?

    private init() {}

    static func prepareForMutedFeedPlayback() async {
        await withCheckedContinuation { continuation in
            shared.queue.async {
                shared.configureCategoryIfNeeded()
                continuation.resume()
            }
        }
    }

    static func activatePlayback() { shared.begin() }
    static func deactivate() { shared.end() }

    private func configureCategoryIfNeeded() {
        guard !isCategoryConfigured else { return }
        // A muted AVPlayer can still activate the app's audio session. Mix
        // with other apps so scrolling past a feed video leaves their audio on.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.mixWithOthers]
            )
            isCategoryConfigured = true
        } catch {
            // Retry on the next activation if mediaserverd is temporarily down.
        }
    }

    private func begin() {
        queue.async { [self] in
            pendingDeactivation?.cancel()
            pendingDeactivation = nil

            configureCategoryIfNeeded()

            activations += 1
            guard activations == 1 else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    private func end() {
        queue.async { [self] in
            activations = max(0, activations - 1)
            guard activations == 0 else { return }

            pendingDeactivation?.cancel()
            let work = DispatchWorkItem { [self] in
                guard activations == 0 else { return }
                try? AVAudioSession.sharedInstance()
                    .setActive(false, options: [.notifyOthersOnDeactivation])
                pendingDeactivation = nil
            }
            pendingDeactivation = work
            queue.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }
}

@MainActor
private enum OctonautAVPlayerFactory {
    fileprivate struct Playback {
        let player: AVPlayer
        let aspectRatio: CGFloat
        var muxOutcome: OctonautMuxOutcome = .notApplicable
    }

    static func makePlayer(videoURL: URL, audioURL: URL?) async -> Playback {
        let videoAsset = AVURLAsset(url: videoURL)
        let aspectRatio = await aspectRatio(for: videoAsset)
        guard let audioURL, audioURL != videoURL else {
            return Playback(
                player: localPlaybackPlayer(asset: videoAsset),
                aspectRatio: aspectRatio,
                muxOutcome: .notApplicable
            )
        }
        // Loading the two separately stops an audio failure -- the common
        // case, since the audio filename is guessed -- from being reported as
        // a video failure and from poisoning the video asset.
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        } catch is CancellationError {
            // A cancelled task is not a mux failure; the view is going away.
            return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .notApplicable
            )
        } catch {
            return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "video track load failed: \(error.localizedDescription)")
            )
        }

        let audio = await loadAudio(preferred: audioURL, videoURL: videoURL)
        let audioAsset = audio.asset
        let audioTracks = audio.tracks
        if let failure = audio.failure {
            return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: failure)
            )
        }
        guard let videoTrack = videoTracks.first else {
            return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "asset has no video track")
            )
        }

        let composition = AVMutableComposition()
        guard let duration = try? await videoAsset.load(.duration) else {
            return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "video duration unavailable")
            )
        }
        do {
            guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "could not add composition video track")
            )
            }
            try compositionVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
            compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

            // An audio URL that yields no usable track is the quiet failure
            // worth surfacing: the video plays, just silently.
            guard let audioTrack = audioTracks.first else {
                return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "audio URL returned no audio track")
            )
            }
            guard let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "could not add composition audio track")
            )
            }
            let loadedAudioDuration = (try? await audioAsset.load(.duration)) ?? duration
            let audioDuration = CMTimeMinimum(duration, loadedAudioDuration)
            try compositionAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: audioTrack, at: .zero)

            return Playback(
                player: localPlaybackPlayer(item: AVPlayerItem(asset: composition)),
                aspectRatio: aspectRatio,
                muxOutcome: .merged
            )
        } catch {
            return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "composition failed: \(error.localizedDescription)")
            )
        }
    }

    /// Reddit does not always publish the DASH audio filename the codec
    /// guesses from the video URL. The manifest is authoritative about which
    /// representations exist, so a miss is retried against it -- fetched only
    /// on failure, so the common case costs nothing.
    private static func loadAudio(
        preferred audioURL: URL,
        videoURL: URL
    ) async -> (asset: AVURLAsset, tracks: [AVAssetTrack], failure: String?) {
        if let hit = await audioTracks(at: audioURL) {
            return (hit.asset, hit.tracks, nil)
        }

        if let resolved = await manifestAudioURL(for: videoURL), resolved != audioURL {
            if let hit = await audioTracks(at: resolved) {
                return (hit.asset, hit.tracks, nil)
            }
            return (
                AVURLAsset(url: audioURL), [],
                "no audio at \(audioURL.lastPathComponent) or \(resolved.lastPathComponent)"
            )
        }

        return (
            AVURLAsset(url: audioURL), [],
            "no audio at \(audioURL.lastPathComponent); manifest lists none"
        )
    }

    private static func audioTracks(
        at url: URL
    ) async -> (asset: AVURLAsset, tracks: [AVAssetTrack])? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              !tracks.isEmpty else {
            return nil
        }
        return (asset, tracks)
    }

    private static func manifestAudioURL(for videoURL: URL) async -> URL? {
        guard let manifestURL = RedditDASHManifest.manifestURL(for: videoURL),
              let (data, _) = try? await URLSession.shared.data(from: manifestURL) else {
            return nil
        }
        return RedditDASHManifest.media(from: data, manifestURL: manifestURL)?.audio
    }

    /// Builds the fallback player from a fresh asset. The one whose load just
    /// failed carries that failure cached, and an item made from it can refuse
    /// to ever become ready to play -- a silent video would become no video.
    private static func localPlaybackPlayer(url: URL) -> AVPlayer {
        localPlaybackPlayer(item: AVPlayerItem(asset: AVURLAsset(url: url)))
    }

    /// A player for media that needs no composing, built synchronously.
    ///
    /// Nothing here touches the network, so a row can have a player in the
    /// same frame it asks for one. That is the whole point: a row that awaits
    /// its player has a state where it has none, and that state is the black
    /// frame and spinner. AVFoundation loads the asset behind the player.
    static func makeStreamingPlayer(url: URL) -> AVPlayer {
        localPlaybackPlayer(url: url)
    }

    /// Measures a video whose post published no dimensions. Returns nil when
    /// the asset cannot answer -- an HLS playlist has no asset tracks to
    /// read -- so a caller can keep its own default rather than adopt 16:9.
    static func measuredAspectRatio(for url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return nil
        }
        let displaySize = naturalSize.applying(transform)
        let width = abs(displaySize.width)
        let height = abs(displaySize.height)
        guard width > 0, height > 0 else { return nil }
        return width / height
    }

    private static func aspectRatio(for asset: AVAsset) async -> CGFloat {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let preferredTransform = try? await track.load(.preferredTransform) else {
            return 16 / 9
        }
        let displaySize = naturalSize.applying(preferredTransform)
        let width = abs(displaySize.width)
        let height = abs(displaySize.height)
        guard width > 0, height > 0 else { return 16 / 9 }
        return width / height
    }

    private static func localPlaybackPlayer(asset: AVAsset) -> AVPlayer {
        localPlaybackPlayer(item: AVPlayerItem(asset: asset))
    }

    private static func localPlaybackPlayer(item: AVPlayerItem) -> AVPlayer {
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = false
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        return player
    }
}

/// Hands playback back and forth between a feed row and the full screen
/// viewer.
///
/// Two problems it solves. A feed row behind a `fullScreenCover` never gets
/// `onDisappear`, so without this it keeps playing underneath the viewer. And
/// the viewer builds its own `AVPlayer`, so without a shared playhead it would
/// always restart from zero rather than continuing from wherever the row had
/// reached.
@MainActor
@Observable
final class OctonautPlaybackCoordinator {
    static let shared = OctonautPlaybackCoordinator()

    /// While true the viewer owns playback and feed rows stay paused.
    private(set) var isFullScreenActive = false

    @ObservationIgnored private var positions: [URL: Double] = [:]
    @ObservationIgnored private let activateAudio: @MainActor () -> Void
    @ObservationIgnored private let deactivateAudio: @MainActor () -> Void

    init(
        activateAudio: @escaping @MainActor () -> Void = OctonautAudioSession.activatePlayback,
        deactivateAudio: @escaping @MainActor () -> Void = OctonautAudioSession.deactivate
    ) {
        self.activateAudio = activateAudio
        self.deactivateAudio = deactivateAudio
    }

    func position(for url: URL) -> Double? {
        positions[url]
    }

    func record(_ seconds: Double, for url: URL) {
        guard seconds.isFinite, seconds >= 0 else { return }
        positions[url] = seconds
    }

    func beginFullScreen() { isFullScreenActive = true }
    func endFullScreen() { isFullScreenActive = false }

    /// Feed rows autoplay muted unless the feed audio setting is enabled.
    /// A row claims audio while it plays so two visible rows cannot talk over
    /// each other.
    private(set) var audioOwner: URL?

    func isAudioOwner(_ url: URL) -> Bool { audioOwner == url }

    func claimAudio(for url: URL) {
        guard audioOwner != url else { return }
        if audioOwner == nil { activateAudio() }
        audioOwner = url
    }

    func releaseAudio(for url: URL) {
        guard audioOwner == url else { return }
        audioOwner = nil
        // The viewer has its own activation while it is audible.
        deactivateAudio()
    }
}

/// The device's power state, as a value a view can observe.
///
/// Separate from `OctonautNetworkStatus` because it answers a different
/// question and changes for a different reason, and shared because the
/// notification is a process-wide fact rather than a per-view one.
@MainActor
@Observable
final class OctonautPowerState {
    static let shared = OctonautPowerState()

    private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let isEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            MainActor.assumeIsolated {
                self?.isLowPowerModeEnabled = isEnabled
            }
        }
    }
}

/// Whether media may be warmed ahead of what the reader is looking at.
enum OctonautPrefetchPolicy {
    /// `REDDIT-ERROR-003` asks for prefetch to be cancelled in Low Power Mode.
    /// Whether the app obeys the mode at all is the reader's `respectsLowPowerMode`
    /// setting, which until now had no reader: it was persisted, shown in
    /// Settings, and consulted nowhere.
    static func allowsPrefetch(isLowPowerModeEnabled: Bool, respectsLowPowerMode: Bool) -> Bool {
        !(isLowPowerModeEnabled && respectsLowPowerMode)
    }
}

/// Admission control for prefetch: how many warming requests may be in flight
/// at once, and which URL goes next.
///
/// `REDDIT-ERROR-003` requires concurrency to be bounded by work type. The feed
/// warms twenty rows ahead, which is up to forty images, and starting all of
/// them at once means the visible row's image queues behind whichever of them
/// the connection happens to be serving. Ordering is first in, first out, which
/// for a feed is also nearest-first.
///
/// A value type with no tasks in it, so the bound can be tested without a
/// network.
struct OctonautPrefetchQueue {
    /// Chosen to sit under `URLSessionConfiguration`'s default six connections
    /// per host, so a visible read always has somewhere to go even when the
    /// queue is full.
    static let defaultMaximumConcurrent = 4

    let maximumConcurrent: Int
    private var active: Set<URL> = []
    private var waiting: [URL] = []

    init(maximumConcurrent: Int = defaultMaximumConcurrent) {
        self.maximumConcurrent = max(maximumConcurrent, 1)
    }

    var activeCount: Int { active.count }
    var waitingCount: Int { waiting.count }

    func contains(_ url: URL) -> Bool { active.contains(url) || waiting.contains(url) }

    /// Takes a URL on unless it is already known. Returns whether it was new.
    mutating func enqueue(_ url: URL) -> Bool {
        guard !contains(url) else { return false }
        waiting.append(url)
        return true
    }

    /// The next URL that may start now, or nil when the bound is reached or
    /// nothing is waiting.
    mutating func startNext() -> URL? {
        guard active.count < maximumConcurrent, !waiting.isEmpty else { return nil }
        let url = waiting.removeFirst()
        active.insert(url)
        return url
    }

    mutating func finish(_ url: URL) {
        active.remove(url)
    }

    /// Forgets a URL whether it had started or not, for a row that has aged out
    /// of the window.
    mutating func remove(_ url: URL) {
        active.remove(url)
        waiting.removeAll { $0 == url }
    }

    /// Empties the queue and reports what had started, so those tasks can be
    /// cancelled.
    mutating func cancelAll() -> Set<URL> {
        let cancelled = active
        active.removeAll()
        waiting.removeAll()
        return cancelled
    }
}

/// Warms the small media window immediately around the visible feed rows.
/// Prepared players stay paused until their row reports that it is on screen.
@MainActor
final class OctonautFeedMediaPreloader {
    private struct VideoKey: Hashable {
        let url: URL
        let audioURL: URL?
    }

    private enum MediaKey: Hashable {
        case image(URL)
        case video(VideoKey)
    }

    private let maximumMedia = 120
    private var imageTasks: [URL: Task<Void, Never>] = [:]
    private var videoTasks: [VideoKey: Task<OctonautAVPlayerFactory.Playback, Never>] = [:]
    private var mediaOrder: [MediaKey] = []
    /// Readable so a test can assert the bound without a network to watch.
    private(set) var prefetchQueue = OctonautPrefetchQueue()
    /// `nonisolated(unsafe)` so `deinit` can reach it. The token is written
    /// once in `init` and read once in `deinit`, both on the main actor, and
    /// nothing else ever touches it.
    nonisolated(unsafe) private var memoryWarningObserver: (any NSObjectProtocol)?

    /// Whether warming ahead of the visible rows is allowed at all. The feed
    /// sets it, because the answer depends on a setting the preloader has no
    /// business reaching for. Turning it off cancels what is already warming.
    var allowsPrefetch = true {
        didSet {
            guard oldValue, !allowsPrefetch else { return }
            cancelPrefetch()
        }
    }

    init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Warming is the first thing to give up under memory pressure:
                // nothing on screen is waiting for any of it. `PERF-003`.
                self?.cancelPrefetch()
            }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func preload(posts: some Sequence<PostCardModel>, compact: Bool) {
        guard allowsPrefetch else { return }
        for post in posts {
            for url in imageURLs(for: post, compact: compact) {
                prepareImage(at: url)
            }
            // Only media that has to be composed is worth preparing ahead.
            // Anything else is built synchronously at the row, so warming it
            // here would construct players -- and their decode sessions and
            // connections -- for a whole window of posts nobody is looking at.
            if !compact,
               post.mediaKind == "video" || post.mediaKind == "gif",
               let url = post.mediaURL,
               let audioURL = post.audioURL {
                prepareVideo(at: url, audioURL: audioURL)
            }
        }
    }

    /// Cancels every image this preloader is warming and leaves the visible
    /// rows alone. Prepared players are left in place: a video is expensive to
    /// re-prepare and a visible row may already own one.
    func cancelPrefetch() {
        for url in prefetchQueue.cancelAll() {
            imageTasks.removeValue(forKey: url)?.cancel()
        }
        // Dropping the task that awaits a download does not stop the download:
        // the cache keeps one request per URL so that several rows can share it.
        OctonautImageCache.cancelWarmingDownloads()
    }

    fileprivate func playback(videoURL: URL, audioURL: URL?) async -> OctonautAVPlayerFactory.Playback {
        let key = VideoKey(url: videoURL, audioURL: audioURL)
        if let task = videoTasks[key] {
            return await task.value
        }
        return await prepareVideo(at: videoURL, audioURL: audioURL).value
    }

    /// Drops a prepared player so the next request builds a new one.
    ///
    /// A prepared entry is a `Task` whose value is awaited by every row for
    /// that video, and it is never retried: without this, one player that
    /// failed or stalled stays the answer for the rest of the session.
    func invalidate(videoURL: URL, audioURL: URL?) {
        let key = VideoKey(url: videoURL, audioURL: audioURL)
        videoTasks.removeValue(forKey: key)
        mediaOrder.removeAll { $0 == .video(key) }
    }

    private func prepareImage(at url: URL) {
        guard imageTasks[url] == nil, prefetchQueue.enqueue(url) else { return }
        mediaOrder.append(.image(url))
        trimPreparedMedia()
        startWaitingImages()
    }

    /// Starts as many warming downloads as the bound allows, and no more. Each
    /// one reports back so the next may go, which is what keeps the queue
    /// draining without a timer.
    private func startWaitingImages() {
        while let url = prefetchQueue.startNext() {
            imageTasks[url] = Task(priority: .utility) { @MainActor [weak self] in
                _ = try? await OctonautImageCache.image(for: url, priority: .prefetch)
                self?.finishWarming(url)
            }
        }
    }

    private func finishWarming(_ url: URL) {
        prefetchQueue.finish(url)
        startWaitingImages()
    }

    @discardableResult
    private func prepareVideo(
        at url: URL,
        audioURL: URL?
    ) -> Task<OctonautAVPlayerFactory.Playback, Never> {
        let key = VideoKey(url: url, audioURL: audioURL)
        if let task = videoTasks[key] { return task }

        let task = Task { @MainActor in
            await OctonautAudioSession.prepareForMutedFeedPlayback()
            let playback = await OctonautAVPlayerFactory.makePlayer(videoURL: url, audioURL: audioURL)
            _ = try? await playback.player.currentItem?.asset.load(.isPlayable)
            if playback.player.status == .readyToPlay {
                _ = await playback.player.preroll(atRate: 1)
            }
            playback.player.pause()
            return playback
        }
        videoTasks[key] = task
        mediaOrder.append(.video(key))
        trimPreparedMedia()
        return task
    }

    private func trimPreparedMedia() {
        while mediaOrder.count > maximumMedia {
            switch mediaOrder.removeFirst() {
            case .image(let expiredURL):
                imageTasks.removeValue(forKey: expiredURL)?.cancel()
                prefetchQueue.remove(expiredURL)
            case .video(let expiredKey):
                // A visible row may still own this player. Removing the cache's
                // reference is enough; the row controls its playback lifecycle.
                videoTasks.removeValue(forKey: expiredKey)
            }
        }
    }

    /// The URLs a row will ask for, chosen the same way the row chooses them.
    ///
    /// These have to match exactly. A prefetch of a different copy of the same
    /// image is not a warm cache, it is the image fetched twice -- so every
    /// size decision here mirrors one in `OctonautCompactPostRow` or
    /// `OctonautInlineMediaView`, through the shared widths.
    private func imageURLs(for post: PostCardModel, compact: Bool) -> [URL] {
        let scale = OctonautImageDisplayWidth.currentScale
        if compact {
            if let thumbnailURL = post.thumbnailURL { return [thumbnailURL] }
            guard post.galleryURLs.first != nil || post.mediaKind == "image" else { return [] }
            return [
                post.imageURL(
                    displayWidth: OctonautImageDisplayWidth.compactThumbnail,
                    scale: scale
                )
            ].compactMap { $0 }
        }

        switch post.mediaKind {
        case "gallery":
            // Two are on screen at a time in the inline strip.
            let pageWidth = OctonautImageDisplayWidth.inlinePage(count: post.galleryURLs.count)
            return (0..<min(2, post.galleryURLs.count)).compactMap { page in
                post.imageURL(page: page, displayWidth: pageWidth, scale: scale)
            }
        case "image":
            return [
                post.imageURL(displayWidth: OctonautImageDisplayWidth.card, scale: scale)
            ].compactMap { $0 }
        case "video", "gif", "embeddedVideo", "link":
            return post.thumbnailURL.map { [$0] } ?? []
        default:
            return []
        }
    }
}

extension View {
    /// Gives a feed row's image its height before the image has it.
    ///
    /// Sized from the loaded image, a row is about as tall as its spinner
    /// until the bytes land and then jumps to the picture's real height. In a
    /// `List` that moves every row below it -- and when the row is above the
    /// viewport, it moves the content under the reader's thumb. That is the
    /// backwards jitter while scrolling, and being a layout event rather than
    /// work on the main thread, no amount of profiling the scroll handlers
    /// shows it.
    ///
    /// Reddit publishes the dimensions in `preview.images[].source` and the
    /// decoder has always read them: `PostCardModel.mediaAspectRatio` is the
    /// same value the gallery grid was taught to lay its tiles out from in
    /// `2f87c68`. This is that fix, for the feed.
    ///
    /// Reserving the published ratio rather than a clamped one is deliberate:
    /// the grid clamps to 9:16...16:9 and crops outside it, which is right
    /// for a page of thumbnails and wrong for a full-width card where the
    /// image is the content. So the shape a row settles at is exactly the
    /// shape it settles at today -- it simply arrives before the bytes do,
    /// instead of after. Capping how tall a feed image may be is a separate
    /// question, and a product one.
    ///
    /// - Parameters:
    ///   - height: A fixed height, which the wide interface supplies. Already
    ///     stable, so it wins.
    ///   - ratio: Reddit's published width-over-height, when there is one.
    ///     Nothing is reserved without it, which is the old behaviour and the
    ///     best available for a post carrying no dimensions.
    @ViewBuilder
    func reservedMediaBox(height: CGFloat?, ratio: CGFloat?) -> some View {
        if let height {
            frame(height: height)
        } else if let ratio, ratio > 0 {
            aspectRatio(ratio, contentMode: .fit)
        } else {
            self
        }
    }
}

/// A cached remote image with stable loading and failure states.
struct OctonautAsyncImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var tint: Color = .secondary
    @State private var image: UIImage?
    @State private var loadFailed = false

    @ViewBuilder
    var body: some View {
        Group {
            if url != nil {
                if let displayedImage {
                    Image(uiImage: displayedImage)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else if loadFailed {
                    ZStack {
                        Color(uiColor: .tertiarySystemBackground)
                        Image(systemName: "photo.slash")
                            .font(.title2)
                            .foregroundStyle(tint)
                    }
                } else {
                    ZStack {
                        Color(uiColor: .tertiarySystemBackground)
                        ProgressView().tint(tint)
                    }
                }
            } else {
                ZStack {
                    Color(uiColor: .tertiarySystemBackground)
                    Image(systemName: "photo.slash")
                        .font(.title2)
                        .foregroundStyle(tint)
                }
            }
        }
        .accessibilityLabel(url == nil ? "No image" : "Image")
        .task(id: url) {
            image = nil
            loadFailed = false
            guard let url else { return }
            do {
                let loadedImage = try await OctonautImageCache.image(for: url)
                guard !Task.isCancelled else { return }
                image = loadedImage
            } catch is CancellationError {
                return
            } catch {
                loadFailed = true
            }
        }
    }

    private var displayedImage: UIImage? {
        image ?? url.flatMap(OctonautImageCache.cachedImage(for:))
    }
}

/// Debug-build warning that a post's audio failed to merge. Reddit's DASH
/// audio is a separate file, and when merging it falls through one of the
/// fallback paths the video still plays -- silently. Without this, that is
/// indistinguishable from a post that simply has no sound.
///
/// Release builds render nothing; the whole body is compiled out.
struct OctonautMuxWarningBadge: View {
    let outcome: OctonautMuxOutcome

    var body: some View {
#if DEBUG
        if let reason = outcome.failureReason {
            Label(reason, systemImage: "speaker.slash.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.yellow.opacity(0.92), in: RoundedRectangle(cornerRadius: 7))
                .padding(7)
                .allowsHitTesting(false)
                .accessibilityLabel("Debug: audio mux failed. \(reason)")
        }
#endif
    }
}

struct OctonautInlineMediaView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.displayScale) private var displayScale
    let post: PostCardModel
    var onOpen: ((Int) -> Void)?
    var preloader: OctonautFeedMediaPreloader?
    var maximumHeight: CGFloat? = nil
    @State private var isRevealed = false
    @State private var isVisibleInFeed = false
    @State private var networkStatus = OctonautNetworkStatus.shared

    private let gallerySpacing: CGFloat = 4
    private let galleryHeight: CGFloat = 220

    private var isSensitiveMedia: Bool {
        post.isSensitive(
            blurringNSFW: dependencies.settings.blurNSFWMedia,
            blurringSpoilers: dependencies.settings.blurSpoilers
        )
    }

    private var shouldBlurMedia: Bool { isSensitiveMedia && !isRevealed }

    private var inlineGalleryURLs: [URL] {
        if !post.galleryURLs.isEmpty { return post.galleryURLs }
        if let mediaURL = post.mediaURL { return [mediaURL] }
        return []
    }

    var body: some View {
        Group {
            if post.mediaKind == "video" || post.mediaKind == "gif", let url = post.mediaURL {
                ZStack {
                    if shouldBlurMedia {
                        ZStack {
                            Color.black
                            OctonautAsyncImage(url: post.thumbnailURL, contentMode: .fit)
                                .compositingGroup()
                                .blur(radius: 18)
                                .scaleEffect(1.08)
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        sensitiveRevealButton
                    } else {
                        OctonautVideoPlayer(
                            url: url,
                            audioURL: post.audioURL,
                            playAudio: dependencies.settings.playFeedVideoAudio,
                            // Only real video carries sound; a GIF is silent.
                            offersAudioControl: post.mediaKind == "video",
                            autoplay: dependencies.settings.autoplayVideo.shouldAutoplay(
                                isConnectedViaWiFi: networkStatus.isConnectedViaWiFi
                            ) && (preloader == nil || isVisibleInFeed),
                            loops: post.mediaKind == "gif",
                            aspectRatioHint: post.mediaAspectRatio,
                            preloader: preloader
                        )
                        .overlay { openVideoButton }
                    }
                }
            } else if post.mediaKind == "embeddedVideo", let url = post.mediaURL,
                      let embedURL = EmbeddedVideoURL.embedURL(for: url) {
                ZStack {
                    if shouldBlurMedia {
                        ZStack {
                            Color.black
                            OctonautAsyncImage(url: post.thumbnailURL, contentMode: .fit)
                                .compositingGroup()
                                .blur(radius: 18)
                                .scaleEffect(1.08)
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        sensitiveRevealButton
                    } else {
                        OctonautEmbeddedVideoView(url: embedURL)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .overlay { openVideoButton }
                    }
                }
            } else if post.mediaKind == "gallery" || post.galleryURLs.count > 1 {
                GeometryReader { geometry in
                    let itemWidth = inlineGalleryURLs.count > 1
                        ? max((geometry.size.width - gallerySpacing) / 2, 1)
                        : geometry.size.width

                    ScrollView(.horizontal) {
                        LazyHStack(spacing: gallerySpacing) {
                            ForEach(Array(inlineGalleryURLs.enumerated()), id: \.offset) { index, _ in
                                Button { openOrReveal(at: index) } label: {
                                    OctonautAsyncImage(
                                        url: post.imageURL(
                                            page: index,
                                            displayWidth: OctonautImageDisplayWidth.inlinePage(
                                                count: inlineGalleryURLs.count
                                            ),
                                            scale: displayScale
                                        ),
                                        contentMode: .fill
                                    )
                                        .frame(width: itemWidth, height: galleryHeight)
                                        .clipped()
                                        .background(.black.opacity(0.04))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(shouldBlurMedia)
                                .accessibilityLabel("Open image \(index + 1) of \(inlineGalleryURLs.count)")
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                    .scrollIndicators(.hidden)
                    .blur(radius: shouldBlurMedia ? 12 : 0)
                    .overlay {
                        if shouldBlurMedia {
                            Button { isRevealed = true } label: { sensitiveOverlay }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Sensitive media. Tap to reveal.")
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Label("\(inlineGalleryURLs.count) images", systemImage: "square.stack")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.58), in: Capsule())
                            .padding(9)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: galleryHeight)
            } else if post.mediaKind == "image" || post.mediaKind == "gif", post.mediaURL != nil {
                Button { openOrReveal(at: 0) } label: {
                    ZStack {
                        OctonautAsyncImage(
                            url: post.imageURL(
                                displayWidth: OctonautImageDisplayWidth.card,
                                scale: displayScale
                            ),
                            contentMode: .fit
                        )
                            .frame(maxWidth: .infinity)
                            .reservedMediaBox(height: maximumHeight, ratio: post.mediaAspectRatio)
                            .blur(radius: shouldBlurMedia ? 12 : 0)
                        if shouldBlurMedia { sensitiveOverlay }
                    }
                }
                .buttonStyle(.plain)
            } else if post.mediaKind == "link" {
                let url = post.mediaURL ?? post.shareURL
                if shouldBlurMedia {
                    Button { isRevealed = true } label: {
                        linkCard(url: url, isBlurred: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sensitive link preview. Tap to reveal.")
                } else {
                    Link(destination: url) {
                        linkCard(url: url, isBlurred: false)
                    }
                    .buttonStyle(.plain)
                }
            } else if post.mediaKind == "unsupported" {
                Link(destination: post.mediaURL ?? post.shareURL) {
                    HStack(spacing: 10) {
                        Image(systemName: "safari").font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open unsupported media").font(.subheadline.weight(.semibold))
                            Text(LinkHostName.display(for: post.mediaURL ?? post.shareURL))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            } else {
                OctonautMediaPlaceholder(
                    title: post.mediaTitle,
                    symbol: post.isVideo ? "play.fill" : "photo",
                    isBlurred: isSensitiveMedia,
                    action: { openOrReveal(at: 0) }
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .onScrollVisibilityChange(threshold: 0.01) { isVisible in
            isVisibleInFeed = isVisible
        }
        .onDisappear {
            isVisibleInFeed = false
        }
    }

    private var sensitiveOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: "eye.slash")
            Text("Tap to reveal")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.62))
        .accessibilityHidden(true)
    }

    private var sensitiveRevealButton: some View {
        Button { isRevealed = true } label: { sensitiveOverlay }
            .buttonStyle(.plain)
            .accessibilityLabel("Sensitive media. Tap to reveal.")
    }

    private var openVideoButton: some View {
        Button { openOrReveal(at: 0) } label: {
            Color.clear
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open video full screen")
    }

    private func linkCard(url: URL, isBlurred: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let thumbnailURL = post.thumbnailURL {
                ZStack {
                    OctonautAsyncImage(url: thumbnailURL, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(height: galleryHeight)
                        .background(.black.opacity(0.04))
                        .blur(radius: isBlurred ? 12 : 0)
                    if isBlurred { sensitiveOverlay }
                }
            }
            // One line: the host is the only thing here that says anything.
            // The line above it read "Link", which is `mediaTitle` -- the
            // media kind, capitalised -- so it told the reader what the link
            // icon already had, and cost the card a whole row of height.
            HStack(spacing: 10) {
                Image(systemName: "link.circle.fill").font(.title3)
                Text(LinkHostName.display(for: url))
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: isBlurred ? "eye" : "arrow.up.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
    }

    private func openOrReveal(at index: Int = 0) {
        if shouldBlurMedia { isRevealed = true } else { onOpen?(index) }
    }
}

private struct OctonautEmbeddedVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Void) {
        webView.stopLoading()
    }
}

/// Whether a feed video row should be asking for audio, and whether to offer
/// the reader a control that decides it.
///
/// Two inputs that have to agree: a global setting, and a per-row choice the
/// reader may or may not have made. Pulled out of the view because the
/// precedence between them is easy to get subtly wrong and impossible to test
/// while it lives inside a `View`.
struct OctonautFeedAudioDecision: Equatable {
    /// `playFeedVideoAudio`: what a row does when the reader has said nothing.
    var setting: Bool
    /// What the reader asked of this row specifically, if anything.
    var rowRequest: Bool?
    /// Whether this media can carry sound at all. A GIF cannot.
    var carriesAudio: Bool

    /// The row's own request wins where it exists; otherwise the setting.
    var wantsAudio: Bool { rowRequest ?? setting }

    /// Offered only when feed audio is off globally. With the setting on,
    /// audio already follows whichever video is playing, and a second control
    /// would only be a way to fight it.
    var showsControl: Bool { carriesAudio && !setting }
}

struct OctonautVideoPlayer: View {
    let url: URL
    var audioURL: URL?
    var playAudio = false
    /// Whether this media can carry sound at all. A GIF cannot, and offering
    /// a speaker button on one is a control that does nothing.
    var offersAudioControl = false
    var autoplay = false
    var loops = false
    /// Reddit's published dimensions, where the post carries them. Preferred
    /// over measuring the asset, which costs a load and reads nothing at all
    /// from an HLS playlist.
    var aspectRatioHint: CGFloat?
    var preloader: OctonautFeedMediaPreloader?
    @State private var player: AVPlayer?
    @State private var measuredAspectRatio: CGFloat?
    @State private var playbackRequested = false
    @State private var looper = OctonautVideoLooper()
    @State private var positionObserver: Any?
    @State private var failureObservers: [any NSObjectProtocol] = []
    @State private var recoveryAttempts = 0
    @State private var muxOutcome: OctonautMuxOutcome = .notApplicable
    /// Whether the item has resolved far enough to have a frame on screen.
    ///
    /// The surface is mounted as soon as there is a player object, which is
    /// well before there is anything in it, so it spends that time black and
    /// then snaps to the first frame. Fading that last step is the difference
    /// between a video appearing and a video popping.
    @State private var showsFrame = false
    @Environment(\.scenePhase) private var scenePhase
    // Upstream's: held rather than recomputed, which matches `networkStatus`
    // and the other shared observables this view reads.
    @State private var coordinator = OctonautPlaybackCoordinator.shared
    /// The reader's own decision about this row's audio, where they have made
    /// one. `nil` means follow `playAudio`, the global setting.
    ///
    /// This is what makes the setting and the button a pair rather than two
    /// rival switches: the setting says what a row does when nobody has said
    /// otherwise, and the button says otherwise for one row.
    @State private var audioRequested: Bool?

    /// A composed player is the only kind worth preparing ahead, so it is the
    /// only kind that comes from the preloader.
    private var needsComposing: Bool { audioURL != nil && audioURL != url }

    private var aspectRatio: CGFloat { measuredAspectRatio ?? aspectRatioHint ?? 16 / 9 }

    /// The viewer takes over playback while it is open.
    private var shouldPlay: Bool { autoplay && !coordinator.isFullScreenActive }

    private var audioDecision: OctonautFeedAudioDecision {
        OctonautFeedAudioDecision(
            setting: playAudio, rowRequest: audioRequested, carriesAudio: offersAudioControl)
    }

    /// Whether this row is asking to be the audible one.
    private var wantsAudio: Bool { audioDecision.wantsAudio }

    /// Muted unless this row owns audio.
    ///
    /// Ownership is the single source of truth, and that is the change that
    /// makes a per-row control possible at all. This used to read
    /// `!playAudio || !coordinator.isAudioOwner(url)`, where the setting being
    /// off muted the row no matter what -- so claiming audio for one video
    /// could not unmute it, and a button would have done nothing. Now the
    /// setting decides who claims ownership, and ownership decides who is
    /// audible.
    private var effectiveMuted: Bool { !coordinator.isAudioOwner(url) }

    /// Whether to offer the per-row speaker control.
    ///
    /// Only when feed audio is switched off globally. With the setting on,
    /// audio already follows whichever video is playing and a second control
    /// would just be a way to fight it.
    private var showsAudioControl: Bool { audioDecision.showsControl }

    private var playbackRequest: PlaybackRequest {
        PlaybackRequest(url: url, audioURL: audioURL)
    }

    var body: some View {
        Group {
            if let player {
                ZStack {
                    // The same black the placeholder shows, so the fade is the
                    // frame arriving over it rather than the whole surface
                    // appearing from nothing.
                    Color.black
                    if !showsFrame { ProgressView().tint(.white) }
                    OctonautSystemIsolatedVideoPlayer(player: player, showsPlaybackControls: false)
                        .opacity(showsFrame ? 1 : 0)
                        .overlay(alignment: .topLeading) {
                            OctonautMuxWarningBadge(outcome: muxOutcome)
                        }
                }
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) { audioControl }
            } else {
                ZStack {
                    Color.black
                    ProgressView().tint(.white)
                }
                .aspectRatio(aspectRatio, contentMode: .fit)
            }
        }
        .task(id: playbackRequest) {
            await OctonautAudioSession.prepareForMutedFeedPlayback()
            playbackRequested = shouldPlay
            recoveryAttempts = 0
            teardownPlayer()

            // Nothing to compose means nothing to wait for. Building the
            // player here removes the state where the row has none, which is
            // what the black frame and spinner were showing.
            guard needsComposing else {
                adopt(OctonautAVPlayerFactory.makeStreamingPlayer(url: url), muxOutcome: .notApplicable)
                // Refine the frame afterwards rather than before: a post that
                // publishes no dimensions should still not be laid out at
                // 16:9 forever, but measuring must not hold up the player.
                if aspectRatioHint == nil,
                   let measured = await OctonautAVPlayerFactory.measuredAspectRatio(for: url),
                   !Task.isCancelled {
                    measuredAspectRatio = measured
                }
                return
            }

            let playback: OctonautAVPlayerFactory.Playback
            if let preloader {
                playback = await preloader.playback(videoURL: url, audioURL: audioURL)
            } else {
                playback = await OctonautAVPlayerFactory.makePlayer(videoURL: url, audioURL: audioURL)
            }
            guard !Task.isCancelled else { return }
            // Only trust a measurement when the post published no dimensions.
            if aspectRatioHint == nil {
                measuredAspectRatio = playback.aspectRatio
            }
            adopt(playback.player, muxOutcome: playback.muxOutcome)
        }
        .task(id: player.map(ObjectIdentifier.init)) {
            showsFrame = false
            guard let item = player?.currentItem else {
                // No item to wait on: show whatever the surface has rather
                // than leave it hidden.
                showsFrame = true
                return
            }
            // Bounded, because a stalled item must not leave the video
            // invisible -- the worst case is the black it would have shown
            // anyway, and then the frame.
            let deadline = Date.now.addingTimeInterval(4)
            while !Task.isCancelled, item.status == .unknown, Date.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) { showsFrame = true }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the background on a failed item, as Winston
            // does: a player that failed while away never recovers by itself.
            guard phase == .active else { return }
            recoverIfFailed()
        }
        .onChange(of: effectiveMuted) { _, isNowMuted in
            player?.isMuted = isNowMuted
        }
        .onChange(of: shouldPlay) { _, shouldAutoplay in
            playbackRequested = shouldAutoplay
            updateAudioOwnership()
            if shouldAutoplay {
                recoverIfFailed()
                // Resume wherever the viewer left off rather than where this
                // row was when it handed playback over.
                if let resumeAt = coordinator.position(for: url), resumeAt > 0 {
                    player?.seek(
                        to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
                if let player { play(player) }
            } else {
                if let player {
                    coordinator.record(player.currentTime().seconds, for: url)
                }
                player?.pause()
            }
        }
        .onChange(of: playAudio) { _, _ in
            // Changing the global setting is a fresh instruction, so a
            // per-row override from earlier no longer reflects what the
            // reader wants.
            audioRequested = nil
            updateAudioOwnership()
        }
        .onChange(of: coordinator.audioOwner) { _, owner in
            // Another row has taken the audio. This row's request has been
            // answered and lost; leaving it set would have the two of them
            // claiming ownership back off each other.
            if owner != url, audioRequested == true { audioRequested = nil }
        }
        .onDisappear {
            playbackRequested = false
            // Deliberately forgotten rather than remembered: a video the
            // reader unmuted, scrolled past, and came back to should not
            // start talking again on its own.
            audioRequested = nil
            coordinator.releaseAudio(for: url)
            if let player {
                coordinator.record(player.currentTime().seconds, for: url)
            }
            player?.pause()
            removePositionObserver()
            removeFailureObservers()
            looper.detach()
        }
        .accessibilityLabel("Video")
    }

    /// The per-row speaker, shown when feed audio is off globally.
    ///
    /// Layered above `openVideoButton` at the call site, which covers the
    /// whole frame, so its taps are not swallowed by the open-full-screen
    /// action.
    @ViewBuilder
    private var audioControl: some View {
        if showsAudioControl {
            let isAudible = coordinator.isAudioOwner(url)
            Button {
                // Recorded as this row's own decision, not pushed straight at
                // the coordinator: `updateAudioOwnership` runs again on every
                // scroll and would hand a manual claim straight back if the
                // only record of it lived in the coordinator.
                audioRequested = !isAudible
                updateAudioOwnership()
            } label: {
                Image(systemName: isAudible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(.black.opacity(0.58), in: Circle())
                    .padding(9)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isAudible ? "Mute video" : "Unmute video")
        }
    }

    /// Takes ownership of a player and starts it if the row is still asking
    /// for playback.
    private func adopt(_ newPlayer: AVPlayer, muxOutcome newOutcome: OctonautMuxOutcome) {
        newPlayer.isMuted = effectiveMuted
        muxOutcome = newOutcome
        // Upstream's (`191f20a`): a row taking a player has to say whether it
        // is claiming audio, or an unmuted row that rebuilds its player goes
        // silently back to being muted.
        updateAudioOwnership()
        if loops {
            looper.attach(to: newPlayer)
        }
        player = newPlayer
        observePosition(of: newPlayer)
        observeFailures(of: newPlayer)
        if playbackRequested {
            play(newPlayer)
        }
    }

    /// Plays from the start when the player is sitting at the end.
    ///
    /// `play()` on a player parked at its final frame does nothing, and a
    /// player can be parked there by having been watched to the end in the
    /// viewer, which hands the position back here.
    private func play(_ player: AVPlayer) {
        if let duration = player.currentItem?.duration.seconds,
           duration.isFinite,
           player.currentTime().seconds >= duration - 0.25 {
            player.seek(to: .zero)
            coordinator.record(0, for: url)
        }
        player.play()
    }

    private func teardownPlayer() {
        removePositionObserver()
        removeFailureObservers()
        player?.pause()
        player = nil
    }

    /// Rebuilds the player when the item has failed outright.
    private func recoverIfFailed() {
        guard player?.currentItem?.status == .failed || player?.error != nil else { return }
        rebuildPlayer()
    }

    /// A stalled or failed item is rebuilt from a fresh asset, and the
    /// prepared copy is dropped so the next row does not inherit it.
    ///
    /// Capped, because a video Reddit will not serve should settle on a still
    /// frame rather than retry for as long as the feed is open.
    private func rebuildPlayer() {
        guard recoveryAttempts < 2 else { return }
        recoveryAttempts += 1
        let resumeAt = player.map { $0.currentTime().seconds } ?? 0
        preloader?.invalidate(videoURL: url, audioURL: audioURL)
        teardownPlayer()

        guard needsComposing else {
            let replacement = OctonautAVPlayerFactory.makeStreamingPlayer(url: url)
            if resumeAt > 0 {
                replacement.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
            }
            adopt(replacement, muxOutcome: .notApplicable)
            return
        }

        Task {
            let playback = await OctonautAVPlayerFactory.makePlayer(videoURL: url, audioURL: audioURL)
            if aspectRatioHint == nil {
                measuredAspectRatio = playback.aspectRatio
            }
            if resumeAt > 0 {
                await playback.player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
            }
            adopt(playback.player, muxOutcome: playback.muxOutcome)
        }
    }

    /// Watches for the two ways an item dies mid-flight. Without this a video
    /// that stalls stays a still frame until the reader scrolls away, and a
    /// prepared player that failed is handed to every row that asks for it.
    private func observeFailures(of player: AVPlayer) {
        removeFailureObservers()
        guard let item = player.currentItem else { return }
        let names: [Notification.Name] = [
            .AVPlayerItemFailedToPlayToEndTime,
            .AVPlayerItemPlaybackStalled
        ]
        failureObservers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: item,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { rebuildPlayer() }
            }
        }
    }

    private func removeFailureObservers() {
        failureObservers.forEach(NotificationCenter.default.removeObserver)
        failureObservers = []
    }

    private func updateAudioOwnership() {
        if wantsAudio && shouldPlay && player != nil {
            coordinator.claimAudio(for: url)
        } else {
            coordinator.releaseAudio(for: url)
        }
        player?.isMuted = effectiveMuted
    }

    /// Records the playhead as it moves so opening the viewer can pick up from
    /// where the row actually was, without depending on the order in which
    /// SwiftUI delivers the full screen transition.
    private func observePosition(of player: AVPlayer) {
        removePositionObserver()
        positionObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            MainActor.assumeIsolated {
                guard !OctonautPlaybackCoordinator.shared.isFullScreenActive else { return }
                OctonautPlaybackCoordinator.shared.record(time.seconds, for: url)
            }
        }
    }

    private func removePositionObserver() {
        if let positionObserver, let player {
            player.removeTimeObserver(positionObserver)
        }
        positionObserver = nil
    }

    private struct PlaybackRequest: Hashable {
        let url: URL
        let audioURL: URL?
    }
}

struct OctonautSystemIsolatedVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var showsPlaybackControls = true
    /// Whether AVKit may analyse frames for text and subjects.
    ///
    /// Off by default because its button is placed by the system in the
    /// bottom trailing corner, with no API to move it -- where it lands
    /// underneath the feed's own mute control. In a scrolling feed the
    /// analysis is noise anyway; full screen it is worth having, and there
    /// is room for it.
    var allowsFrameAnalysis = false

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        Self.makeViewController(
            player: player,
            showsPlaybackControls: showsPlaybackControls,
            allowsFrameAnalysis: allowsFrameAnalysis
        )
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls
        controller.updatesNowPlayingInfoCenter = false
        controller.allowsPictureInPicturePlayback = false
        controller.allowsVideoFrameAnalysis = allowsFrameAnalysis
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Void) {
        controller.player = nil
    }

    static func makeViewController(
        player: AVPlayer,
        showsPlaybackControls: Bool,
        allowsFrameAnalysis: Bool = false
    ) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls
        controller.updatesNowPlayingInfoCenter = false
        controller.allowsPictureInPicturePlayback = false
        controller.allowsVideoFrameAnalysis = allowsFrameAnalysis
        return controller
    }
}

@MainActor
@Observable
final class OctonautNetworkStatus {
    static let shared = OctonautNetworkStatus()

    private(set) var isConnectedViaWiFi = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.octonaut.network-status")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isConnectedViaWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                self?.isConnectedViaWiFi = isConnectedViaWiFi
            }
        }
        monitor.start(queue: queue)
    }
}

struct OctonautZoomableImage: View {
    let url: URL
    /// A smaller copy of the same image that is probably already decoded --
    /// the one the row behind this view drew. Shown while `url` loads so the
    /// viewer opens on the picture rather than on a spinner.
    var placeholderURL: URL?
    let accessibilityLabel: String
    var onZoomChange: ((Bool) -> Void)?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnification(viewportSize: geometry.size, imageSize: image.size))
                        .simultaneousGesture(
                            drag(viewportSize: geometry.size, imageSize: image.size),
                            isEnabled: scale > 1
                        )
                        .highPriorityGesture(
                            TapGesture(count: 2)
                                .onEnded {
                                    toggleZoom(viewportSize: geometry.size, imageSize: image.size)
                                }
                        )
                } else if loadFailed {
                    ContentUnavailableView("Image unavailable", systemImage: "photo.slash")
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onChange(of: geometry.size) { _, newSize in
                clampPosition(viewportSize: newSize, imageSize: image?.size)
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double tap to zoom. Pinch to zoom and drag to pan.")
        .task(id: url) {
            loadFailed = false
            scale = 1
            baseScale = 1
            offset = .zero
            baseOffset = .zero
            onZoomChange?(false)
            // Only a cached copy is used as a stand-in. Fetching one purely to
            // fill the gap would put a second request on the wire for an image
            // that is already being fetched at the size actually wanted.
            image = placeholderURL.flatMap(OctonautImageCache.cachedImage(for:))
            do {
                let fullSize = try await OctonautImageCache.image(for: url)
                guard !Task.isCancelled else { return }
                image = fullSize
            } catch is CancellationError {
                return
            } catch {
                // A stand-in on screen is better than an error over the top
                // of it; only a viewer with nothing to show reports a failure.
                loadFailed = image == nil
            }
        }
    }

    private func magnification(viewportSize: CGSize, imageSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let proposedScale = min(max(baseScale * value, 1), 8)
                scale = proposedScale
                offset = clampedOffset(
                    baseOffset,
                    scale: scale,
                    viewportSize: viewportSize,
                    imageSize: imageSize
                )
                onZoomChange?(scale > 1)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1 {
                    resetPosition()
                } else {
                    baseOffset = offset
                }
                onZoomChange?(scale > 1)
            }
    }

    private func drag(viewportSize: CGSize, imageSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = clampedOffset(
                    CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    ),
                    scale: scale,
                    viewportSize: viewportSize,
                    imageSize: imageSize
                )
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    private func toggleZoom(viewportSize: CGSize, imageSize: CGSize) {
        if scale > 1 {
            resetPosition()
        } else {
            let targetScale = min(max(
                fillScale(imageSize: imageSize, viewportSize: viewportSize),
                2
            ), 8)
            scale = targetScale
            baseScale = targetScale
            onZoomChange?(true)
        }
    }

    private func fillScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        let fittedSize = aspectFitSize(imageSize: imageSize, viewportSize: viewportSize)
        return max(
            viewportSize.width / max(fittedSize.width, 1),
            viewportSize.height / max(fittedSize.height, 1)
        )
    }

    private func clampPosition(viewportSize: CGSize, imageSize: CGSize?) {
        guard let imageSize else { return }
        let clamped = clampedOffset(
            offset,
            scale: scale,
            viewportSize: viewportSize,
            imageSize: imageSize
        )
        withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
            offset = clamped
            baseOffset = clamped
        }
    }

    private func clampedOffset(
        _ proposed: CGSize,
        scale: CGFloat,
        viewportSize: CGSize,
        imageSize: CGSize
    ) -> CGSize {
        let fittedSize = aspectFitSize(imageSize: imageSize, viewportSize: viewportSize)
        let maximumX = max((fittedSize.width * scale - viewportSize.width) / 2, 0)
        let maximumY = max((fittedSize.height * scale - viewportSize.height) / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY)
        )
    }

    private func aspectFitSize(imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        guard imageSize.width > 0,
              imageSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else { return .zero }
        let fitScale = min(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )
        return CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
    }

    private func resetPosition() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1
            baseScale = 1
            offset = .zero
            baseOffset = .zero
        }
        onZoomChange?(false)
    }
}

@MainActor
struct OctonautMediaViewer: View {
    let post: PostCardModel
    var onSave: (() -> Void)?
    var onOpenPost: (() -> Void)?
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var showOverlay = true
    @State private var isRevealed = false
    @State private var fileToExport: OctonautExportableMedia?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveConfirmation: String?
    @State private var isZoomed = false
    @State private var dismissOffset: CGFloat = 0
    @State private var dismissalAxis: DismissalAxis?
    @State private var isDismissing = false
    @State private var activePlayer: AVPlayer?
    @State private var isPlayerMuted = false
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var networkStatus = OctonautNetworkStatus.shared
    @Environment(\.displayScale) private var displayScale

    private let saveCoordinator = OctonautMediaSaveCoordinator()

    private var shouldBlurMedia: Bool {
        guard !isRevealed else { return false }
        return post.isSensitive(
            blurringNSFW: dependencies.settings.blurNSFWMedia,
            blurringSpoilers: dependencies.settings.blurSpoilers
        )
    }

    init(
        post: PostCardModel,
        initialPage: Int = 0,
        initiallyRevealed: Bool = false,
        onSave: (() -> Void)? = nil,
        onOpenPost: (() -> Void)? = nil
    ) {
        self.post = post
        self.onSave = onSave
        self.onOpenPost = onOpenPost
        _page = State(initialValue: max(initialPage, 0))
        _isRevealed = State(initialValue: initiallyRevealed)
    }

    /// Reddit's full-size media, which is what saving, sharing and exporting
    /// all mean by "this image".
    private var mediaURLs: [URL] {
        if post.galleryURLs.isEmpty, let mediaURL = post.mediaURL { return [mediaURL] }
        return post.galleryURLs
    }

    /// What the viewer actually displays: full resolution on Wi-Fi, and
    /// Reddit's largest pre-made copy on a metered connection.
    private func displayedImageURL(at page: Int) -> URL {
        post.viewerImageURL(page: page, isConnectedViaWiFi: networkStatus.isConnectedViaWiFi)
            ?? mediaURLs[page]
    }

    /// The copy the feed row behind this viewer already drew.
    ///
    /// It is usually still in the decoded cache, so handing it over means the
    /// image is on screen the instant the viewer opens and sharpens when the
    /// full-size one arrives -- rather than the reader watching a spinner
    /// where a perfectly good picture had been a moment earlier.
    private func placeholderImageURL(at page: Int) -> URL? {
        post.imageURL(
            page: page,
            displayWidth: OctonautImageDisplayWidth.inlinePage(count: mediaURLs.count),
            scale: displayScale
        )
    }

    private var pagePosition: Binding<Int?> {
        Binding(
            get: { page },
            set: { newPage in
                if let newPage { page = newPage }
            }
        )
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - dismissalProgress)
                .ignoresSafeArea()
            Group {
                if mediaURLs.isEmpty {
                    ContentUnavailableView("Media unavailable", systemImage: "photo.slash")
                        .foregroundStyle(.white)
                } else {
                    GeometryReader { viewport in
                        ScrollView(.horizontal) {
                            HStack(spacing: 0) {
                                ForEach(Array(mediaURLs.enumerated()), id: \.offset) { index, url in
                                    Group {
                                        if post.mediaKind == "video" || post.mediaKind == "gif" {
                                            OctonautVideoDetailView(
                                                url: url,
                                                audioURL: post.audioURL,
                                                loops: post.mediaKind == "gif",
                                                startsMuted: post.mediaKind == "gif",
                                                allowsFrameAnalysis: dependencies.settings.enableLiveText,
                                                onPlayerChange: { activePlayer = $0 }
                                            )
                                        } else if post.mediaKind == "embeddedVideo",
                                                  let embedURL = EmbeddedVideoURL.embedURL(for: url) {
                                            ZStack {
                                                OctonautEmbeddedVideoView(url: embedURL)
                                                    .aspectRatio(16 / 9, contentMode: .fit)
                                                    .blur(radius: shouldBlurMedia ? 24 : 0)
                                                if shouldBlurMedia {
                                                    Button { isRevealed = true } label: {
                                                        VStack(spacing: 7) {
                                                            Image(systemName: "eye.slash")
                                                            Text("Tap to reveal")
                                                                .font(.caption.weight(.semibold))
                                                        }
                                                        .foregroundStyle(.white)
                                                        .padding(18)
                                                        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12))
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        } else {
                                            ZStack {
                                                OctonautZoomableImage(
                                                    url: displayedImageURL(at: index),
                                                    placeholderURL: placeholderImageURL(at: index),
                                                    accessibilityLabel: "Image \(index + 1) of \(mediaURLs.count)",
                                                    onZoomChange: { isZoomed = $0 }
                                                )
                                                .blur(radius: shouldBlurMedia ? 24 : 0)
                                                if shouldBlurMedia {
                                                    Button { isRevealed = true } label: {
                                                        VStack(spacing: 7) {
                                                            Image(systemName: "eye.slash")
                                                            Text("Tap to reveal")
                                                                .font(.caption.weight(.semibold))
                                                        }
                                                        .foregroundStyle(.white)
                                                        .padding(18)
                                                        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12))
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                    }
                                    .frame(width: viewport.size.width, height: viewport.size.height)
                                    .id(index)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.paging)
                        .scrollPosition(id: pagePosition)
                        .scrollDisabled(isZoomed)
                        .scrollIndicators(.hidden)
                    }
                    .ignoresSafeArea(.container, edges: .all)
                }

                chromeOverlay
            }
            .offset(y: dismissOffset)
            .scaleEffect(1 - (dismissalProgress * 0.08))
            .opacity(1 - (dismissalProgress * 0.2))
        }
        .contentShape(Rectangle())
        .simultaneousGesture(dismissalGesture, isEnabled: !isZoomed && !isDismissing)
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showOverlay.toggle() } }
        .onChange(of: page) { _, _ in isZoomed = false }
        .onChange(of: activePlayer == nil) { _, hasNoPlayer in
            if hasNoPlayer {
                cancelChromeHide()
            } else {
                scheduleChromeHide()
            }
        }
        .onChange(of: showOverlay) { _, isVisible in
            // A tap that brings the chrome back restarts the countdown;
            // hiding it manually stops the timer from fighting the user.
            if isVisible && activePlayer != nil {
                scheduleChromeHide()
            } else if !isVisible {
                cancelChromeHide()
            }
        }
        .onDisappear { cancelChromeHide() }
        .onChange(of: saveConfirmation) { _, confirmation in
            if confirmation != nil {
                showOverlay = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        .statusBarHidden(!showOverlay)
        .presentationBackground(.clear)
        .sheet(item: $fileToExport) { media in
            OctonautFileExporter(fileURL: media.url) {
                saveConfirmation = "The media was saved to Files."
            } onDismiss: {
                if !isVideo {
                    try? FileManager.default.removeItem(at: media.url)
                }
            }
        }
        .alert("Could not save media", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "The media could not be saved.")
        }
    }

    /// Extracted from `body`: inlined, the viewer's chrome pushed the whole
    /// expression past what the type-checker will solve in reasonable time.
    @ViewBuilder
    private var chromeOverlay: some View {
        if showOverlay {
            VStack(spacing: 0) {
                HStack {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Close media viewer")
                Spacer()
                Text("\(min(page + 1, max(mediaURLs.count, 1))) / \(max(mediaURLs.count, 1))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                Spacer()
                if let mediaURL = mediaURLs[safe: page] ?? post.mediaURL {
                    Menu {
                        Button { saveMedia(mediaURL, destination: .photos) } label: {
                            Label("Save to Photos", systemImage: "photo.badge.arrow.down")
                        }
                        if mediaURLs.count > 1 {
                            Button { saveAllMediaToPhotos() } label: {
                                Label("Save All Media to Photos", systemImage: "photo.stack")
                            }
                        }
                        Button { saveMedia(mediaURL, destination: .files) } label: {
                            Label("Save to Files", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.title3)
                    }
                    .disabled(isSaving)
                    .opacity(isSaving || saveConfirmation != nil ? 0 : 1)
                    .overlay {
                        // Keep live feedback outside the native menu's label.
                        Group {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                            } else if saveConfirmation != nil {
                                Image(systemName: "checkmark.circle")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .accessibilityLabel("Save media")
                    .accessibilityValue(isSaving ? "Saving media" : saveConfirmation ?? "")
                }
                Menu {
                    if let onSave {
                        Button { onSave() } label: { Label(post.isSaved ? "Unsave" : "Save", systemImage: "bookmark") }
                    }
                    ShareLink(item: mediaURLs[safe: page] ?? post.shareURL) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { onOpenPost?(); dismiss() } label: { Label("Open Post", systemImage: "doc.text") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .accessibilityLabel("Media actions")
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .foregroundStyle(.white)
                .background(LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .top, endPoint: .bottom))
                Spacer()
                if mediaURLs.count > 1 {
                HStack(spacing: 6) {
                    ForEach(mediaURLs.indices, id: \.self) { index in
                        Circle()
                            .fill(index == page ? .white : .white.opacity(0.38))
                            .frame(
                                width: index == page ? 7 : 6,
                                height: index == page ? 7 : 6
                            )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.bottom, post.title.isEmpty ? 16 : 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Image \(page + 1) of \(mediaURLs.count)")
                }
                if let activePlayer {
                OctonautPlayerControls(
                    player: activePlayer,
                    isMuted: $isPlayerMuted,
                    onInteraction: scheduleChromeHide
                )
                .padding(.horizontal, 10)
                .padding(.bottom, post.title.isEmpty ? 10 : 4)
                }
                if post.title != "" {
                VStack(alignment: .leading, spacing: 5) {
                    Text(post.title).font(.headline).lineLimit(3)
                    Text("r/\(post.community) • \(post.score.formatted()) points")
                        .font(.caption).foregroundStyle(.white.opacity(0.78))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .foregroundStyle(.white)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                }
            }
            .transition(.opacity)
        }
    }

    private enum DismissalAxis {
        case horizontal
        case vertical
    }

    private var dismissalProgress: CGFloat {
        min(abs(dismissOffset) / 280, 1)
    }

    private var dismissalGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if dismissalAxis == nil {
                    dismissalAxis = abs(value.translation.height) > abs(value.translation.width)
                        ? .vertical : .horizontal
                }
                guard dismissalAxis == .vertical else { return }
                dismissOffset = value.translation.height
            }
            .onEnded { value in
                let wasVertical = dismissalAxis == .vertical
                dismissalAxis = nil
                guard wasVertical else { return }

                let projectedDistance = value.predictedEndTranslation.height
                if abs(value.translation.height) > 110 || abs(projectedDistance) > 220 {
                    let direction: CGFloat = projectedDistance == 0
                        ? (value.translation.height < 0 ? -1 : 1)
                        : (projectedDistance < 0 ? -1 : 1)
                    finishInteractiveDismissal(direction: direction)
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    /// Video chrome gets out of the way on its own, the way a player is
    /// expected to behave. Images keep their chrome until tapped.
    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        if !showOverlay {
            withAnimation(.easeOut(duration: 0.2)) { showOverlay = true }
        }
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showOverlay = false }
        }
    }

    private func cancelChromeHide() {
        chromeHideTask?.cancel()
        chromeHideTask = nil
    }

    private func finishInteractiveDismissal(direction: CGFloat) {
        isDismissing = true
        withAnimation(.easeOut(duration: 0.18)) {
            dismissOffset = direction * 1_200
        }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            dismiss()
        }
    }

    private enum SaveDestination {
        case photos
        case files
    }

    private var isVideo: Bool {
        post.mediaKind == "video" || post.mediaKind == "gif"
    }

    private func saveMedia(_ sourceURL: URL, destination: SaveDestination) {
        guard !isSaving else { return }
        isSaving = true
        saveConfirmation = nil
        saveError = nil
        showOverlay = true
        Task {
            defer { isSaving = false }
            var temporaryDownloadedURL: URL?
            do {
                let localURL = try await prepareMediaForSaving(sourceURL)
                if !isVideo {
                    temporaryDownloadedURL = localURL
                }
                guard !Task.isCancelled else {
                    if let temporaryDownloadedURL {
                        try? FileManager.default.removeItem(at: temporaryDownloadedURL)
                    }
                    return
                }

                switch destination {
                case .photos:
                    try await saveCoordinator.saveToPhotos(fileURL: localURL, isVideo: isVideo)
                    saveConfirmation = isVideo ? "The video was added to Photos." : "The image was added to Photos."
                    if let temporaryDownloadedURL {
                        try? FileManager.default.removeItem(at: temporaryDownloadedURL)
                    }
                case .files:
                    fileToExport = OctonautExportableMedia(url: localURL)
                }
            } catch is CancellationError {
                if let temporaryDownloadedURL {
                    try? FileManager.default.removeItem(at: temporaryDownloadedURL)
                }
                return
            } catch {
                if destination == .photos, let temporaryDownloadedURL {
                    try? FileManager.default.removeItem(at: temporaryDownloadedURL)
                }
                saveError = error.localizedDescription
            }
        }
    }

    private func saveAllMediaToPhotos() {
        guard !isSaving, mediaURLs.count > 1 else { return }
        isSaving = true
        saveConfirmation = nil
        saveError = nil
        showOverlay = true
        Task {
            defer { isSaving = false }
            var downloadedURLs: [URL] = []
            do {
                var localURLs: [URL] = []
                localURLs.reserveCapacity(mediaURLs.count)
                for sourceURL in mediaURLs {
                    let local = try await prepareMediaForSaving(sourceURL)
                    localURLs.append(local)
                    if !isVideo {
                        downloadedURLs.append(local)
                    }
                }
                guard !Task.isCancelled else {
                    for url in downloadedURLs { try? FileManager.default.removeItem(at: url) }
                    return
                }

                try await saveCoordinator.saveToPhotos(fileURLs: localURLs, isVideo: isVideo)
                let mediaType = isVideo ? "videos" : "images"
                saveConfirmation = "All \(localURLs.count) \(mediaType) were added to Photos."
                for url in downloadedURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            } catch is CancellationError {
                for url in downloadedURLs { try? FileManager.default.removeItem(at: url) }
                return
            } catch {
                for url in downloadedURLs { try? FileManager.default.removeItem(at: url) }
                saveError = error.localizedDescription
            }
        }
    }

    private func prepareMediaForSaving(_ sourceURL: URL) async throws -> URL {
        if isVideo {
            let job = try await dependencies.media.exportVideo(
                source: sourceURL,
                audio: post.audioURL,
                cleanupDate: .now.addingTimeInterval(24 * 60 * 60)
            )
            guard let outputURL = job.outputURL else {
                throw OctonautMediaSaveCoordinator.SaveError.downloadFailed
            }
            return outputURL
        }
        return try await saveCoordinator.downloadImage(from: sourceURL)
    }
}

/// Restarts a player when it reaches the end. GIFs arrive as ordinary mp4s
/// once the codec resolves their preview variant, so looping is what makes
/// them read as GIFs rather than very short videos.
@MainActor
final class OctonautVideoLooper {
    private var observer: (any NSObjectProtocol)?

    func attach(to player: AVPlayer) {
        detach()
        player.actionAtItemEnd = .none
        observer = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                player.seek(to: .zero)
                player.play()
            }
        }
    }

    func detach() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }
}

@MainActor
struct OctonautVideoDetailView: View {
    let url: URL
    var audioURL: URL?
    var loops = false
    var autoplay = true
    /// AVPlayerViewController's controls cannot be inset, so they collided
    /// with the viewer's own chrome. The viewer draws `OctonautPlayerControls`
    /// in its overlay stack instead.
    var showsSystemControls = false
    /// GIFs carry no audio track; real videos should open audible.
    var startsMuted = false
    /// The reader's Live Text preference, which had no effect anywhere until
    /// it reached AVKit's frame analysis.
    var allowsFrameAnalysis = true
    var onPlayerChange: ((AVPlayer?) -> Void)?
    @State private var player: AVPlayer?
    @State private var looper = OctonautVideoLooper()
    @State private var positionObserver: Any?
    @State private var muxOutcome: OctonautMuxOutcome = .notApplicable
    @State private var audioSessionActivated = false

    private var coordinator: OctonautPlaybackCoordinator { .shared }

    var body: some View {
        ZStack {
            Color.black
            if let player {
                OctonautSystemIsolatedVideoPlayer(
                    player: player,
                    showsPlaybackControls: showsSystemControls,
                    allowsFrameAnalysis: allowsFrameAnalysis
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    OctonautMuxWarningBadge(outcome: muxOutcome)
                }
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            coordinator.beginFullScreen()
            let playback = await OctonautAVPlayerFactory.makePlayer(videoURL: url, audioURL: audioURL)
            guard !Task.isCancelled else { return }
            playback.player.isMuted = startsMuted
            muxOutcome = playback.muxOutcome

            // The factory builds deliberately isolated players so feed rows
            // cannot hijack a system AirPlay session. Here the viewer is front
            // and centre and the user asked for the route, so allow it.
            playback.player.allowsExternalPlayback = true

            if !startsMuted && !audioSessionActivated {
                audioSessionActivated = true
                OctonautAudioSession.activatePlayback()
            }
            if loops {
                looper.attach(to: playback.player)
            }

            // Assign the player before seeking. The async seek does not return
            // until the item is ready to play, and on an asset that never
            // becomes ready it never returns at all -- which left the viewer
            // on a spinner forever while the same media played fine in the
            // feed, where nothing seeks.
            player = playback.player
            observePosition(of: playback.player)
            onPlayerChange?(playback.player)

            // Continue from wherever the feed row had reached.
            if let resumeAt = coordinator.position(for: url), resumeAt > 0 {
                // Completion-handler form: the bare seek maps to async and
                // would reintroduce the wait this fix removes.
                playback.player.seek(
                    to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero,
                    completionHandler: { _ in }
                )
            }

            if autoplay {
                playback.player.play()
            }
        }
        .onDisappear {
            if let player {
                coordinator.record(player.currentTime().seconds, for: url)
            }
            player?.pause()
            removePositionObserver()
            looper.detach()
            onPlayerChange?(nil)
            coordinator.endFullScreen()
            if audioSessionActivated {
                audioSessionActivated = false
                OctonautAudioSession.deactivate()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video player")
    }

    /// Keeps the shared playhead current so dismissing the viewer hands the
    /// feed row back the position the user actually watched to.
    private func observePosition(of player: AVPlayer) {
        removePositionObserver()
        positionObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            MainActor.assumeIsolated {
                OctonautPlaybackCoordinator.shared.record(time.seconds, for: url)
            }
        }
    }

    private func removePositionObserver() {
        if let positionObserver, let player {
            player.removeTimeObserver(positionObserver)
        }
        positionObserver = nil
    }

}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
