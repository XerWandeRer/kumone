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
    /// How long a beat-matched incoming deck takes to ramp back to rate 1.0
    /// when the plan carries no `rampReleaseSeconds` of its own.
    static let rateRestoreDuration: TimeInterval = 1.5

    /// How much audio a pre-rendered `TransitionSegment` duplicates at each end
    /// so the swap between deck and segment can be an identity crossfade.
    ///
    /// It lives here, next to the curves, rather than in the renderer that
    /// spends it, because the *tempo ramp* is defined against it: the glide
    /// has to be finished this far before the out point, or the deck and the
    /// (constant-rate) segment head would be playing the same source at two
    /// different speeds and the identity crossfade would comb-filter instead of
    /// cancelling. `TransitionSegmentRenderer.handoff` is this number.
    static let segmentHandoff: TimeInterval = 0.5

    // MARK: - Tempo ramp

    /// The outgoing deck's pre-seam tempo glide, as pure geometry.
    ///
    /// **Why it is a function of the outgoing track's source position, not of
    /// wall time.** Everything that has to agree about this curve — the engine's
    /// wait tick, the offline renderer's pre-roll, the segment head invariant —
    /// knows where the outgoing deck is *in its own song*; only one of them
    /// (the engine) also has a wall clock, and that clock is exactly what the
    /// glide is bending. Anchoring on source position makes the curve
    /// pause-proof, seek-proof and tick-jitter-proof for free: a deck that
    /// resumes at position s resumes at rate r(s), whatever happened in
    /// between. It also keeps the seam itself exact — the overlap fires when
    /// the outgoing deck's *source* position reaches `outPoint`, a downbeat in
    /// its own timeline, which no amount of bending before it can move.
    ///
    /// The wall-clock consequence is then a consequence, not an input: with
    /// ds/dt = r(s) the deck takes ∫ ds/r(s) seconds to cross the ramp, which
    /// is closed-form for a linear r (see `wallSeconds(from:to:)`).
    struct TempoRamp: Equatable, Sendable {
        /// Outgoing source position where the glide leaves 1.0…
        let start: TimeInterval
        /// …and where it arrives at `target`, one `segmentHandoff` before the
        /// out point. From here to the seam the deck is at a constant bent
        /// rate, which is what a pre-rendered segment's head is rendered at.
        let end: TimeInterval
        let target: Float

        var leadSeconds: TimeInterval { end - start }

        /// Rate at outgoing source position `s`.
        ///
        /// Linear in the rate, not smoothstepped, and deliberately: what a
        /// listener detects is the *rate of rate change* (a glide at constant
        /// slope reads as one steady drift and disappears into the music,
        /// while a smoothstep's mid-curve slope is 1.5× the mean and its ends
        /// are flat — the same total bend with a worse worst case). Linear
        /// also makes the position↔time map closed-form, which is what lets
        /// the offline renderer land on the out point exactly.
        func rate(at s: TimeInterval) -> Float {
            guard end > start else { return s >= end ? target : 1 }
            let u = Float(Swift.min(1, Swift.max(0, (s - start) / (end - start))))
            return 1 + (target - 1) * u
        }

        /// The worst-case slope of the glide, in fraction-of-rate per **wall**
        /// second — the number the lead is chosen against. |target − 1| / lead,
        /// times r for the wall/source conversion, which is within 6 % of 1.
        var slopePerSecond: Double {
            guard leadSeconds > 0 else { return .infinity }
            return abs(Double(target) - 1) / leadSeconds
        }

        /// Wall seconds the outgoing deck spends crossing source `[a, b]`.
        ///
        /// ∫ ds / r(s), split into the flat run-in (r = 1), the glide, and the
        /// flat run-out (r = target). Over the glide r is linear in s, so
        /// ∫ ds/r = lead · ln(target) / (target − 1).
        func wallSeconds(from a: TimeInterval, to b: TimeInterval) -> TimeInterval {
            guard b > a else { return 0 }
            let t = Double(target)
            var total = Swift.max(0, Swift.min(b, start) - Swift.min(a, start))
            let rampA = Swift.min(Swift.max(a, start), end)
            let rampB = Swift.min(Swift.max(b, start), end)
            if rampB > rampA, leadSeconds > 0 {
                // Antiderivative of 1/(1 + (t−1)·(s−start)/lead).
                let k = (t - 1) / leadSeconds
                if abs(k) < 1e-12 {
                    total += rampB - rampA
                } else {
                    total += (log(1 + k * (rampB - start)) - log(1 + k * (rampA - start))) / k
                }
            }
            total += Swift.max(0, b - Swift.max(a, end)) / t
            return total
        }
    }

    /// The tempo ramp a plan implies, or nil when it implies none — a plan made
    /// with `tempoRampEnabled` off, a crossfade, or a beat-match whose outgoing
    /// deck is not bent at all. Nil is the pre-ramp behaviour everywhere.
    static func tempoRamp(for plan: TransitionPlan) -> TempoRamp? {
        guard case .beatMatched(let p) = plan,
              p.rampLeadSeconds > 0,
              abs(p.outgoingRate - 1) > 0.0005
        else { return nil }
        let end = p.outPoint - segmentHandoff
        return TempoRamp(start: end - p.rampLeadSeconds, end: end, target: p.outgoingRate)
    }

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

    /// How fast the bent-rate headroom pad
    /// (`LoudnessCompensation.timePitchPadDB`) is glided on, in dB per second.
    ///
    /// The same number as the ride's release and for the same reason — it is
    /// the rate at which a level change stops presenting itself as an event —
    /// but it buys something different: the pad has to be **completely in
    /// before the deck's rate leaves unity**, because the time-pitch overshoot
    /// does not scale with the bend. A pad that faded in alongside the glide
    /// would be covering a third of the overshoot for the first half of it.
    /// So the pad gets its own lead-in *ahead* of the tempo ramp, and this is
    /// what sets its length: |pad| / 0.3 dB/s, about 10 s at the deepest pad
    /// the caps allow.
    static let ratePadGlideDBPerSecond: Double = 0.3

    /// Seconds of unbent lead-in a deck needs to have `padDB` fully glided on
    /// by the time its tempo ramp starts.
    static func ratePadLeadSeconds(_ padDB: Double) -> TimeInterval {
        guard padDB.isFinite, padDB != 0 else { return 0 }
        return abs(padDB) / ratePadGlideDBPerSecond
    }

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
    ///
    /// `approximateStems` is the live engine's stand-in for a stem technique
    /// it cannot perform (see below). Pass false when the deck really is being
    /// fed separated stems — a pre-rendered segment, or an audition render with
    /// a separator wired up — or the duck lands *on top of* the technique it
    /// was only ever meant to imitate.
    static func frame(plan: TransitionPlan, style: TransitionStyle,
                      elapsed: TimeInterval, geometry: Geometry,
                      approximateStems: Bool = true) -> Frame {
        var f = Frame()
        guard case .gapless = plan else {
            let duration = geometry.overlapDuration
            let t = elapsed
            let progress = Float(min(1, t / duration))
            f.progress = progress

            // Incoming fader: equal-power rise, identical for every style.
            f.incoming.fader = sin(progress * .pi / 2)

            // …unless this is a staged beat-matched blend asking for the
            // dominant-deck law, where both faders are rewritten together.
            let dominant = dominantDeckFaders(plan: plan, style: style,
                                              geometry: geometry, elapsed: t)
            if let dominant { f.incoming.fader = dominant.incoming }

            // Outgoing fader: how the track leaves is the style's whole point.
            switch style.outroEffect {
            case .fade:
                // Equal-power fade (mixer volume stays the user's).
                f.outgoing.fader = dominant?.outgoing ?? cos(progress * .pi / 2)
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

            // Live approximation of the vocal-facing stem techniques, for the
            // hand-overs that get no separated audio: a mid-band duck on the
            // outgoing deck, the 900 Hz parametric band carrying most vocal
            // presence. Crude next to a real separated duck, but audibly the
            // right direction. It engages only when the planner explicitly
            // chose a stem technique *and* nothing is going to perform it —
            // no separator installed, or the pre-render did not finish in time.
            if style.stemTechnique != nil, approximateStems {
                let edge = Float(min(1, t / 0.5))
                f.outgoing.midGain = min(f.outgoing.midGain,
                                         Self.stemApproxDuckDB * edge)
            }

            f.midpointReached = progress >= 0.5
            if case .beatMatched(let p) = plan {
                f.incoming.rate = p.incomingRate
                if p.rampLeadSeconds > 0 {
                    // The pre-seam glide already landed the deck on its matched
                    // rate a `segmentHandoff` before the out point, so the whole
                    // overlap is flat. This is not just tidiness: the in-overlap
                    // ease below runs the outgoing deck at the *wrong* tempo for
                    // its first second, which is a beat-phase error of a few
                    // milliseconds right where the two grids are supposed to be
                    // locked. The ramp removes it.
                    f.outgoing.rate = p.outgoingRate
                } else {
                    // Ease the outgoing deck onto its matched rate over the first
                    // quarter of the overlap (capped at 1 s).
                    let rampIn = min(1.0, duration * 0.25)
                    if t < rampIn {
                        f.outgoing.rate = 1 + (p.outgoingRate - 1) * Float(t / rampIn)
                    } else {
                        f.outgoing.rate = p.outgoingRate
                    }
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

    // MARK: - Dominant-deck fader law

    /// How far the outgoing deck is allowed to dip before the swap, as a fader
    /// level — a courtesy step back as the incoming track establishes itself,
    /// not a fade. 0.94 is −0.5 dB: under the ~1 dB just-noticeable step, so it
    /// reads as "the mix made room" rather than as the outgoing track leaving.
    static let dominantCourtesyLevel: Float = 0.94
    /// What share of the run-up to the swap the incoming deck spends climbing
    /// to its plateau. The rest of that run-up is spent *at* the plateau,
    /// sitting under the outgoing deck — which is the whole point: the new
    /// track has to be established, and audibly present, before it is handed
    /// the floor, or the swap sounds like a cut rather than a hand-over.
    static let dominantRiseShare: Float = 0.3

    /// The two faders of a staged beat-matched blend, or nil when this plan and
    /// style are not asking for the dominant-deck law (every other hand-over —
    /// plain crossfade, filter sweep, echo out, and the legacy non-staged
    /// beat-match — is left exactly as it was).
    ///
    /// ### The problem it fixes
    ///
    /// The symmetric law runs both faders as equal-power curves across the
    /// *whole* overlap while the staged EQ simultaneously carves the two decks
    /// into complementary halves of the spectrum. Over a 30 s blend that means
    /// that at the swap both decks sit at −3 dB *and* each holds only part of
    /// the spectrum, so for several seconds either side of the middle nobody
    /// owns the floor and the mix audibly collapses — strong, weak, strong.
    /// Two half-spectra at −3 dB do not add back up to one track.
    ///
    /// ### The law
    ///
    /// What a DJ does instead is keep exactly one deck dominant at all times:
    ///
    ///   - **outgoing** holds full level (bar the courtesy dip) all the way to
    ///     the swap, then leaves over what is left of the overlap;
    ///   - **incoming** climbs quickly to `preSwapPlateau` and *waits* there,
    ///     underneath — low-cut by the staged EQ, so it adds presence without
    ///     mud — reaching unity exactly at the swap, where the EQ hands it the
    ///     low end and it becomes the dominant deck.
    ///
    /// Both curves are smoothstepped and meet their pieces at equal values, so
    /// the result is continuous in value *and* slope: the engine writes these
    /// at 50 Hz and any step is a click.
    ///
    /// ### Headroom
    ///
    /// Both decks are near full around the swap, which is the one thing this
    /// law could plausibly break. It does not, because the staged EQ is doing
    /// the opposite thing at the same time: by the swap the outgoing deck is
    /// down −24/−18/−24 across all three bands, so its contribution to the sum
    /// is small exactly where its fader is highest, and before that the two
    /// decks hold complementary bands. Measured on the offline renders of two
    /// real seams at the shipped trims and ride, sample peak across swap ± 2 s
    /// on the player path (i.e. with the audition renderer's blind-test
    /// normalization undone):
    ///
    /// | seam | symmetric | dominant | margin |
    /// |---|---|---|---|
    /// | Kendrick "LOVE." → "Pray For Me" | −5.49 dBFS | −3.37 dBFS | 3.37 dB |
    /// | Kelela "Happy Ending" → "On the Run" | −5.91 dBFS | −4.23 dBFS | 4.23 dB |
    ///
    /// The law costs about 2 dB of peak, which is the point — it is 2 dB the
    /// old curve was throwing away in the middle — and lands three to four dB
    /// clear of full scale, so the plateau stays at 0.85.
    static func dominantDeckFaders(
        plan: TransitionPlan, style: TransitionStyle,
        geometry: Geometry, elapsed t: TimeInterval
    ) -> (outgoing: Float, incoming: Float)? {
        guard style.dominantDeck, style.stagedEQ, case .beatMatched = plan else { return nil }
        let duration = geometry.overlapDuration
        // The swap has to leave room on both sides for either half to be a
        // curve rather than a jump; a degenerate geometry falls back.
        let swapAt = geometry.swapOffset
        guard swapAt > 0.05, duration - swapAt > 0.05 else { return nil }

        let plateau = Swift.min(1, Swift.max(0, style.preSwapPlateau))
        let riseEnd = swapAt * TimeInterval(Swift.min(0.9, Swift.max(0.05, dominantRiseShare)))

        let incoming: Float
        if t < riseEnd {
            incoming = plateau * ramp(t, from: 0, to: riseEnd)
        } else {
            // Plateau → unity over the wait, arriving at 1.0 exactly at the
            // swap. Smoothstep on both sides of `riseEnd` means the join has
            // zero slope from either direction, so the plateau really is flat.
            incoming = plateau + (1 - plateau) * ramp(t, from: riseEnd, to: swapAt)
        }

        let outgoing: Float
        if t < swapAt {
            // Full level, less the courtesy dip, taken over the same window
            // the incoming deck climbs in — the two moves are one gesture.
            outgoing = 1 - (1 - dominantCourtesyLevel) * ramp(t, from: 0, to: riseEnd)
        } else {
            // The equal-power exit, compressed into what remains of the
            // overlap. Starts at exactly the courtesy level the branch above
            // ends on, and reaches 0 at the end of the overlap.
            let u = Float((t - swapAt) / (duration - swapAt))
            outgoing = dominantCourtesyLevel * cos(Swift.min(1, Swift.max(0, u)) * .pi / 2)
        }
        return (outgoing, Swift.min(1, incoming))
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

    /// How long the incoming deck's rate release takes. The plan's own
    /// `rampReleaseSeconds` when it has one — the release is the back half of
    /// the ramp gesture and is let go of at the same unhurried pace the ride
    /// is — and the legacy 1.5 s otherwise, which is every plan made with the
    /// ramp off.
    static func rateReleaseDuration(_ plan: TransitionPlan) -> TimeInterval {
        guard case .beatMatched(let p) = plan, p.rampReleaseSeconds > 0 else {
            return rateRestoreDuration
        }
        return p.rampReleaseSeconds
    }

    static func settleFrame(plan: TransitionPlan, restoringRate: Bool,
                            echoTailRinging: Bool, elapsed: TimeInterval) -> SettleFrame {
        var s = SettleFrame()
        if restoringRate, case .beatMatched(let p) = plan {
            let progress = Float(min(1, elapsed / rateReleaseDuration(plan)))
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
