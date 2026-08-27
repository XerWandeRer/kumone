import Foundation

// Pure decision function: two analyses in, one TransitionPlan out (spec §5).
// Rules are checked top-down; the first hit wins:
//   1. Both analyzed, both confident, BPM delta (after double/half-time
//      folding) ≤ 8% → beatMatched.
//   2. Both analyzed but not beat-matchable → crossfade.
//   3. Anything missing, or either track shorter than 45 s → gapless.
enum TransitionPlanner {
    // Compatibility gate: how different two adjacent tracks are decides how
    // aggressive the transition is allowed to be. Very different songs
    // (ballad → banger, folk → electronic) get their boundary respected
    // with a short fade instead of a long blend.
    enum CompatibilityTier {
        case compatible   // full AutoMix: beat-match / long computed fades
        case neutral      // quick hand-over, no forced blending
        case clash        // boundary-respecting short fade
    }

    /// Every tunable the decision turns on, in one value. `Config.standard`
    /// holds the shipped numbers and is the default everywhere, so the
    /// product path behaves exactly as it did when these were bare
    /// constants; `audition serve` swaps in a modified copy to explore what
    /// a different calibration would have decided.
    struct Config: Sendable, Equatable {
        var minTrackDuration: TimeInterval = 45
        var bpmConfidenceThreshold: Double = 0.6
        var maxBPMDeltaRatio: Double = 0.08
        var maxRateDeviation: Double = 0.04
        /// Coefficient of variation below which an RMS slice counts as steady.
        /// Deliberately loose: longer 8-bar overlaps are preferred whenever the
        /// energy is anywhere near stable.
        var stableCV: Double = 0.3
        /// Hard bounds on any overlap. Between them the length is computed from
        /// the audio: how long the outgoing tail stays steady, and how long the
        /// incoming opening can sit under a fade (see tailCapacity /
        /// intakeCapacity) — never a fixed number.
        var maxOverlap: TimeInterval = 30
        var minOverlap: TimeInterval = 2
        /// An overlap also never eats more than this share of the shorter track.
        var maxOverlapShare: Double = 0.25
        /// Looser steadiness bar for the tail search than for 8/16-bar upgrades.
        var tailStableCV: Double = 0.35

        /// Loudness gap (dB) between the outgoing tail and the incoming opening.
        var neutralLoudnessDB: Double = 3.0
        var clashLoudnessDB: Double = 6.5
        /// Cosine distance between the tracks' timbre fingerprints
        /// (level-removed log-mel shape, so the distance is one minus a shape
        /// correlation).
        ///
        /// Calibrated on the audition corpus (16 tracks, all 120 pairs). The
        /// natural unit of "definitely compatible" is a track measured against
        /// its own other half: median 0.028, worst case 0.11. Two different
        /// tracks sit at a median of 0.24 and reach 0.88. The neutral line is
        /// set above every same-song distance, so an arrangement change inside
        /// one track can never trip it; the clash line only catches the
        /// corpus's top decile — a modern bass-forward master against a thin,
        /// bass-light old recording. On the 15 adjacent pairs that leaves 5
        /// above the neutral line and 1 above the clash line. (The old
        /// fingerprint put all 15 between 0.001 and 0.032: this gate had never
        /// once fired.)
        var neutralTimbreDistance: Double = 0.25
        var clashTimbreDistance: Double = 0.45
        /// Folded BPM ratio beyond which confident tempos count as clashing.
        var clashTempoRatio: Double = 0.2
        /// Overlap ceilings for the two degraded tiers.
        var neutralOverlapCap: TimeInterval = 6
        var clashOverlapCap: TimeInterval = 2.5

        /// Key gate: below this confidence a detected key never influences
        /// decisions. At `clashKeyDistance` fifths or more apart (minors folded
        /// to their relative major), harmony alone demotes compatible →
        /// neutral — it denies the long blend but never forces the clash tier
        /// by itself.
        var keyConfidenceThreshold: Double = 0.5
        var clashKeyDistance: Int = 3

        /// Vocal gate: overlap windows are scored relative to the track's own
        /// mean vocal activity (absolute levels drift with genre/mastering).
        /// Vocals on both sides at once — the one thing a DJ never lets
        /// happen — shortens the fade and blocks long beat-matched overlaps.
        var vocalClashRatio: Double = 1.1
        var vocalClashFadeCap: TimeInterval = 4

