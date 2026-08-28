import Foundation

/// The transition's parameter curves, as a pure function of time.
///
/// This is the single description of *what a hand-over does to the two decks*:
/// given the plan, the chosen style and how far into the overlap we are, it
/// returns the target fader / EQ / high-pass / delay / rate values for both
/// decks. `PlaybackEngine` applies a frame per real-time tick; the offline
/// renderer (`OfflineTransitionRenderer`, used by the `audition` CLI) applies
/// the same frames to an identical node graph in manual rendering mode. There
/// is exactly one copy of the curves, so what you audition offline is what the
/// player does.
///
/// Statefulness note: the real engine treats `.echoOut`'s delay throw as a
/// one-shot event (`echoThrown`). Here it is expressed as a *predicate on
/// time* — "the progress has crossed the stop point" — which yields the same
/// parameter values on every tick, because everything the throw sets is
/// constant for the transition. The caller keeps whatever latch it needs
/// (the engine still latches, so the settling phase knows a tail is ringing).
enum TransitionAutomation {

    // MARK: - Tuning constants
    //
    // These are the knobs to turn when tuning how a transition *sounds*;
    // `TransitionPlanner`'s constants decide which transition you get at all.

    /// How far the low shelf ducks at full cut (plain bass swap and staged).
    static let bassCutDB: Float = -24
    /// Staged hand-over: how far the mid / high bands duck at full cut.
    static let midCutDB: Float = -18
    /// Live stand-in for a stem-level vocal duck until S3's pre-render path
    /// exists: how far the outgoing mid band drops when the plan carries a
    /// stem technique.
    static let stemApproxDuckDB: Float = -7
    static let highCutDB: Float = -24
    /// `.filterSweep` end points; the sweep is logarithmic between them.
    static let sweepStartHz: Float = 20
    static let sweepEndHz: Float = 1200
    /// `.echoOut` delay settings once the outgoing deck hits its stop point.
    static let echoWetMix: Float = 70
    static let echoFeedback: Float = 50
    static let echoDefaultDelayTime: TimeInterval = 0.25
    /// How fast the outgoing deck is cut once the echo is thrown.
    static let echoCutDuration: TimeInterval = 0.2
    /// `.echoOut` cuts the source with the EQ's global gain rather than the
    /// deck fader — the fader sits at the mixer input, *after* the delay, so
    /// using it would mute the tail along with the track.
    static let echoCutGainDB: Float = -60
    /// How long the tail is allowed to ring after the overlap ends.
    static let echoTailDuration: TimeInterval = 1.4
    /// How long a beat-matched incoming deck takes to ramp back to rate 1.0.
    static let rateRestoreDuration: TimeInterval = 1.5

    /// How fast a transition gain ride (`PlannedTransition.rideDB`) is let go
    /// of once the overlap is over, in dB per second.
    ///
    /// This is the "and then push it back up" half of the DJ's gesture, and it
    /// only works if nobody notices it happening. 0.3 dB/s is an order of
    /// magnitude under the ~1 dB just-noticeable step and slow enough that the
    /// change never presents itself as an *event*: the full ±4 dB ride takes
    /// just over 13 s to unwind, so the new track arrives at its own level
    /// somewhere in its first verse without a single audible move.
    ///
    /// It is deliberately far longer than the `.echoOut` tail or the rate
    /// restore, which is why the ride is **not** part of the settling phase —
    /// the transition state machine must be free to finish and clear while the
    /// release is still running. The engine carries it on the deck instead.
    static let rideReleaseDBPerSecond: Double = 0.3

    /// The ride level, in dB, `elapsed` seconds after the overlap ended.
    /// A linear-in-dB release to 0, which is a constant-slope fader move —
    /// the shape a hand on a trim knob makes.
    static func rideDB(_ ride: Double, secondsAfterOverlap elapsed: TimeInterval) -> Double {
        guard ride != 0, ride.isFinite else { return 0 }
        let released = rideReleaseDBPerSecond * Swift.max(0, elapsed)
        return ride > 0 ? Swift.max(0, ride - released) : Swift.min(0, ride + released)
    }

