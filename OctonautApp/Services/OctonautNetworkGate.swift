import Foundation
#if OCTOFORK_DEV_ADDIN
import OctoforkAddinKit
#endif

/// Asked before anything this app sends leaves the device.
///
/// An optional out-of-tree add-in, built into one local variant only, can
/// require a precondition to be met before the app opens a connection. This is
/// the single place that is asked, and every call site that opens a connection
/// goes through it -- a gate the Reddit client honours but the image cache
/// does not, or the image cache but not video playback, would be worse than no
/// gate at all, because it would report a guarantee it is not keeping.
///
/// Without `OCTOFORK_DEV_ADDIN` -- which is to say in upstream Octonaut and in
/// the fork's ordinary variant -- both members compile to an unconditional
/// yes, and the add-in's own repository holds the reasoning for the rest.
enum OctonautNetworkGate {
    /// Holds until the precondition is met, or throws.
    ///
    /// Returns immediately unless the add-in is present, configured, and
    /// currently withholding permission, so the cost on the ordinary path is
    /// one `await` that does nothing.
    static func waitUntilPermitted() async throws {
#if OCTOFORK_DEV_ADDIN
        try await OctoforkAddin.Gate.shared.waitUntilPermitted()
#endif
    }

    /// The synchronous answer, for the places that cannot wait.
    ///
    /// `AVURLAsset` is built in synchronous code, and an asset handed to a
    /// player fetches on its own schedule through AVFoundation rather than
    /// through any `URLSession` this app owns -- so it cannot be gated after
    /// the fact. Refusing to build it is the only point of control.
    static var isPermitted: Bool {
#if OCTOFORK_DEV_ADDIN
        OctoforkAddin.Gate.shared.isPermitted
#else
        true
#endif
    }
}

extension OctonautNetworkGate {
    /// Local files are always allowed. Media the app already downloaded sits
    /// in its own container, and refusing to read it would make the gate look
    /// broken while withholding nothing.
    static func waitUntilPermitted(for url: URL) async throws {
        guard !url.isFileURL else { return }
        try await waitUntilPermitted()
    }

    static func permits(_ url: URL) -> Bool {
        url.isFileURL || isPermitted
    }
}