        // --- Shape parameters: less about *which* transition and more about
        // where it lands and how it sounds. Same story: constants promoted
        // to fields so the tuning surface can reach them.

        /// Overlap length at or above which a compatible crossfade earns the
        /// staged-EQ hand-over.
        var stagedEQMinOverlap: TimeInterval = 8
        /// Echo-out delay: a dotted eighth of the outgoing tempo, clamped.
        var echoBeatFraction: Double = 0.75
        var echoDelayMin: TimeInterval = 0.15
        var echoDelayMax: TimeInterval = 1.0
        /// Window (seconds of 1 s RMS) each side contributes to the loudness gap.
        var loudnessWindow: Int = 15
        /// Out-point search window for beat-matched plans: candidates must sit
        /// past `max(duration * tailWindowShare, outLimit - tailWindowSeconds)`.
        var tailWindowSeconds: TimeInterval = 60
        var tailWindowShare: Double = 0.5
        /// Crossfade out-point candidates must sit past this share of the track.
        var crossfadeOutPointShare: Double = 0.6
        /// Incoming intake capacity: seconds until the opening reaches this
        /// share of the track's peak, plus this much body.
        var intakePeakShare: Double = 0.7
        var intakeBodySeconds: TimeInterval = 8
        /// Fade length used when the outgoing tail never settles.
        var tailCapacityFallback: TimeInterval = 4

        // --- Stem layer. Read *only* when the caller passes
        // `StemAvailability.ready`; at `.none` — every product path today —
        // not one of these numbers is looked at, which is what makes the
        // stem work provably additive.

        /// How vocal-active the outgoing window has to be, relative to that
        /// track's own mean, before a stem technique is worth asking for.
        ///
        /// Calibrated on the audition corpus: sliding 8 s windows put the
        /// median at 1.00 and the 95th percentile between 1.16 and 1.58 per
        /// track (`vocalActivity` is level-normalized, so its dynamic range is
        /// narrow). 1.15 sits around each track's own 85th percentile — a
        /// window that is *noticeably* more sung than the song's average — and
        /// deliberately above `vocalClashRatio`, so anything the stem layer
        /// calls "vocal-active" is by definition also on the clash side of the
        /// two-lead-vocals rule.
        var stemVocalActiveRatio: Double = 1.15
        /// `acapellaOver` additionally needs the incoming opening to be
        /// instrumental-leaning: at or below this share of its own mean vocal
        /// density. Floating one track's vocal over another's is only a
        /// technique when the other one is not singing; at the corpus's median
        /// intake of ~1.0 it would just be the two-vocal pile-up the ducking
        /// rule exists to prevent.
        var stemAcapellaIncomingVocalMax: Double = 0.90
        /// No stem technique on an overlap shorter than this: the curves in
        /// `StemTechniqueLayer` (an accompaniment drop by 28 %, a vocal
        /// retired by 96 %) need room, and a separation pass is far too
        /// expensive to spend on a two-second clash-tier hand-over.
        var stemMinOverlap: TimeInterval = 5
        /// How far `vocalDuck` holds the outgoing vocal down, in dB of
        /// attenuation (S1's blind test liked 9).
        var stemDuckDepthDB: Double = 9

        static let standard = Config()
    }

    // The shipped numbers, kept as the flat names the rest of the codebase and
    // the tests already read. Every one is `Config.standard`'s field, so there
    // is exactly one source of truth.
    static let minTrackDuration = Config.standard.minTrackDuration
    static let bpmConfidenceThreshold = Config.standard.bpmConfidenceThreshold
    static let maxBPMDeltaRatio = Config.standard.maxBPMDeltaRatio
    static let maxRateDeviation = Config.standard.maxRateDeviation
    static let stableCV = Config.standard.stableCV
    static let maxOverlap = Config.standard.maxOverlap
    static let minOverlap = Config.standard.minOverlap
    static let maxOverlapShare = Config.standard.maxOverlapShare
    static let tailStableCV = Config.standard.tailStableCV
    static let neutralLoudnessDB = Config.standard.neutralLoudnessDB
    static let clashLoudnessDB = Config.standard.clashLoudnessDB
    static let neutralTimbreDistance = Config.standard.neutralTimbreDistance
    static let clashTimbreDistance = Config.standard.clashTimbreDistance
    static let clashTempoRatio = Config.standard.clashTempoRatio
    static let neutralOverlapCap = Config.standard.neutralOverlapCap
    static let clashOverlapCap = Config.standard.clashOverlapCap
    static let keyConfidenceThreshold = Config.standard.keyConfidenceThreshold
    static let clashKeyDistance = Config.standard.clashKeyDistance
    static let vocalClashRatio = Config.standard.vocalClashRatio
    static let vocalClashFadeCap = Config.standard.vocalClashFadeCap