    /// How long `ride` takes to unwind to unity.
    static func rideReleaseDuration(_ ride: Double) -> TimeInterval {
        guard ride.isFinite else { return 0 }
        return abs(ride) / rideReleaseDBPerSecond
    }

    // MARK: - Output

    /// Every automated parameter of one deck's chain, at one instant.
    /// Defaults are the neutral (transparent) pose.
    struct DeckParameters: Equatable, Sendable {
        var fader: Float = 1
        var rate: Float = 1
        var eqGlobalGain: Float = 0
        var lowGain: Float = 0
        var midGain: Float = 0
        var highGain: Float = 0
        var highPassBypassed: Bool = true
        var highPassFrequency: Float = TransitionAutomation.sweepStartHz
        var delayWetDryMix: Float = 0
        var delayFeedback: Float = 0
        var delayTime: TimeInterval = TransitionAutomation.echoDefaultDelayTime
    }

    /// One tick of the overlap.
    struct Frame: Equatable, Sendable {
        var outgoing = DeckParameters()
        var incoming = DeckParameters()
        /// 0…1 across the overlap.
        var progress: Float = 0
        /// `.echoOut` has passed its stop point (the delay is thrown and the
        /// source is being cut).
        var echoThrown = false
        /// The audible hand-over point has been reached — where the low end
        /// changes decks, and where `PlayerService` swaps the current track.
        var midpointReached = false
        /// The overlap is over; the caller should finish the hand-over.
        var isComplete = false
    }

    // MARK: - Geometry

    /// The timing landmarks a plan implies. Pure geometry, no styling: the
    /// engine's `TransitionState` reads its offsets from here, so the real-time
    /// and offline paths cannot disagree about where the swap happens.
    struct Geometry: Equatable, Sendable {
        /// Never zero, so ramps can always divide by it.
        let overlapDuration: TimeInterval
        /// Seconds into the overlap where the low end changes decks.
        let swapOffset: TimeInterval
        /// `.echoOut`: where the outgoing track slams shut. Deliberately
        /// inside the overlap (a clash-grade crossfade is only ~2.5 s, so
        /// "after the overlap" would never sound), leaving room for the tail.
        let echoStopOffset: TimeInterval
        /// Beat period of the outgoing track when the plan implies one
        /// (bars × 4 beats over the overlap); nil for a plain crossfade.
        let outgoingBeatDuration: TimeInterval?

        init(plan: TransitionPlan) {
            switch plan {
            case .beatMatched(let p):
                let duration = max(p.overlapDuration, 0.1)
                overlapDuration = duration
                let swap = min(max(p.bassSwapOffset, duration * 0.2), duration * 0.9)
                swapOffset = swap
                echoStopOffset = min(max(swap, duration * 0.4), duration * 0.8)
                if p.overlapBars > 0 {
                    let beat = p.overlapDuration / Double(p.overlapBars * 4)
                    outgoingBeatDuration = (beat > 0.05 && beat < 4) ? beat : nil
                } else {
                    outgoingBeatDuration = nil
                }
            case .crossfade(let duration, _, _):
                let d = max(duration, 0.1)
                overlapDuration = d
                swapOffset = d * 0.5
                echoStopOffset = d * 0.65
                outgoingBeatDuration = nil
            case .gapless:
                overlapDuration = 0
                swapOffset = 0
                echoStopOffset = 0
                outgoingBeatDuration = nil
            }
        }
    }

    // MARK: - The curves

    /// 0→1 across [start, end], smoothstepped so per-tick parameter moves are
    /// continuous in slope as well as value (no audible steps at the edges).
    static func ramp(_ t: TimeInterval, from start: TimeInterval,
                     to end: TimeInterval) -> Float {
        guard end > start else { return t >= end ? 1 : 0 }
        let x = Float(min(1, max(0, (t - start) / (end - start))))
        return x * x * (3 - 2 * x)
    }

    /// The whole automation for one instant of an overlap.
    static func frame(plan: TransitionPlan, style: TransitionStyle,
                      elapsed: TimeInterval) -> Frame {
        frame(plan: plan, style: style, elapsed: elapsed, geometry: Geometry(plan: plan))
    }

