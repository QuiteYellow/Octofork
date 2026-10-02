import Foundation
import SwiftUI
#if DEBUG
import OSLog
#endif

/// Where the time goes while the feed and the gallery are being scrolled.
///
/// Four candidates were reasoned from the code and none of them can be
/// separated by looking harder at it: the per-frame rebuild of
/// `visiblePosts`, the read rule that walks it again, markdown re-parsed on
/// every body evaluation, and the gallery recomputing `items` twice a pass.
/// They all scale with `posts.count`, so they all get worse together and a
/// guess between them is worth nothing.
///
/// Counters rather than lines. A probe that logged every call would be slower
/// than what it is measuring, so each site accumulates a count and a
/// duration, and one summary is emitted per second of activity. Nesting is
/// deliberate and the totals therefore overlap -- `markScrolledPast`
/// contains a `visiblePosts` -- so read each row against the frame count,
/// never as a share of a sum.
///
/// Two categories, so one screen can be watched without the other's rows in
/// the way: `feed.perf` for the list, `gallery.perf` for the grid. Each keeps
/// its own second and emits its own line.
///
/// Debug builds only; in Release `measure` is the closure and nothing else.
///
///     log collect --device-udid <udid> --last 10m --output perf.logarchive
///     log show perf.logarchive --predicate 'category == "gallery.perf"'
enum FeedPerf {
    /// Which log category a key reports under, so the feed and the gallery
    /// can be watched one at a time. Each keeps its own second.
    enum Group: Int, CaseIterable {
        case feed
        case gallery

        var category: String {
            switch self {
            case .feed: "feed.perf"
            case .gallery: "gallery.perf"
            }
        }
    }

    enum Key: Int, CaseIterable {
        case scrollFrame
        case visiblePosts
        case markScrolledPast
        case markdownBlocks
        case markdownAttributed
        case galleryItems
        case galleryColumns
        /// A tile deciding to show a player -- an `AVPlayer` being created.
        /// Churn, not a standing count: mounting is the expensive half, and a
        /// grid that mounts forty a second is a different problem from one
        /// holding forty open.
        case galleryPlayerMount
        /// A mounted player being told to run.
        case galleryPlayerPlay
        /// A tile asking the image cache for its still.
        case galleryImageFetch

        var label: String {
            switch self {
            case .scrollFrame: "frames"
            case .visiblePosts: "visiblePosts"
            case .markScrolledPast: "markScrolledPast"
            case .markdownBlocks: "mdBlocks"
            case .markdownAttributed: "mdAttrString"
            case .galleryItems: "items"
            case .galleryColumns: "columns"
            case .galleryPlayerMount: "playerMount"
            case .galleryPlayerPlay: "playerPlay"
            case .galleryImageFetch: "imageFetch"
            }
        }

        var group: Group {
            switch self {
            case .scrollFrame, .visiblePosts, .markScrolledPast, .markdownBlocks,
                 .markdownAttributed:
                .feed
            case .galleryItems, .galleryColumns, .galleryPlayerMount, .galleryPlayerPlay,
                 .galleryImageFetch:
                .gallery
            }
        }
    }

    /// Times `work` against `key` and returns what it returned.
    static func measure<T>(_ key: Key, _ work: () -> T) -> T {
#if DEBUG
        let start = DispatchTime.now().uptimeNanoseconds
        let value = work()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        MainActor.assumeIsolated { Totals.shared(key.group).record(key, nanos: elapsed) }
        return value
#else
        work()
#endif
    }

    /// Counts an occurrence with no duration worth taking -- a scroll frame,
    /// or a player being created.
    static func count(_ key: Key) {
#if DEBUG
        MainActor.assumeIsolated { Totals.shared(key.group).record(key, nanos: 0) }
#endif
    }