    /// - Parameter stems: whether a vocal/accompaniment separator is available
    ///   for this hand-over. At `.none` — the default, and what every product
    ///   path passes — the result is field-for-field what it was before the
    ///   stem layer existed; `.ready` lets the two rules in "Stem layer" below
    ///   re-aim the out point and add a `StemTechnique`.
    static func plan(
        outgoing: TrackAnalysis?, incoming: TrackAnalysis?,
        stems: StemAvailability = .none,
        config: Config = .standard
    ) -> PlannedTransition {
        guard let outgoing, let incoming,
              outgoing.duration >= config.minTrackDuration,
              incoming.duration >= config.minTrackDuration
        else { return .plain(.gapless) }

        var tier = compatibility(outgoing: outgoing, incoming: incoming, config: config)
        if tier == .compatible, keysClash(outgoing, incoming, config) { tier = .neutral }
        if tier == .compatible,
           let matched = beatMatchedPlan(outgoing: outgoing, incoming: incoming,
                                         stems: stems, config: config) {
            // The full DJ hand-over: staged three-band EQ across the overlap.
            // A stem technique layers *under* that — it rewrites what the
            // outgoing deck is fed, and the fader / EQ / outro automation then
            // runs over it unchanged (see `StemTechniqueLayer`).
            var style = TransitionStyle(outroEffect: .fade, stagedEQ: true)
            style.stemTechnique = matched.stem
            return PlannedTransition(plan: .beatMatched(matched.plan), style: style)
        }
        let cap: TimeInterval
        switch tier {
        case .compatible: cap = config.maxOverlap
        case .neutral: cap = config.neutralOverlapCap
        case .clash: cap = config.clashOverlapCap
        }
        let crossfade = crossfadePlan(outgoing: outgoing, incoming: incoming,
                                      tierCap: cap, tier: tier, stems: stems, config: config)
        // Same composition rule as above: the stem technique never replaces
        // the outro effect or the staged-EQ decision, it sits beneath them.
        // So a ducked vocal under a filter sweep is a swept exit whose vocal
        // is 9 dB down, not a different exit.
        var style = crossfadeStyle(tier: tier, outgoing: outgoing,
                                   plan: crossfade.plan, config: config)
        style.stemTechnique = crossfade.stem
        return PlannedTransition(plan: crossfade.plan, style: style)
    }

    // MARK: - Stem layer
    //
    // Two rules, checked in this order, and only ever when the caller says a
    // separator is available. Both start from the same observation: a stem
    // technique acts on the *outgoing vocal*, so it is worth nothing in a
    // window that has none — and the corpus says the planner's own out points
    // are exactly such windows. Fourteen of sixteen tracks have an
    // `outroFadeStart`, which pins the crossfade out point to the fade itself:
    // the track is on its way to silence there, and a separation of that
    // window comes back near-empty (measured vocal-over-mixture energy ≈ 0.005
    // against ~0.33 mid-song). So both rules re-aim the out point at a
    // vocal-carrying phrase boundary *before* the outro, and decline to name a
    // technique when no such boundary exists.
    //
    //   1. vocalDuck — the outgoing window is vocal-active and so is the
    //      incoming opening. Without stems this is the one blend a DJ never
    //      allows, and the planner punishes it: the crossfade is cut to
    //      `vocalClashFadeCap`, and the 8/16-bar beat-matched upgrades are
    //      refused. With stems the punishment becomes a technique — keep the
    //      long overlap and hold the outgoing vocal `stemDuckDepthDB` down.
    //      S1's blind test liked this best (3 of 6 pairs).
    //   2. acapellaOver — the outgoing window is vocal-active and the incoming
    //      opening is instrumental-leaning, at `tier == .compatible` only.
    //      S1: this is the structure the technique was built for, and the one
    //      technique whose separation residue is genuinely exposed, so it stays
    //      on the tier that already licenses a full blend.
    //
    // `instrumentalOut` is deliberately never chosen automatically: it never
    // won a pair in S1's blind test. It remains reachable by hand (`--stem
    // instrumental`, or the console's picker) so it can keep being auditioned.
    //
    // The two rules cannot both apply: `stemAcapellaIncomingVocalMax` (0.90)
    // sits below `vocalClashRatio` (1.10), so an incoming opening is either
    // hot enough to duck against or quiet enough to float over, never both.