    /// Geometry-injecting overload, so a caller stepping a whole transition
    /// does not recompute the landmarks 50 times a second.
    static func frame(plan: TransitionPlan, style: TransitionStyle,
                      elapsed: TimeInterval, geometry: Geometry) -> Frame {
        var f = Frame()
        guard case .gapless = plan else {
            let duration = geometry.overlapDuration
            let t = elapsed
            let progress = Float(min(1, t / duration))
            f.progress = progress

            // Incoming fader: equal-power rise, identical for every style.
            f.incoming.fader = sin(progress * .pi / 2)

            // Outgoing fader: how the track leaves is the style's whole point.
            switch style.outroEffect {
            case .fade:
                // Equal-power fade (mixer volume stays the user's).
                f.outgoing.fader = cos(progress * .pi / 2)
            case .filterSweep:
                // The sweep carries the exit, so the level is held high early
                // and only collapses late: cos over a >1 exponent of progress.
                f.outgoing.fader = cos(pow(progress, 1.8) * .pi / 2)
                // Logarithmic 20 Hz → 1.2 kHz: constant perceived sweep speed.
                f.outgoing.highPassBypassed = false
                f.outgoing.highPassFrequency =
                    sweepStartHz * pow(sweepEndHz / sweepStartHz, progress)
            case .echoOut:
                applyEchoOut(&f, style: style, geometry: geometry, elapsed: t)
            }

            applyEQHandover(&f, plan: plan, style: style, geometry: geometry, elapsed: t)

            // Live approximation of the vocal-facing stem techniques: the
            // engine has no stem playback path yet (that is S3's pre-render
            // job), so a plan that asked for one gets a mid-band duck on the
            // outgoing deck — the 900 Hz parametric band carries most vocal
            // presence. Crude next to a real separated duck, but audibly the
            // right direction, and it only engages when the planner explicitly
            // chose a stem technique.
            if style.stemTechnique != nil {
                let edge = Float(min(1, t / 0.5))
                f.outgoing.midGain = min(f.outgoing.midGain,
                                         Self.stemApproxDuckDB * edge)
            }

            f.midpointReached = progress >= 0.5
            if case .beatMatched(let p) = plan {
                f.incoming.rate = p.incomingRate
                // Ease the outgoing deck onto its matched rate over the first
                // quarter of the overlap (capped at 1 s).
                let rampIn = min(1.0, duration * 0.25)
                if t < rampIn {
                    f.outgoing.rate = 1 + (p.outgoingRate - 1) * Float(t / rampIn)
                } else {
                    f.outgoing.rate = p.outgoingRate
                }
                f.midpointReached = t >= (style.stagedEQ
                                          ? geometry.swapOffset
                                          : min(max(p.bassSwapOffset, 0.8), duration))
            }
            f.isComplete = progress >= 1
            return f
        }
        // `.gapless` has no overlap to automate: both decks stay transparent.
        f.midpointReached = true
        f.isComplete = true
        return f
    }

    /// `.echoOut`: hold the outgoing track up to its stop point, throw the
    /// delay there, then slam the source shut in ~200 ms so what is left is the
    /// (already captured) tail ringing itself out.
    private static func applyEchoOut(_ f: inout Frame, style: TransitionStyle,
                                     geometry: Geometry, elapsed t: TimeInterval) {
        let stopAt = geometry.echoStopOffset
        guard t >= stopAt else {
            // A gentle duck only — the exit is the stop, not a fade.
            f.outgoing.fader = 1 - 0.25 * ramp(t, from: 0, to: stopAt)
            return
        }
        f.echoThrown = true
        f.outgoing.delayTime = echoDelayTime(style: style, geometry: geometry)
        f.outgoing.delayFeedback = echoFeedback
        f.outgoing.delayWetDryMix = echoWetMix
        // Cut what feeds the delay, not the deck's output: the fader is applied
        // at the mixer input, downstream of the delay, so pulling it down would
        // silence the very tail this style exists for.
        f.outgoing.fader = 0.75
        f.outgoing.eqGlobalGain =
            echoCutGainDB * ramp(t, from: stopAt, to: stopAt + echoCutDuration)
    }

