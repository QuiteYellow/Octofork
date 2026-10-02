import AVFoundation
import UIKit

/// A small, capped set of `AVPlayer`s handed between gallery tiles.
///
/// A player per tile is the wrong shape however well mounting is gated. The
/// 160ms dwell stopped the grid *creating* six to seventeen players a second
/// while a thumb went past, and measured near zero afterwards -- but it did
/// nothing about how many are alive at once, which is the cost that scales
/// with how far the reader has scrolled rather than how fast.
///
/// So the grid owns a fixed number of players and lends them out. A tile that
/// wants to show video takes a lease; when every player is out, the lease that
/// has gone longest without being renewed is revoked and its player handed to
/// the new tile. The ceiling on decoders, buffers and network sessions is then
/// the pool size rather than the scroll depth.
///
/// ## Why the layer moves and the player does not
///
/// `AVPlayerLayer` is the expensive half to build and the cheap half to move.
/// Each pooled entry keeps its player and its layer together for life, and a
/// lease re-parents that layer into the borrowing tile's host view. Nothing is
/// allocated on the hot path: taking a lease swaps an `AVPlayerItem` and moves
/// a layer between superlayers.
///
/// This is also why the grid does not reuse `OctonautVideoPlayer`, which is
/// otherwise the right thing everywhere else in the app. It mounts an
/// `AVPlayerViewController` -- a whole view controller, its own gesture
/// recognisers and a transport UI the grid hides anyway -- and it owns its
/// player in `@State`, so its lifetime is the view's and cannot be pooled. A
/// feed row showing one video at a time can afford that; twenty tiles cannot.
@MainActor
final class GalleryPlayerPool {
    /// How many videos may run at once.
    ///
    /// Was four, and four was wrong -- but the number was only half of why.
    /// A lease used to go to every video tile in view whether it was playing
    /// or not, so four players had to cover every video on screen, and in a
    /// GIF-heavy gallery they ran out immediately. Now only a tile that is
    /// actually playing takes one, so the same pool goes much further.
    ///
    /// Ten, which covers a full screen of video rather than most of one.
    ///
    /// The geometry: on a 430pt-wide phone a two-column tile is ~209pt, and
    /// the 9:16 clamp makes the shortest tile ~118pt, so a column of an 800pt
    /// viewport holds about seven tiles at or past the half-visible mark --
    /// fourteen across both columns, and that is the genuine worst case of an
    /// all-landscape-video screen.
    ///
    /// Eight was picked to cover "a screenful of medium-to-tall video" and
    /// left the densest screens short. Ten covers everything but that worst
    /// case, and the worst case degrades in the right direction anyway:
    /// `updatePlayers` ranks by distance from the middle of the screen, so
    /// the videos nearest where the reader is looking are the ones that run
    /// and the rest show their posters.
    ///
    /// What makes ten affordable is that this bounds *concurrent playback*
    /// and not much else. Players are created once and reused for the life of
    /// the grid -- measured, three were ever created across a 300-tile sweep
    /// -- so the ceiling is on decoders running at once, not on allocation
    /// churn. The fling gate in `updatePlayers` keeps even that from being
    /// reached while the grid is moving fast.
    static let capacity = 10
    static let shared = GalleryPlayerPool(capacity: capacity)

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    private let capacity: Int
    private var entries: [Entry] = []
    /// Rises on every lease, so "least recently asked for" is a comparison
    /// rather than a wall-clock reading.
    private var clock: UInt64 = 0

    fileprivate final class Entry {
        let player: AVPlayer
        let layer: AVPlayerLayer
        var url: URL?
        var lastUsed: UInt64 = 0
        var looper: OctonautVideoLooper?
        /// Keeps the layer hidden until it has a frame of the *current* item.
        ///
        /// A pooled layer holds the last frame it drew, so handing it to
        /// another tile showed that tile the previous video for as long as
        /// the new item took to load -- the flash of someone else's GIF in a
        /// recycled slot. Hiding the layer across the swap means the tile
        /// shows its own poster until there is really something to show.
        var readiness: Task<Void, Never>?
        /// The lease currently holding this entry, so revoking it can tell the
        /// tile its video has gone rather than leaving a tile pointing at a
        /// layer that now shows someone else's frames.
        weak var lease: Lease?

        init(player: AVPlayer, layer: AVPlayerLayer) {
            self.player = player
            self.layer = layer
        }
    }

    /// A tile's claim on one pooled player.
    ///
    /// Held by the cell. Releasing it -- explicitly, or by the cell being
    /// reused -- returns the player. A lease that has been revoked answers
    /// `isValid == false`, so a late callback cannot drive a player another
    /// tile now owns.
    @MainActor
    final class Lease {
        fileprivate weak var pool: GalleryPlayerPool?
        fileprivate let entry: Entry
        let url: URL