    /// Moves a gauge that stands still between changes -- how many tiles and
    /// players are alive right now, rather than how many were made.
    ///
    /// Churn was the first guess and measured near zero once mounting waited
    /// for a dwell, which rules out creation and says nothing about
    /// population. A `LazyVStack` defers making its subviews but does not
    /// recycle them the way a collection view does, so the question is
    /// whether a deep scroll leaves hundreds of tiles and their players
    /// alive behind it.
    ///
    /// `tiles` and `retained` answer two halves of that and can disagree,
    /// which is the point. `tiles` counts what the stack has *realised* --
    /// moved by `onAppear` and `onDisappear`, so it falls when a tile leaves
    /// the realised range. `retained` counts tiles whose SwiftUI state is
    /// still allocated, moved from the `init` and `deinit` of a state-held
    /// object, and it falls only when that state is genuinely discarded.
    ///
    /// A container that recycles keeps both flat and roughly equal. A stack
    /// that merely defers keeps `retained` climbing with scroll depth while
    /// `tiles` stays near a screenful -- and `retained` is then the cost,
    /// because a retained tile still holds its image, its observers and its
    /// player. Reading only `tiles` would have called that grid healthy.
    static func gauge(_ gauge: Gauge, _ delta: Int, group: Group = .gallery) {
#if DEBUG
        MainActor.assumeIsolated { Totals.shared(group).move(gauge, by: delta) }
#endif
    }

    enum Gauge: Int, CaseIterable {
        case liveTiles
        case livePlayers
        case retainedTiles

        var label: String {
            switch self {
            case .liveTiles: "tiles"
            case .livePlayers: "players"
            case .retainedTiles: "retained"
            }
        }
    }

    /// Emits any group whose second has elapsed, whether or not anything
    /// happened in it.
    ///
    /// Without this the probe could not answer the question it was built for.
    /// `record` and `move` only flush on their way past, so a grid that came
    /// to rest stopped reporting -- and a standing population is exactly what
    /// wants reading at rest. Two tiles sat on screen through an eight-second
    /// capture and `gallery.perf` printed nothing at all.
    ///
    /// Driven from `FeedFrameProbe`'s per-second report, so the counters and
    /// the frame line share a cadence and can be read against each other.
    /// Only groups that already exist are flushed: a surface nobody has
    /// instrumented should stay silent rather than print empty rows.
    static func tick() {
#if DEBUG
        MainActor.assumeIsolated { Totals.flushDue() }
#endif
    }

    /// How many posts the store holds, so a cost can be read per post rather
    /// than in the abstract. Last value wins.
    ///
    /// Deliberately the stored count and nothing derived: asking for
    /// `visiblePosts.count` here would run the very filter being measured,
    /// once per frame, purely because the probe was watching.
    static func size(posts: Int) {
#if DEBUG
        MainActor.assumeIsolated {
            for group in Group.allCases { Totals.shared(group).posts = posts }
        }
#endif
    }
}

#if DEBUG
@MainActor
private final class Totals {
    private static var instances: [FeedPerf.Group: Totals] = [:]

    static func shared(_ group: FeedPerf.Group) -> Totals {
        if let existing = instances[group] { return existing }
        let made = Totals(group: group)
        instances[group] = made
        return made
    }

    static func flushDue() {
        let now = DispatchTime.now().uptimeNanoseconds
        for totals in instances.values where now - totals.windowStart >= window {
            totals.flush(elapsedWindow: now - totals.windowStart)
            totals.windowStart = now
        }
    }

    private let group: FeedPerf.Group
    private let logger: Logger