    /// Planner hint first, then beat-synced 3/8 when the plan implies a grid,
    /// else a plain 250 ms.
    static func echoDelayTime(style: TransitionStyle, geometry: Geometry) -> TimeInterval {
        style.echoDelayTime.map { min(max($0, 0.05), 2.0) }
            ?? geometry.outgoingBeatDuration.map { min(max($0 * 0.75, 0.05), 2.0) }
            ?? echoDefaultDelayTime
    }

    /// The EQ side of the hand-over.
    ///
    /// `stagedEQ` splits it into three stages around the swap point S: the
    /// outgoing track loses its highs first, then its mids, and keeps the low
    /// end until S; the incoming track is the mirror image, taking the lows
    /// over at S. Without it, the legacy single low-shelf bass swap runs
    /// (beat-matched plans only) — byte-for-byte the pre-styles behaviour, so
    /// `.plain` sounds exactly as it did.
    private static func applyEQHandover(_ f: inout Frame, plan: TransitionPlan,
                                        style: TransitionStyle, geometry: Geometry,
                                        elapsed t: TimeInterval) {
        let duration = geometry.overlapDuration
        let swapAt = geometry.swapOffset

        guard style.stagedEQ else {
            guard case .beatMatched(let p) = plan else { return }
            // Bass swap around plan.bassSwapOffset: the outgoing low shelf
            // ducks out just before it, the incoming one recovers just after.
            let swapRamp = 0.8
            let legacySwapAt = min(max(p.bassSwapOffset, swapRamp), duration)
            let outP = Float(min(1, max(0, (t - (legacySwapAt - swapRamp)) / swapRamp)))
            f.outgoing.lowGain = bassCutDB * outP
            let inP = Float(min(1, max(0, (t - legacySwapAt) / swapRamp)))
            f.incoming.lowGain = bassCutDB * (1 - inP)
            return
        }

        // Stage windows, expressed relative to the swap so they always fit
        // inside the overlap however short it is.
        let highStageEnd = swapAt * 0.45
        let midStageStart = swapAt * 0.35
        let midStageEnd = swapAt * 0.85
        let swapRamp = min(0.4, max(0.1, swapAt * 0.2))

        let highP = ramp(t, from: 0, to: highStageEnd)
        let midP = ramp(t, from: midStageStart, to: midStageEnd)
        let lowOutP = ramp(t, from: swapAt - swapRamp, to: swapAt)
        let lowInP = ramp(t, from: swapAt, to: swapAt + swapRamp)

        f.outgoing.highGain = highCutDB * highP
        f.outgoing.midGain = midCutDB * midP
        f.outgoing.lowGain = bassCutDB * lowOutP

        f.incoming.highGain = highCutDB * (1 - highP)
        f.incoming.midGain = midCutDB * (1 - midP)
        f.incoming.lowGain = bassCutDB * (1 - lowInP)
    }

    // MARK: - Settling

    /// What the post-overlap phase does: ramp a beat-matched rate back to 1.0
    /// on the incoming deck and decay an `.echoOut` tail on the outgoing one.
    struct SettleFrame: Equatable, Sendable {
        var incomingRate: Float = 1
        var outgoingDelayWetDryMix: Float = 0
        var outgoingDelayFeedback: Float = 0
        var rateRestoreDone = true
        var echoTailDone = true

        var isDone: Bool { rateRestoreDone && echoTailDone }
    }

    static func settleFrame(plan: TransitionPlan, restoringRate: Bool,
                            echoTailRinging: Bool, elapsed: TimeInterval) -> SettleFrame {
        var s = SettleFrame()
        if restoringRate, case .beatMatched(let p) = plan {
            let progress = Float(min(1, elapsed / rateRestoreDuration))
            s.incomingRate = p.incomingRate + (1 - p.incomingRate) * progress
            if progress >= 1 {
                s.incomingRate = 1
            } else {
                s.rateRestoreDone = false
            }
        }
        if echoTailRinging {
            let progress = Float(min(1, elapsed / echoTailDuration))
            // Wet level down alongside the delay's own feedback decay, so the
            // tail dies out instead of being chopped.
            s.outgoingDelayWetDryMix = echoWetMix * (1 - progress)
            s.outgoingDelayFeedback = echoFeedback * (1 - progress)
            if progress < 1 { s.echoTailDone = false }
        }
        return s
    }
}