        fileprivate init(pool: GalleryPlayerPool, entry: Entry, url: URL) {
            self.pool = pool
            self.entry = entry
            self.url = url
        }

        var isValid: Bool { entry.lease === self }

        var player: AVPlayer? { isValid ? entry.player : nil }

        func play() {
            guard isValid else { return }
            entry.player.play()
        }

        func pause() {
            guard isValid else { return }
            entry.player.pause()
        }

        func release() {
            guard isValid else { return }
            pool?.release(entry)
        }
    }

    /// Lends a player for `url`, showing it in `host`.
    ///
    /// Re-leasing a URL a tile already holds is deliberately cheap: the entry
    /// keeps its item, so a cell that is re-configured with the same video --
    /// which happens whenever the grid re-applies a snapshot -- does not
    /// restart it.
    func lease(url: URL, in host: UIView, muted: Bool, loops: Bool) -> Lease {
        clock += 1
        let entry = entryFor(url: url)
        entry.lastUsed = clock
        entry.player.isMuted = muted

        // Attaching an item is what starts the fetch, so that is where the
        // gate has to refuse. Refusing in the condition rather than inside the
        // body matters: the entry never adopts the URL, so it still looks
        // stale and the next lease retries once the gate opens.
        if entry.url != url, OctonautNetworkGate.permits(url) {
            entry.url = url
            entry.looper?.detach()
            entry.looper = nil
            // Hidden before the swap, not after: the layer is still holding
            // the previous tile's last frame, and the whole point is that it
            // never gets drawn in this tile.
            setHidden(true, on: entry.layer)
            let item = AVPlayerItem(url: url)
            entry.player.replaceCurrentItem(with: item)
            revealWhenReady(entry, item: item)
            if loops {
                let looper = OctonautVideoLooper()
                looper.attach(to: entry.player)
                entry.looper = looper
            }
        }

        attach(entry.layer, to: host)

        let lease = Lease(pool: self, entry: entry, url: url)
        entry.lease = lease
        return lease
    }

    /// Stops every player and empties the pool. Called when the grid goes
    /// away, so a gallery left behind holds no decoders.
    func releaseAll() {
        for entry in entries {
            entry.lease = nil
            entry.player.pause()
            entry.player.replaceCurrentItem(with: nil)
            entry.looper?.detach()
            entry.looper = nil
            entry.readiness?.cancel()
            entry.readiness = nil
            entry.url = nil
            Self.setHidden(true, on: entry.layer)
            entry.layer.removeFromSuperlayer()
        }
    }

    private func entryFor(url: URL) -> Entry {
        // Already holding this video and not in use: the best possible case,
        // because the item does not have to be replaced and the layer is
        // already showing the right thing.
        //
        // The `lease == nil` half matters and was missing. Matching on URL
        // alone took the player away from a tile that was visible and
        // playing it, purely because another tile wanted the same video --
        // which happens with a crosspost, a repost, or the same clip twice
        // in one feed. The victim went back to its poster and then had to
        // re-lease, so two tiles traded one player back and forth.
        if let existing = entries.first(where: { $0.url == url && $0.lease == nil }) {
            reclaim(existing)
            return existing
        }
        // A free player, if the pool has not filled yet.
        if let idle = entries.first(where: { $0.lease == nil }) {
            return idle
        }
        if entries.count < capacity {
            let made = makeEntry()
            entries.append(made)
            return made
        }
        // Everything is out. Take the one nobody has asked for in longest.
        guard let victim = entries.min(by: { $0.lastUsed < $1.lastUsed }) else {
            let made = makeEntry()
            entries.append(made)
            return made
        }
        reclaim(victim)
        return victim
    }

    /// Detaches an entry from whoever holds it, so it can be handed on.
    private func reclaim(_ entry: Entry) {
        entry.lease = nil
        entry.player.pause()
        entry.layer.removeFromSuperlayer()
    }

    private func release(_ entry: Entry) {
        entry.lease = nil
        entry.player.pause()
        entry.layer.removeFromSuperlayer()
        // The item is kept. A tile scrolled just off screen is the likeliest
        // next borrower of this exact video, and keeping the item makes
        // coming back free; `entryFor` drops it the moment the entry is
        // handed to a different URL.
    }

