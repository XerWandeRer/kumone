import Foundation
import os

/// A one-line-per-event journal of the seam machinery, written to the unified
/// log so a field incident can be reconstructed after the fact.
///
///     log show --predicate 'subsystem == "im.missuo.Kumone"' --last 30m
///
/// **Why this exists.** The watery-playback bug is a deck left with its
/// time-pitch unit off unity and no transition to explain it. Nothing in the
/// system resolves that on its own — the music simply stays underwater until
/// the track ends — and by the time anyone hears it, every piece of state that
/// would say *which* teardown path dropped the plan is gone. The panel shows
/// the symptom live; this shows how the seam got there.
///
/// **Rules.** Every line is written from the engine's serial queue (or the main
/// actor), never from a render callback — we run no code on the realtime thread
/// and this must not become the first thing that does. Every line is a
/// lifecycle event, a handful per seam, never per tick: the string is built
/// eagerly, which is only acceptable because these are rare.
///
/// Values are logged `.public` on purpose. This is engineering telemetry about
/// tempo and gain, not about the listener; the only user data anywhere near it
/// is a track title, which is deliberately not included.
enum PlaybackJournal {

    static let log = Logger(subsystem: "im.missuo.Kumone", category: "automix")

    static func note(_ message: String) {
        log.log("\(message, privacy: .public)")
    }

    /// `a=×1.0000 b=×1.0630` — the two rates, on every line where a stuck one
    /// would be the story.
    static func rates(_ a: Float, _ b: Float) -> String {
        String(format: "a=×%.4f b=×%.4f", a, b)
    }
}
