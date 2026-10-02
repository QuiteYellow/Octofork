#if DEBUG
import OSLog
import SwiftUI
import UIKit

/// Scrolls a gallery at a fixed rate so two containers can be compared.
///
/// Measurement scaffolding for item M. There is no way to tap or swipe a
/// simulator from here -- `simctl` has no input command -- so a scroll has to
/// come from inside the app. That is fine, and in one way better than a thumb:
/// it is repeatable, so the two containers are moved over the same distance at
/// the same speed and the frame counts mean something against each other.
///
/// **Both containers are driven through their `UIScrollView`, deliberately.**
/// The obvious alternative was `ScrollViewProxy.scrollTo` for the SwiftUI grid
/// and `setContentOffset` for the collection view, and that would have made
/// the comparison worthless: two different motion profiles, one animated by
/// SwiftUI and one linear, reported as though they were the same test. A
/// `ScrollView` is a `UIScrollView` underneath, so `ScrollViewFinder` goes and
/// gets it and both then move under identical code.
///
/// Set `OCTONAUT_AUTOSCROLL` to the number of seconds the sweep should take.
@MainActor
enum GalleryScrollDriver {
    static var requestedDuration: Double? {
        ProcessInfo.processInfo.environment["OCTONAUT_AUTOSCROLL"].flatMap(Double.init)
    }

    /// Sweeps to the bottom and back, so the return leg measures a container
    /// re-showing tiles it has already been past -- which is where a grid that
    /// kept everything looks fastest and a grid that recycles has to work.
    /// The sweep in progress, if any.
    ///
    /// A singleton because the first run was not one. SwiftUI rebuilt the
    /// comparison grid's `ScrollViewFinder` several times, each rebuild got
    /// its own coordinator and so its own `found` call, and the columns grid
    /// ended up with four sweeps driving the same scroll view at once --
    /// four times the `setContentOffset` calls and four task wake-ups every
    /// 8ms, all charged to the container under test. The recycling grid,
    /// driven once from `makeUIView`, had one. That is a difference in the
    /// harness being read as a difference in the code, which is exactly the
    /// failure the tracker warns about.
    private static var active: Task<Void, Never>?

    static func start(_ scrollView: UIScrollView) -> Task<Void, Never>? {
        guard let duration = requestedDuration else { return nil }
        guard active == nil else { return nil }
        let task = Task { @MainActor in
            // Let the first page lay out before moving.
            try? await Task.sleep(for: .seconds(2))
            await sweep(scrollView, duration: duration, returning: false)
            try? await Task.sleep(for: .seconds(1))
            await sweep(scrollView, duration: duration, returning: true)
            logger.notice("sweep complete")
        }
        active = task
        return task
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Octonaut", category: "gallery.sweep")

    private static func sweep(
        _ scrollView: UIScrollView, duration: Double, returning: Bool
    ) async {
        let step = Duration.milliseconds(8)
        let ticks = max(1, Int(duration * 1000 / 8))
        var peak: CGFloat = 0
        defer {
            // The validity check on the whole comparison. Two containers only
            // have comparable frame counts if they were moved over comparable
            // distances, and "it looked like it scrolled" is not that. A grid
            // that quietly travelled half as far would post half the hitches
            // and read as a fix.
            logger.notice(
                """
                sweep \(returning ? "up" : "down", privacy: .public) \
                peak=\(String(format: "%.0f", peak), privacy: .public) \
                content=\(String(format: "%.0f", scrollView.contentSize.height), privacy: .public)
                """)
        }
        for tick in 0...ticks {
            peak = max(peak, scrollView.contentOffset.y)
            guard !Task.isCancelled else { return }
            // Read the travel every tick: paging grows the content while the
            // sweep is running, and a distance captured up front would stop
            // short of the bottom the moment a page landed.
            let travel = max(
                0, scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom)
            let progress = Double(tick) / Double(ticks)
            let fraction = returning ? 1 - progress : progress
            scrollView.setContentOffset(
                CGPoint(
                    x: 0,
                    y: travel * fraction - scrollView.adjustedContentInset.top),
                animated: false)
            try? await Task.sleep(for: step)
        }
    }
}

/// Hands back the `UIScrollView` a SwiftUI `ScrollView` is built on.
///
/// Measurement scaffolding, and the only part of this work that reaches for
/// something SwiftUI does not offer. It is confined to `#if DEBUG` and to the
/// comparison grid, which is itself deleted once the numbers are recorded.
struct ScrollViewFinder: UIViewRepresentable {
    let found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard !context.coordinator.hasReported else { return }
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    context.coordinator.hasReported = true
                    found(scrollView)
                    return
                }
                ancestor = current.superview
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hasReported = false
    }
}
#endif