    private func makeEntry() -> Entry {
        let player = AVPlayer()
        player.allowsExternalPlayback = false
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        // `automaticallyWaitsToMinimizeStalling` is deliberately left at its
        // default of true.
        //
        // It was set to false here with the note that "nothing in a grid tile
        // wants to stall the pipeline waiting for a perfectly smooth start;
        // the tile is a hundred points wide". That is not a reason -- tile
        // size has nothing to do with buffering -- and it was never checked.
        // Turning it off tells `play()` to start at once on an empty buffer,
        // which is for media already to hand. A Reddit video is an HLS
        // playlist fetched over the network, where it means the player goes
        // to rate 1.0 with nothing to render.
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        // Nothing to show yet, so show nothing. The borrowing tile's poster
        // is underneath and is what the reader sees until this turns true.
        layer.isHidden = true
        return Entry(player: player, layer: layer)
    }

    /// Reveals an entry's layer once it is showing a frame of *this* item.
    ///
    /// `isReadyForDisplay` alone is not enough, and relying on it was the
    /// first attempt at this and did not work. The flag describes whether the
    /// layer has something to draw, and a pooled layer that was mid-playback
    /// a moment ago still does -- it is not reset by
    /// `replaceCurrentItem(with:)`. So the very first poll, which runs before
    /// any sleep, saw `true` left over from the previous tile and revealed
    /// the layer instantly, showing exactly the stale GIF this is supposed to
    /// prevent.
    ///
    /// The third condition is the one that cannot be satisfied by a stale
    /// frame: `currentTime` belongs to the current item and starts at zero
    /// when the item is replaced, so a time past zero is positive proof that
    /// the *new* item is the one producing frames. The identity check pins it
    /// further -- a later swap replaces `currentItem`, and this loop should
    /// then do nothing rather than reveal on another item's behalf.
    ///
    /// A video that never loads never satisfies any of it, so the tile keeps
    /// its poster, which is the right outcome rather than a failure.
    ///
    /// Polled rather than observed through KVO, which is not a style choice:
    /// `AVPlayerLayer` is not `Sendable`, so a `@Sendable` KVO closure may
    /// not touch it, and the identifier round trip needed to reach it again
    /// on the main actor is worse than this loop. `OctonautVideoPlayer` waits
    /// for its own first frame the same way and on the same kind of deadline.
    /// How long the strict proof is insisted on before weaker proof will do.
    private static let revealGrace: TimeInterval = 0.8
    /// When to stop waiting at all. Generous, because the cost of giving up
    /// early is a video that plays where nobody can see it.
    private static let revealDeadline: TimeInterval = 20

    private func revealWhenReady(_ entry: Entry, item: AVPlayerItem) {
        entry.readiness?.cancel()
        let started = Date.now
        entry.readiness = Task { @MainActor in
            while !Task.isCancelled, Date.now.timeIntervalSince(started) < Self.revealDeadline {
                // A later swap owns the layer now; this loop must not reveal
                // on another item's behalf.
                guard entry.player.currentItem === item else { return }
                let elapsed = Date.now.timeIntervalSince(started)
                if entry.layer.isReadyForDisplay {
                    // `currentTime > 0` proves the new item is the one
                    // producing frames, and for the first moments it is worth
                    // insisting on: that is what keeps the previous tile's
                    // last frame off screen.
                    //
                    // Insisting on it forever fails in the wrong direction.
                    // Playback over a network can take seconds to produce a
                    // first frame, and the old version gave up after six --
                    // leaving the layer hidden for the life of the lease even
                    // when the video was playing perfectly well underneath. A
                    // video playing invisibly cannot be told apart from one
                    // that never plays, which is very likely what was
                    // reported from the phone.
                    //
                    // So past a grace period an item that has reached
                    // `.readyToPlay` counts as evidence enough. Worst case is
                    // a brief stale frame; the alternative is never showing
                    // the video at all.
                    let playing = entry.player.currentTime().seconds > 0
                    let settled = elapsed > Self.revealGrace && item.status == .readyToPlay
                    if playing || settled {
                        Self.setHidden(false, on: entry.layer)
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    /// Without an implicit animation. A layer appearing or being swapped
    /// mid-scroll must not fade.
    private static func setHidden(_ hidden: Bool, on layer: CALayer) {
        guard layer.isHidden != hidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = hidden
        CATransaction.commit()
    }

    private func setHidden(_ hidden: Bool, on layer: CALayer) {
        Self.setHidden(hidden, on: layer)
    }

    private func attach(_ layer: AVPlayerLayer, to host: UIView) {
        guard layer.superlayer !== host.layer else {
            layer.frame = host.bounds
            return
        }
        layer.removeFromSuperlayer()
        // No implicit animation: a layer being re-parented mid-scroll must not
        // fade or slide into its new tile.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = host.bounds
        host.layer.addSublayer(layer)
        CATransaction.commit()
    }
}
