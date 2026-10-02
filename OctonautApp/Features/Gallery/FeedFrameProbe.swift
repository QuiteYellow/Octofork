import Foundation
#if DEBUG
import OSLog
import UIKit
#endif

/// Counts frames the display actually presented, which is the only honest
/// measure of whether scrolling is smooth.
///
/// The previous attempt inferred this from `onScrollGeometryChange` and could
/// not work: a geometry observer fires when geometry changes, so a gap between
/// events means either that frames were skipped or that the reader stopped
/// moving their thumb, and nothing in the timestamp separates the two. Checked
/// against travelled distance, most of what it called a stall turned out to be
/// a slowing finger -- 8 to 22 points over 100 milliseconds, where scrolling
/// proper covered 400 in the same span.
///
/// `CADisplayLink` has no such ambiguity. It ticks once per refresh whether or
/// not anything moved, so a missing tick is a missing frame and nothing else.
/// A hitch is then simply an interval longer than the display's own, and the
/// display says what its own is -- 120Hz on this phone, so 8.3ms, and it drops
/// to 60Hz or lower on its own when nothing is moving, which is why the nominal
/// interval is read per tick rather than assumed.
///
/// ## What changed after 2026-09-30, and why
///
/// The headline was `hitches`, thresholded at `interval > nominal * 1.5`, and
/// that threshold hid the one finding that mattered. A steady 16.7ms against a
/// 12.5ms nominal is 1.34x -- under the threshold on every single frame -- so a
/// display missing a quarter of its refreshes reported `hitches=0`. The signal
/// was only ever in the `frames X/Y` ratio, which was printed third and read as
/// noise.
///
/// So `deficit` leads now: the percentage of intended refreshes that went
/// unfilled, which catches a uniformly slow grid and a stuttering one alike. A
/// hitch is still counted, at a lower threshold, but it answers a different and
/// narrower question -- whether the loss is concentrated in a few long stalls or
/// spread across every frame -- and it is no longer the thing being watched.
///
/// `expected` is accumulated per tick as `interval / nominal` rather than
/// divided out at the end. The display changes its own rate mid-window, so one
/// closing value of `nominal` does not describe the second that just passed.
///
/// Reported once per second, alongside how many content-height changes landed
/// in the same second, so a hitch can be attributed to layout or ruled clear
/// of it.
///
/// One category per surface, because attributing a hitch means reading what
/// happened either side of it and the feed's rows are noise while the grid is
/// the thing under test. Both can still be read together:
///
///     log show probe.logarchive --predicate 'category ENDSWITH ".jitter"'
@MainActor
final class FeedFrameProbe {
    /// Which surface this probe is watching. `FeedPerf` splits the same way and
    /// for the same reason.
    enum Surface: String {
        case feed = "feed.jitter"
        case gallery = "gallery.jitter"
    }

    init(surface: Surface = .feed) {
        self.surface = surface
    }

    private let surface: Surface

    /// Starts counting. Idempotent, so a view can call it from `task` without
    /// checking.
    func start() {
#if DEBUG
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
#endif
    }

    func stop() {
#if DEBUG
        link?.invalidate()
        link = nil
        reset()
#endif
    }

    /// Told from the outside, so a hitch can be lined up against the list
    /// re-measuring itself rather than guessed at.
    func noteContentHeightChange() {
#if DEBUG
        heightChanges += 1
#endif
    }

#if DEBUG
    private var link: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var windowStart: CFTimeInterval?
    private var frames = 0
    /// Refreshes the display intended to present during this window, summed per
    /// tick against the nominal in force at the time.
    private var expected: Double = 0
    private var hitches = 0
    private var longestInterval: CFTimeInterval = 0
    private var heightChanges = 0

    private lazy var logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Octonaut", category: surface.rawValue)

    /// A frame served more than a quarter of a frame late. Low enough to catch
    /// a uniform deficit, which `1.5` did not; `deficit` is still the headline
    /// and this only says whether the loss is bunched or spread.
    private static let hitchThreshold: Double = 1.25

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        // What this display intends between frames right now. It lowers its
        // own rate when little is moving, so a fixed 8.3ms would report every
        // idle moment as a hitch.
        let nominal = link.targetTimestamp - link.timestamp
        defer { previousTimestamp = now }
        guard let previous = previousTimestamp else {
            windowStart = now
            return
        }
        let interval = now - previous
        frames += 1
        longestInterval = max(longestInterval, interval)
        if nominal > 0 {
            expected += interval / nominal
            if interval > nominal * Self.hitchThreshold { hitches += 1 }
        }
        guard let start = windowStart, now - start >= 1 else { return }
        report(seconds: now - start, nominal: nominal)
        // The counters share this tick so the two lines land together and a
        // population can be read from a grid that has come to rest. Left to
        // flush themselves they only reported while something was still
        // happening, which is the opposite of when a standing level matters.
        FeedPerf.tick()
        windowStart = now
        reset()
    }

    private func report(seconds: CFTimeInterval, nominal: CFTimeInterval) {
        let intended = Int(expected.rounded())
        // The share of intended refreshes that went unfilled. Zero when the app
        // kept up, whether the display was asking for 120Hz or had idled to 60.
        let deficit = expected > 0
            ? max(0, (expected - Double(frames)) / expected * 100)
            : 0
        logger.notice(
            """
            deficit \(String(format: "%.0f", deficit), privacy: .public)% \
            frames \(self.frames, privacy: .public)/\(intended, privacy: .public) \
            hitches=\(self.hitches, privacy: .public) \
            longest=\(String(format: "%.1f", self.longestInterval * 1000), privacy: .public)ms \
            nominal=\(String(format: "%.1f", nominal * 1000), privacy: .public)ms \
            heightChanges=\(self.heightChanges, privacy: .public)
            """)
    }

    private func reset() {
        frames = 0
        expected = 0
        hitches = 0
        longestInterval = 0
        heightChanges = 0
    }
#endif
}