    /// What the stem search settled on: where to hand over, and with which
    /// technique.
    private struct StemChoice {
        let outPoint: TimeInterval
        let technique: StemTechnique
    }

    /// Pick a vocal-carrying out point out of `candidates` (tail-window phrase
    /// boundaries that fit `overlap`, best-scored first) and name the technique
    /// its structure implies; nil when nothing here is worth a separation pass.
    private static func stemChoice(
        outgoing: TrackAnalysis, incoming: TrackAnalysis,
        candidates: [TimeInterval], inPoint: TimeInterval, overlap: TimeInterval,
        tier: CompatibilityTier, config: Config
    ) -> StemChoice? {
        guard overlap >= config.stemMinOverlap else { return nil }
        // Best-scored boundary that actually carries the outgoing vocal — the
        // exact opposite of the whole-mix rule below, which prefers a window
        // where the vocals have already finished.
        guard let outPoint = candidates.first(where: {
            (vocalScore(outgoing, from: $0, length: overlap) ?? 0) >= config.stemVocalActiveRatio
        }) else { return nil }

        // A missing incoming contour means an instrumental (or a vocal too
        // weak to measure): not something to duck against, and fine to float
        // over — same reading `vocalsClash` gives it.
        let incomingScore = vocalScore(incoming, from: inPoint, length: overlap)
        if let incomingScore, incomingScore > config.vocalClashRatio {
            return StemChoice(
                outPoint: outPoint,
                technique: .vocalDuck(depthDB: Float(-abs(config.stemDuckDepthDB))))
        }
        if tier == .compatible,
           (incomingScore ?? 0) <= config.stemAcapellaIncomingVocalMax {
            return StemChoice(outPoint: outPoint, technique: .acapellaOver)
        }
        return nil
    }

    /// Phrase boundaries in the outgoing tail that can hold `overlap` and sit
    /// *before* any outro fade — the stem search's candidate list.
    ///
    /// This is the beat-matched out-point window rather than the crossfade's
    /// `crossfadeOutPointShare` one, on purpose: the crossfade window happily
    /// includes the outro fade, and handing over inside a fade is precisely
    /// what leaves a stem technique with nothing to work on.
    private static func stemCandidates(
        _ a: TrackAnalysis, overlap: TimeInterval, config: Config
    ) -> [TimeInterval] {
        let outLimit = a.outroFadeStart ?? a.duration
        let windowStart = max(a.duration * config.tailWindowShare,
                              outLimit - config.tailWindowSeconds)
        return a.phraseBoundaries.filter {
            $0 >= windowStart && $0 <= outLimit && $0 + overlap <= a.duration
        }
    }

    /// Which technique sends the outgoing track off, per tier: clashing
    /// pairs exit on an (ideally beat-synced) echo instead of an apologetic
    /// fade; neutral pairs with a hot tail get hollowed out by a filter
    /// sweep; compatible long fades earn the staged EQ hand-over.
    private static func crossfadeStyle(
        tier: CompatibilityTier, outgoing: TrackAnalysis, plan: TransitionPlan,
        config: Config
    ) -> TransitionStyle {
        guard case .crossfade(let duration, _, _) = plan else { return .plain }
        switch tier {
        case .clash:
            guard outgoing.bpmConfidence >= config.keyConfidenceThreshold, outgoing.bpm > 0
            else { return .plain }
            // Dotted eighth of the outgoing tempo — the classic echo-out tail.
            let delay = min(max(config.echoBeatFraction * 60 / outgoing.bpm,
                                config.echoDelayMin), config.echoDelayMax)
            return TransitionStyle(outroEffect: .echoOut, stagedEQ: false,
                                   echoDelayTime: delay)
        case .neutral:
            // A track already fading itself out doesn't need to be swept out.
            return outgoing.outroFadeStart == nil
                ? TransitionStyle(outroEffect: .filterSweep, stagedEQ: false)
                : .plain
        case .compatible:
            return duration >= config.stagedEQMinOverlap
                ? TransitionStyle(outroEffect: .fade, stagedEQ: true)
                : .plain
        }
    }

