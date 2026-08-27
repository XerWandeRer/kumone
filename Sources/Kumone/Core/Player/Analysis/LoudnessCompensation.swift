import Foundation

/// Cross-track loudness compensation: one constant playback gain per song, so
/// two songs meeting at a hand-over arrive at the same perceived level.
///
/// Pain point ④ of docs/automix-research-notes.md — "the next song is suddenly
/// 6 dB louder" — is a *mastering* difference, not a transition bug. No fade
/// curve can fix it, because both sides of the curve are wrong by a constant.
/// The fix is walkywalker's: a per-track trim applied to the whole song
/// (`dj.cpp:18-24` / `tune.cpp:153-173`), with Sony's clip guard on top
/// (`utils_data_normalization.py:79-80`).
///
/// ### Absolute, not pairwise
///
/// The trim is a function of **one** track: `target − referenceLoudness`. It is
/// deliberately not "match the incoming song to the outgoing one", because a
/// deck is loaded before the player knows what follows it, and a pairwise trim
/// would have to change under a running song when the queue changes. An
/// absolute target makes the trim a property of the loaded track, fixed for as
/// long as it plays — which is also why `PlaybackEngine` takes it as a
/// load-time argument and never as a setter.
///
/// ### Attenuate freely, boost barely
///
/// Modern masters sit well above −14 LUFS, so almost every trim is a cut, and a
/// cut is always safe. A boost is capped at `maxBoostDB` (+3 dB) *and* held to
/// whatever headroom the track's own peak leaves — a quiet master with a hot
/// peak gets no boost at all. What a boost cannot recover is exactly the
/// residual the planner's loudness gate still sees (see
/// `TransitionPlanner.signals`).
enum LoudnessCompensation {

    struct Config: Sendable, Equatable {
        /// House level. −14 LUFS is the streaming-platform convention
        /// (Spotify/YouTube/Amazon normalize there), so trims come out small
        /// and mostly negative for contemporary masters.
        var targetLUFS: Double = -14
        /// A quiet master may be lifted at most this far.
        var maxBoostDB: Double = 3
        /// A loud master may be pulled down at most this far. Wide, because a
        /// cut can never misbehave; it exists only to bound absurd input.
        var maxCutDB: Double = 12
        /// A boost must leave the track's peak under this.
        var peakCeilingDBFS: Double = -1
        /// The analyzer measures the peak of a **mono downmix**, which sits at
        /// or below the loudest channel's peak (up to ~3 dB below for wide
        /// stereo). Charge that difference against the headroom so the guard
        /// stays conservative on the real stereo file — and cover
        /// inter-sample overshoot with the same allowance.
        var downmixPeakAllowanceDB: Double = 3

        static let standard = Config()
    }

    /// The playback trim, in dB, for a track that is about to be loaded.
    ///
    /// Zero — unity gain, byte-identical to the pre-compensation player — when
    /// compensation is off, when there is no analysis yet (first listen of a
    /// streamed track), or when the analysis carries no loudness reading.
    static func trimDB(
        for analysis: TrackAnalysis?, enabled: Bool = true, config: Config = .standard
    ) -> Double {
        guard enabled, let loudness = analysis?.referenceLoudness, loudness.isFinite else {
            return 0
        }
        let wanted = config.targetLUFS - loudness
        var trim = min(config.maxBoostDB, max(-config.maxCutDB, wanted))
        if trim > 0 {
            // Sony's clip guard, expressed as a ceiling on the boost instead of
            // a post-hoc rescale: we cannot rescale a live playback stream.
            let peak = (analysis?.peakDBFS ?? 0) + config.downmixPeakAllowanceDB
            trim = min(trim, max(0, config.peakCeilingDBFS - peak))
        }
        return trim
    }

    /// dB → linear gain, the multiplier a fader is scaled by.
    static func gain(fromDB db: Double) -> Float { Float(pow(10.0, db / 20.0)) }
}