    init(group: FeedPerf.Group) {
        self.group = group
        self.logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "Octonaut", category: group.category)
    }

    private var counts = [Int](repeating: 0, count: FeedPerf.Key.allCases.count)
    private var nanos = [UInt64](repeating: 0, count: FeedPerf.Key.allCases.count)
    private var windowStart = DispatchTime.now().uptimeNanoseconds
    private var gauges = [Int](repeating: 0, count: FeedPerf.Gauge.allCases.count)
    var posts = 0

    /// Gauges are not reset with the counters: they are a standing level, not
    /// something that happened during the second.
    func move(_ gauge: FeedPerf.Gauge, by delta: Int) {
        gauges[gauge.rawValue] = max(0, gauges[gauge.rawValue] + delta)
        // A level changing is reason enough to report, or a grid that has
        // stopped counting anything else would never show its population.
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - windowStart >= Self.window else { return }
        flush(elapsedWindow: now - windowStart)
        windowStart = now
    }

    private static let window: UInt64 = 1_000_000_000

    func record(_ key: FeedPerf.Key, nanos elapsed: UInt64) {
        counts[key.rawValue] += 1
        nanos[key.rawValue] += elapsed
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - windowStart >= Self.window else { return }
        flush(elapsedWindow: now - windowStart)
        windowStart = now
    }

    private func flush(elapsedWindow: UInt64) {
        var parts: [String] = []
        for key in FeedPerf.Key.allCases where key.group == group && counts[key.rawValue] > 0 {
            let count = counts[key.rawValue]
            let milliseconds = Double(nanos[key.rawValue]) / 1_000_000
            parts.append(
                milliseconds > 0
                    ? "\(key.label) \(count)x \(String(format: "%.1f", milliseconds))ms"
                    : "\(key.label) \(count)x")
        }
        counts = [Int](repeating: 0, count: FeedPerf.Key.allCases.count)
        nanos = [UInt64](repeating: 0, count: FeedPerf.Key.allCases.count)
        if gauges.contains(where: { $0 > 0 }) {
            let levels = FeedPerf.Gauge.allCases
                .map { "\($0.label)=\(gauges[$0.rawValue])" }
                .joined(separator: " ")
            parts.insert(levels, at: 0)
        }
        guard !parts.isEmpty else { return }
        let seconds = Double(elapsedWindow) / 1_000_000_000
        let summary = parts.joined(separator: " | ")
        logger.notice(
            "perf \(String(format: "%.1f", seconds), privacy: .public)s posts=\(self.posts, privacy: .public) \(summary, privacy: .public)"
        )
    }
}
#endif

/// Holds a gauge up for exactly as long as the object lives, so a view can
/// report its own population by holding one in `@State`.
///
/// Deliberately not `onAppear`/`onDisappear`, which report *realisation* --
/// whether the container has the view on screen -- and so cannot see a tile
/// the container has scrolled past but is still holding. SwiftUI allocates
/// this when it first keeps the view's state and releases it when it discards
/// it, which is the population question asked directly.
///
/// Not `@MainActor`, because a `deinit` on an isolated class cannot touch its
/// own stored properties under strict concurrency. SwiftUI tears state down on
/// the main actor, so `assumeIsolated` holds; it would trap rather than
/// silently miscount if that ever stopped being true.
final class PerfLifetime {
#if DEBUG
    private let gauge: FeedPerf.Gauge
    private let group: FeedPerf.Group

    init(_ gauge: FeedPerf.Gauge, group: FeedPerf.Group = .gallery) {
        self.gauge = gauge
        self.group = group
        MainActor.assumeIsolated { FeedPerf.gauge(gauge, 1, group: group) }
    }

    deinit {
        let gauge = self.gauge
        let group = self.group
        MainActor.assumeIsolated { FeedPerf.gauge(gauge, -1, group: group) }
    }
#else
    init(_ gauge: FeedPerf.Gauge, group: FeedPerf.Group = .gallery) {}
#endif
}

/// Holds a gauge up for as long as SwiftUI keeps this view's state.
///
/// Attached to the player rather than counted at the call site because the
/// `AVPlayer` is owned by `OctonautVideoPlayer`'s own `@State`, so the only
/// thing whose lifetime matches the player's is the view holding it.
///
/// One caveat on reading it: `@State`'s initial value is built on every
/// struct initialisation, not only the one SwiftUI keeps, so the discarded
/// copies each add a `+1` and an immediate `-1`. The standing level is exact;
/// the level *during* a body evaluation is not. Read it at a standstill.
struct PerfGauge: ViewModifier {
    @State private var lifetime: PerfLifetime

    init(_ gauge: FeedPerf.Gauge, group: FeedPerf.Group) {
        _lifetime = State(initialValue: PerfLifetime(gauge, group: group))
    }

    func body(content: Content) -> some View { content }
}

extension View {
    /// Counts this view into a gauge for as long as its state lives.
    func perfGauge(_ gauge: FeedPerf.Gauge, group: FeedPerf.Group = .gallery) -> some View {
        modifier(PerfGauge(gauge, group: group))
    }
}