    // MARK: - Key gate

    /// Both keys confident and ≥ `clashKeyDistance` apart on the circle of
    /// fifths. Minors fold to their relative major first, so Am → C is
    /// distance 0 (Camelot-style adjacency).
    private static func keysClash(
        _ a: TrackAnalysis, _ b: TrackAnalysis, _ config: Config
    ) -> Bool {
        guard let distance = keyDistance(a, b, config: config) else { return false }
        return distance >= config.clashKeyDistance
    }

    /// Circle-of-fifths distance between two confident keys; nil when either
    /// key is missing or below the confidence gate. Exposed so `audition` can
    /// print the number the decision actually turned on.
    static func keyDistance(
        _ a: TrackAnalysis, _ b: TrackAnalysis, config: Config = .standard
    ) -> Int? {
        guard let ka = a.keyPitchClass, let kb = b.keyPitchClass,
              a.keyConfidence >= config.keyConfidenceThreshold,
              b.keyConfidence >= config.keyConfidenceThreshold
        else { return nil }
        let majA = a.keyIsMinor ? (ka + 3) % 12 : ka
        let majB = b.keyIsMinor ? (kb + 3) % 12 : kb
        // Position on the circle of fifths, then circular distance.
        let ia = (majA * 7) % 12
        let ib = (majB * 7) % 12
        let d = abs(ia - ib)
        return min(d, 12 - d)
    }

    // MARK: - Vocal gate

    /// Mean vocal activity over [from, from+length), relative to the track's
    /// own mean; nil when the track has no usable vocal contour (analysis
    /// missing, or an instrumental with a near-zero baseline).
    static func vocalScore(
        _ a: TrackAnalysis, from: TimeInterval, length: TimeInterval
    ) -> Double? {
        let env = a.vocalActivity
        guard !env.isEmpty else { return nil }
        let trackMean = Double(env.reduce(0) { $0 + Double($1) }) / Double(env.count)
        guard trackMean > 0.05 else { return nil }
        let start = max(0, min(env.count - 1, Int(from)))
        let end = max(start + 1, min(env.count, Int((from + length).rounded(.up))))
        let slice = env[start..<end]
        let mean = Double(slice.reduce(0) { $0 + Double($1) }) / Double(slice.count)
        return mean / trackMean
    }

    private static func vocalsClash(
        outgoing: TrackAnalysis, outPoint: TimeInterval,
        incoming: TrackAnalysis, inPoint: TimeInterval,
        overlap: TimeInterval, config: Config
    ) -> Bool {
        guard let outScore = vocalScore(outgoing, from: outPoint, length: overlap),
              let inScore = vocalScore(incoming, from: inPoint, length: overlap)
        else { return false }
        return outScore > config.vocalClashRatio && inScore > config.vocalClashRatio
    }

    /// The three raw numbers the tier gate turns on, kept together so
    /// `audition` can print them (and how close each sits to its threshold)
    /// rather than re-deriving them and drifting from the real decision.
    struct Signals {
        let loudnessGapDB: Double
        let timbreDistance: Double
        /// Folded (double/half-time) BPM difference as a ratio of the outgoing
        /// tempo; nil when either tempo is below the confidence gate.
        let tempoRatio: Double?
    }

    static func signals(
        outgoing: TrackAnalysis, incoming: TrackAnalysis, config: Config = .standard
    ) -> Signals {
        var tempoRatio: Double?
        if outgoing.bpmConfidence >= config.bpmConfidenceThreshold,
           incoming.bpmConfidence >= config.bpmConfidenceThreshold,
           outgoing.bpm > 0, incoming.bpm > 0 {
            tempoRatio = [0.5, 1.0, 2.0]
                .map { abs(incoming.bpm * $0 - outgoing.bpm) / outgoing.bpm }
                .min()!
        }
        return Signals(
            loudnessGapDB: loudnessGapDB(outgoing: outgoing, incoming: incoming,
                                         config: config),
            timbreDistance: timbreDistance(outgoing.melProfile, incoming.melProfile),
            tempoRatio: tempoRatio)
    }

    static func compatibility(
        outgoing: TrackAnalysis, incoming: TrackAnalysis, config: Config = .standard
    ) -> CompatibilityTier {
        tier(of: signals(outgoing: outgoing, incoming: incoming, config: config),
             config: config)
    }

    static func tier(of s: Signals, config: Config = .standard) -> CompatibilityTier {
        let tempoClash = (s.tempoRatio ?? 0) > config.clashTempoRatio
        if s.loudnessGapDB > config.clashLoudnessDB
            || s.timbreDistance > config.clashTimbreDistance
            || tempoClash {
            return .clash
        }
        if s.loudnessGapDB > config.neutralLoudnessDB
            || s.timbreDistance > config.neutralTimbreDistance {
            return .neutral
        }
        return .compatible
    }

    /// |dB| gap between the outgoing tail's mean RMS and the incoming
    /// opening's mean RMS (~15 s windows).
    private static func loudnessGapDB(
        outgoing: TrackAnalysis, incoming: TrackAnalysis, config: Config
    ) -> Double {
        func mean(_ env: [Float], from: Int, length: Int) -> Double {
            let start = max(0, min(env.count - 1, from))
            let end = max(start + 1, min(env.count, from + length))
            let slice = env[start..<end]
            return Double(slice.reduce(0, +)) / Double(slice.count)
        }
        guard !outgoing.rmsEnvelope.isEmpty, !incoming.rmsEnvelope.isEmpty else { return 0 }
        // Anchor the outgoing window *before* any outro fade: a track that
        // fades itself out reads as near-silence over its literal last
        // seconds, which is the fade — not a level mismatch (audition-loop
        // finding: this misread 12/15 real pairs as 15–31 dB clashes).
        let tailEnd = min(outgoing.rmsEnvelope.count,
                          Int(outgoing.outroFadeStart ?? outgoing.duration))
        let window = max(1, config.loudnessWindow)
        let tail = mean(outgoing.rmsEnvelope, from: tailEnd - window, length: window)
        let opening = mean(incoming.rmsEnvelope, from: Int(incoming.introEnd), length: window)
        guard tail > 1e-6, opening > 1e-6 else { return 0 }
        return abs(20 * log10(tail / opening))
    }

    /// Cosine distance between the (already normalized) mel fingerprints;
    /// 0 when either is missing — absence of evidence is not a clash.
    private static func timbreDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return Double(max(0, 1 - dot))
    }

    // MARK: - Rule 1: beat-matched

    private static func beatMatchedPlan(
        outgoing: TrackAnalysis, incoming: TrackAnalysis,
        stems: StemAvailability, config: Config
    ) -> (plan: BeatMatchedPlan, stem: StemTechnique?)? {
        guard outgoing.bpmConfidence >= config.bpmConfidenceThreshold,
              incoming.bpmConfidence >= config.bpmConfidenceThreshold,
              outgoing.bpm > 0, incoming.bpm > 0
        else { return nil }

        // Fold the incoming tempo to the closest double/half-time candidate.
        let foldedBPM = [0.5, 1.0, 2.0]
            .map { incoming.bpm * $0 }
            .min { abs($0 - outgoing.bpm) < abs($1 - outgoing.bpm) }!
        guard abs(foldedBPM - outgoing.bpm) / outgoing.bpm <= config.maxBPMDeltaRatio else {
            return nil
        }

        // Meet in the middle; each deck bends at most ±4%.
        let targetBPM = (outgoing.bpm + foldedBPM) / 2
        let outgoingRate = targetBPM / outgoing.bpm
        let incomingRate = targetBPM / foldedBPM
        guard abs(outgoingRate - 1) <= config.maxRateDeviation + 1e-9,
              abs(incomingRate - 1) <= config.maxRateDeviation + 1e-9
        else { return nil }

        // In point: the downbeat aligned with the incoming track's intro end.
        guard let inPoint = incoming.downbeats.first(where: { $0 >= incoming.introEnd - 0.05 })
                ?? incoming.downbeats.first
        else { return nil }

        let beatDuration = 60.0 / targetBPM
        func overlapDuration(bars: Int) -> TimeInterval { Double(bars) * 4 * beatDuration }
        let overlapCeiling = min(
            config.maxOverlap,
            config.maxOverlapShare * min(outgoing.duration, incoming.duration))

        // Out point: best-scored phrase boundary before any outro fade that
        // still leaves room for the overlap. Boundaries are ordered by score,
        // so restrict candidates to a tail window first — the top-scored
        // boundary may sit mid-song, and cutting there would skip half the
        // track.
        let outLimit = outgoing.outroFadeStart ?? outgoing.duration
        let tailWindowStart = max(outgoing.duration * config.tailWindowShare,
                                  outLimit - config.tailWindowSeconds)
        func outPoint(forOverlap overlap: TimeInterval) -> TimeInterval? {
            outgoing.phraseBoundaries.first {
                $0 >= tailWindowStart && $0 <= outLimit && $0 + overlap <= outgoing.duration
            }
        }

        // Longest steady overlap wins, under the shared ceiling: 16 or 8
        // bars when both regions hold steady, 4 bars as the floor.
        var bars = 4
        var chosenOutPoint: TimeInterval?
        for candidate in [16, 8] {
            let overlap = overlapDuration(bars: candidate)
            guard overlap <= overlapCeiling,
                  let op = outPoint(forOverlap: overlap),
                  inPoint + overlap <= incoming.duration,
                  isStable(outgoing.rmsEnvelope, from: op, length: overlap,
                           cv: config.stableCV),
                  isStable(incoming.rmsEnvelope, from: inPoint, length: overlap,
                           cv: config.stableCV),
                  !vocalsClash(outgoing: outgoing, outPoint: op,
                               incoming: incoming, inPoint: inPoint, overlap: overlap,
                               config: config)
            else { continue }
            bars = candidate
            chosenOutPoint = op
            break
        }
        if chosenOutPoint == nil {
            let overlap4 = overlapDuration(bars: 4)
            guard overlap4 <= overlapCeiling,
                  let op4 = outPoint(forOverlap: overlap4),
                  inPoint + overlap4 <= incoming.duration
            else { return nil }
            chosenOutPoint = op4
        }
        guard let outPoint = chosenOutPoint else { return nil }

        func made(bars: Int, outPoint: TimeInterval) -> BeatMatchedPlan {
            let overlap = overlapDuration(bars: bars)
            return BeatMatchedPlan(
                outPoint: outPoint,
                inPoint: inPoint,
                overlapBars: bars,
                outgoingRate: Float(outgoingRate),
                incomingRate: Float(incomingRate),
                bassSwapOffset: overlap / 2,
                overlapDuration: overlap)
        }
        let plain = made(bars: bars, outPoint: outPoint)
        guard stems == .ready else { return (plain, nil) }

        // Stem variant: the same longest-first bar search, but the vocal gate
        // that blocked the 8/16-bar upgrades above is replaced by "a stem
        // technique must apply here". So a pair the whole-mix planner cut back
        // to four bars for a vocal clash gets its long overlap back — with the
        // clash ducked rather than avoided. Everything the search still
        // insists on (the ceiling, both sides' steadiness, room on the
        // incoming deck) is unchanged: a technique cannot make a lurching
        // window sit still.
        for candidate in [16, 8, 4] {
            let overlap = overlapDuration(bars: candidate)
            guard overlap <= overlapCeiling, inPoint + overlap <= incoming.duration,
                  let choice = stemChoice(
                    outgoing: outgoing, incoming: incoming,
                    candidates: stemCandidates(outgoing, overlap: overlap, config: config),
                    inPoint: inPoint, overlap: overlap, tier: .compatible, config: config)
            else { continue }
            if candidate > 4 {
                guard isStable(outgoing.rmsEnvelope, from: choice.outPoint, length: overlap,
                               cv: config.stableCV),
                      isStable(incoming.rmsEnvelope, from: inPoint, length: overlap,
                               cv: config.stableCV)
                else { continue }
            }
            return (made(bars: candidate, outPoint: choice.outPoint), choice.technique)
        }
        return (plain, nil)
    }

    /// Whether the 1s RMS envelope is steady over [from, from+length).
    private static func isStable(
        _ envelope: [Float], from: TimeInterval, length: TimeInterval, cv: Double
    ) -> Bool {
        let start = max(0, Int(from))
        let end = min(envelope.count, Int((from + length).rounded(.up)))
        guard end - start >= 3 else { return false }
        let slice = envelope[start..<end]
        let mean = slice.reduce(0, +) / Float(slice.count)
        guard mean > 1e-4 else { return false }
        let variance = slice.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
            / Float(slice.count)
        return Double(variance.squareRoot() / mean) < cv
    }

    /// How many tail seconds of the outgoing track can sit under a fade:
    /// the whole outro when the track fades itself out, otherwise the
    /// longest energy-steady window ending at the tail.
    static func tailCapacity(_ a: TrackAnalysis, config: Config) -> TimeInterval {
        if let outro = a.outroFadeStart {
            return a.duration - max(outro, a.duration * config.tailWindowShare)
        }
        let env = a.rmsEnvelope
        for len in stride(from: Int(config.maxOverlap), through: 3, by: -1) {
            let start = env.count - len
            guard start >= 0 else { continue }
            if isStable(env, from: TimeInterval(start), length: TimeInterval(len),
                        cv: config.tailStableCV) {
                return TimeInterval(len)
            }
        }
        // The track ends hot and jagged — keep the fade short.
        return config.tailCapacityFallback
    }

    /// How long the incoming opening can sit under the fade: its energy
    /// climb after the in point (a slow build hides nicely under the
    /// outgoing tail; a hot open should surface fast), plus a little body.
    static func intakeCapacity(
        _ a: TrackAnalysis, inPoint: TimeInterval, config: Config
    ) -> TimeInterval {
        let env = a.rmsEnvelope
        guard let peak = env.max(), peak > 0, !env.isEmpty else { return 6 }
        var i = min(env.count - 1, max(0, Int(inPoint)))
        var climb: TimeInterval = 0
        while i < env.count, env[i] < peak * Float(config.intakePeakShare) {
            climb += 1
            i += 1
        }
        return climb + config.intakeBodySeconds
    }

    // MARK: - Rule 2: crossfade

    private static func crossfadePlan(
        outgoing: TrackAnalysis, incoming: TrackAnalysis,
        tierCap: TimeInterval, tier: CompatibilityTier,
        stems: StemAvailability, config: Config
    ) -> (plan: TransitionPlan, stem: StemTechnique?) {
        let inPoint = incoming.introEnd
        // Computed, not fixed: the shorter of what the outgoing tail can
        // carry and what the incoming opening can absorb, bounded by the
        // shared ceiling and the compatibility tier's cap.
        let ceiling = min(config.maxOverlap, tierCap,
                          config.maxOverlapShare * min(outgoing.duration, incoming.duration))
        var fade = max(config.minOverlap,
                       min(tailCapacity(outgoing, config: config),
                           intakeCapacity(incoming, inPoint: inPoint, config: config),
                           ceiling))

        let outPoint: TimeInterval
        if let outro = outgoing.outroFadeStart {
            // Trim the limp outro: hand over where the fade begins instead
            // of riding it down to silence and cutting at the last moment.
            outPoint = max(outro, outgoing.duration * config.tailWindowShare)
        } else {
            // Same tail-window restriction as the beat-matched out point;
            // among the candidates, prefer one where the outgoing vocals
            // have already finished.
            let candidates = outgoing.phraseBoundaries.filter {
                $0 >= outgoing.duration * config.crossfadeOutPointShare
                    && $0 + fade <= outgoing.duration
            }
            outPoint = candidates.first {
                (vocalScore(outgoing, from: $0, length: fade) ?? 0) <= config.vocalClashRatio
            } ?? candidates.first ?? max(0, outgoing.duration - fade)
        }
        // Stem layer, before the vocal cap: a technique that can hold the
        // outgoing vocal down does not need the overlap shortened, and it
        // needs a *vocal-carrying* out point rather than the outro fade this
        // search would otherwise settle on.
        if stems == .ready,
           let choice = stemChoice(
            outgoing: outgoing, incoming: incoming,
            candidates: stemCandidates(outgoing, overlap: fade, config: config),
            inPoint: inPoint, overlap: fade, tier: tier, config: config) {
            return (.crossfade(duration: fade, outPoint: choice.outPoint, inPoint: inPoint),
                    choice.technique)
        }

        // Two lead vocals over each other is the one unforgivable blend —
        // when no vocal-free window exists, keep the overlap brief instead.
        if vocalsClash(outgoing: outgoing, outPoint: outPoint,
                       incoming: incoming, inPoint: inPoint, overlap: fade,
                       config: config) {
            fade = min(fade, config.vocalClashFadeCap)
        }
        return (.crossfade(duration: fade, outPoint: outPoint, inPoint: inPoint), nil)
    }
}
