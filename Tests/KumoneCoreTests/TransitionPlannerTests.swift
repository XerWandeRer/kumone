import Testing
@testable import KumoneCore
import Foundation

@Suite struct TransitionPlannerTests {

    // MARK: - Fixtures

    /// Shared default timbre fingerprint, so fixtures compare as identical
    /// unless a test overrides one side. Shaped like what the analyzer now
    /// produces: a zero-sum, unit-norm 40-band spectral shape (here a plain
    /// bass-to-treble tilt).
    private static let defaultProfile: [Float] = unit((0..<40).map { Float($0) })

    /// A second shape, orthogonal to `defaultProfile`: a symmetric "smile"
    /// (mids scooped) with the tilt component projected out.
    private static let contrastProfile: [Float] = {
        let smile = (0..<40).map { b -> Float in
            let x = (Float(b) - 19.5) / 19.5
            return x * x
        }
        let base = defaultProfile
        let dot = zip(smile, base).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return unit(zip(smile, base).map { $0 - dot * $1 })
    }()

    /// Zero-sum, unit-norm version of `v` — the invariants of a real profile.
    private static func unit(_ v: [Float]) -> [Float] {
        let mean = v.reduce(0, +) / Float(v.count)
        let centered = v.map { $0 - mean }
        let norm = centered.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return centered.map { $0 / norm }
    }

    /// A profile sitting exactly `distance` (cosine distance) away from
    /// `defaultProfile`, by rotating it towards `contrastProfile`.
    private static func profile(distance: Float) -> [Float] {
        let cosine = 1 - distance
        let sine = (1 - cosine * cosine).squareRoot()
        return zip(defaultProfile, contrastProfile).map { cosine * $0 + sine * $1 }
    }

    private func makeAnalysis(
        bpm: Double = 120,
        confidence: Double = 0.9,
        duration: TimeInterval = 200,
        downbeats: [TimeInterval]? = nil,
        phraseBoundaries: [TimeInterval] = [150, 90, 30],
        rmsEnvelope: [Float]? = nil,
        outroFadeStart: TimeInterval? = nil,
        introEnd: TimeInterval = 2,
        melProfile: [Float]? = nil,
        keyPitchClass: Int? = nil,
        keyIsMinor: Bool = false,
        keyConfidence: Double = 0,
        vocalActivity: [Float] = [],
        referenceLoudness: Double? = nil,
        peakDBFS: Double? = -6
    ) -> TrackAnalysis {
        let barLength = 4 * 60 / bpm
        let db = downbeats ?? stride(from: 0.4, to: duration, by: barLength).map { $0 }
        let beats = stride(from: 0.4, to: duration, by: 60 / bpm).map { $0 }
        return TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: bpm,
            bpmConfidence: confidence,
            beats: beats,
            downbeats: db,
            phraseBoundaries: phraseBoundaries,
            rmsEnvelope: rmsEnvelope ?? [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: outroFadeStart,
            introEnd: introEnd,
            duration: duration,
            melProfile: melProfile ?? Self.defaultProfile,
            keyPitchClass: keyPitchClass, keyIsMinor: keyIsMinor,
            keyConfidence: keyConfidence,
            vocalActivity: vocalActivity,
            referenceLoudness: referenceLoudness,
            peakDBFS: peakDBFS)
    }

    /// Mechanics-only view of the planner result; style assertions use
    /// `TransitionPlanner.plan` directly.
    private func planOnly(
        outgoing: TrackAnalysis?, incoming: TrackAnalysis?
    ) -> TransitionPlan {
        TransitionPlanner.plan(outgoing: outgoing, incoming: incoming).plan
    }

    /// Choppy envelope: high coefficient of variation, never "steady".
    private func choppyEnvelope(duration: Int) -> [Float] {
        (0..<duration).map { $0 % 2 == 0 ? 0.1 : 0.9 }
    }

    // MARK: - Rule 1: beat-matched

    @Test func beatMatchedCloseBPMSteadyEnergyUses8Bars() throws {
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 124, introEnd: 2)
        guard case .beatMatched(let plan) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected beatMatched")
            return
        }
        // Target tempo splits the difference: (120+124)/2 = 122.
        #expect(abs(Double(plan.outgoingRate) - 122.0 / 120.0) < 1e-4)
        #expect(abs(Double(plan.incomingRate) - 122.0 / 124.0) < 1e-4)
        #expect(abs(Double(plan.outgoingRate) - 1) <= 0.04)
        #expect(abs(Double(plan.incomingRate) - 1) <= 0.04)
        // Steady envelopes on both sides → 8 bars.
        #expect(plan.overlapBars == 8)
        // Best-scored phrase boundary that fits the overlap.
        #expect(plan.outPoint == 150)
        // First downbeat at/after introEnd.
        let expectedInPoint = try #require(
            incoming.downbeats.first { $0 >= incoming.introEnd - 0.05 })
        #expect(abs(plan.inPoint - expectedInPoint) < 1e-9)
        #expect(abs(plan.overlapDuration - 8 * 4 * 60 / 122) < 1e-9)
        #expect(abs(plan.bassSwapOffset - plan.overlapDuration / 2) < 1e-9)
    }

    @Test func beatMatchedUnstableEnergyUses4Bars() {
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(
            bpm: 120, rmsEnvelope: choppyEnvelope(duration: 200))
        guard case .beatMatched(let plan) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(plan.overlapBars == 4)
        #expect(abs(plan.overlapDuration - 4 * 4 * 60 / 120) < 1e-9)
    }

    @Test func beatMatchedDoubleTimeFolding() {
        // 240 folds to 120: exact match, both rates 1.0.
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 240)
        guard case .beatMatched(let plan) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(abs(Double(plan.outgoingRate) - 1) < 1e-6)
        #expect(abs(Double(plan.incomingRate) - 1) < 1e-6)
    }

    @Test func beatMatchedHalfTimeFolding() {
        let outgoing = makeAnalysis(bpm: 124)
        let incoming = makeAnalysis(bpm: 62)
        guard case .beatMatched = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected beatMatched after half-time folding")
            return
        }
    }

    @Test func beatMatchedSkipsPhraseBoundaryAfterOutroFade() {
        // Boundary 150 sits inside the outro fade; 120 is the best remaining
        // candidate inside the tail window [max(100, 80), 140].
        let outgoing = makeAnalysis(bpm: 120, phraseBoundaries: [150, 120, 30],
                                    outroFadeStart: 140)
        let incoming = makeAnalysis(bpm: 120)
        guard case .beatMatched(let plan) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(plan.outPoint == 120)
    }

    @Test func beatMatchedIgnoresMidSongPhraseBoundary() {
        // The only boundaries sit mid-song (before 50% of the duration);
        // cutting there would skip half the track, so the plan degrades.
        let outgoing = makeAnalysis(bpm: 120, phraseBoundaries: [90, 30])
        let incoming = makeAnalysis(bpm: 120)
        guard case .crossfade = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade when no tail-window boundary exists")
            return
        }
    }

    @Test func beatMatchedWithoutPhraseBoundariesFallsBackToCrossfade() {
        let outgoing = makeAnalysis(bpm: 120, phraseBoundaries: [])
        let incoming = makeAnalysis(bpm: 120)
        guard case .crossfade = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade fallback without phrase boundaries")
            return
        }
    }

    // MARK: - Rule 2: crossfade

    @Test func farBPMFallsBackToCrossfade() {
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 100, introEnd: 3)
        guard case .crossfade(let duration, let outPoint, let inPoint) =
            planOnly(outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        // Flat 0.5 envelope: tail carries plenty, but the incoming opening is
        // already at full energy → intake caps the fade at 8 s.
        #expect(duration == 8)
        #expect(outPoint == 150)  // best phrase boundary in the tail window
        #expect(inPoint == 3)
    }

    @Test func lowConfidenceFallsBackToCrossfade() {
        let outgoing = makeAnalysis(bpm: 120, confidence: 0.5)
        let incoming = makeAnalysis(bpm: 120)
        guard case .crossfade = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade with low confidence")
            return
        }
    }

    @Test func outroFadeUsesShortTailCrossfade() {
        let outgoing = makeAnalysis(bpm: 120, duration: 200, outroFadeStart: 180)
        let incoming = makeAnalysis(bpm: 100, introEnd: 1.5)
        guard case .crossfade(let duration, let outPoint, let inPoint) =
            planOnly(outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        // The limp outro is trimmed: the hand-over starts where the fade
        // begins, not two seconds before silence. Length still bounded by
        // the hot-opening incoming side (8 s).
        #expect(duration == 8)
        #expect(outPoint == 180)
        #expect(inPoint == 1.5)
    }

    @Test func crossfadeWithoutPhraseBoundariesUsesTail() {
        let outgoing = makeAnalysis(bpm: 120, confidence: 0.2, phraseBoundaries: [])
        let incoming = makeAnalysis(bpm: 120)
        guard case .crossfade(let duration, let outPoint, _) =
            planOnly(outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration == 8)
        #expect(outPoint == 192)
    }

    @Test func quietOpeningEarnsLongCrossfade() {
        // Incoming spends its first 12 s well below peak: the climb hides
        // under the outgoing tail, so the fade stretches (climb ≈ 10 + 8).
        var env = [Float](repeating: 0.1, count: 12)
        env += [Float](repeating: 0.9, count: 188)
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 100, rmsEnvelope: env, introEnd: 2)
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration == 18)
    }

    @Test func hotJaggedTailKeepsCrossfadeShort() {
        // Outgoing ends loud and choppy (no steady tail window): fade
        // collapses to the 4 s floor of tailCapacity.
        let outgoing = makeAnalysis(bpm: 120, rmsEnvelope: choppyEnvelope(duration: 200))
        let incoming = makeAnalysis(bpm: 100)
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration == 4)
    }

    @Test func fastTempoSteadyEnergyUses16Bars() {
        // At ~198 BPM sixteen bars fit inside the 20 s ceiling; flat
        // envelopes on both sides let the upgrade through.
        let outgoing = makeAnalysis(bpm: 200)
        let incoming = makeAnalysis(bpm: 196, introEnd: 2)
        guard case .beatMatched(let plan) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(plan.overlapBars == 16)
    }

    // MARK: - Compatibility gate

    @Test func loudnessClashForcesShortFade() {
        // Same BPM would normally beat-match, but a ~24 dB loudness gap
        // (banger → whisper-quiet track) gates the pair down to a
        // boundary-respecting short fade.
        let outgoing = makeAnalysis(bpm: 120,
                                    rmsEnvelope: [Float](repeating: 0.8, count: 200))
        let incoming = makeAnalysis(bpm: 120,
                                    rmsEnvelope: [Float](repeating: 0.05, count: 200))
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected short crossfade, not beatMatched")
            return
        }
        #expect(duration <= TransitionPlanner.clashOverlapCap)
    }

    @Test func outroFadeIsNotALoudnessClash() {
        // The outgoing track fades itself out over its last 20 s. Its level
        // *before* the fade matches the incoming opening — the fade is not a
        // mismatch, so the pair must not be gated down to the clash tier.
        var env = [Float](repeating: 0.5, count: 180)
        env += (0..<20).map { 0.5 * Float(20 - $0) / 20 }
        let outgoing = makeAnalysis(bpm: 120, rmsEnvelope: env, outroFadeStart: 180)
        let incoming = makeAnalysis(bpm: 100)
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration > TransitionPlanner.clashOverlapCap)
    }

    // MARK: - Loudness compensation and the tier gate

    /// The gate must judge what will be *played*, not what is on disk. Two
    /// masters 8 dB apart are a clash on the raw numbers; once each deck runs
    /// at its own trim the gap is gone, so the pair must not be punished.
    @Test func compensationRemovesAMasteringLoudnessClash() {
        // −6 LUFS vs −14 LUFS, and the RMS windows carry the same 8 dB gap.
        let loudEnv = [Float](repeating: 0.5, count: 200)
        let quietEnv = [Float](repeating: 0.5 * 0.398, count: 200)  // −8 dB
        let outgoing = makeAnalysis(bpm: 120, rmsEnvelope: loudEnv, referenceLoudness: -6)
        let incoming = makeAnalysis(bpm: 120, rmsEnvelope: quietEnv, referenceLoudness: -14)

        var off = TransitionPlanner.Config.standard
        off.loudnessCompensation = false
        let raw = TransitionPlanner.signals(outgoing: outgoing, incoming: incoming, config: off)
        #expect(abs(raw.loudnessGapDB - 8) < 0.2)
        #expect(raw.loudnessGapDB > TransitionPlanner.clashLoudnessDB)
        #expect(TransitionPlanner.tier(of: raw, config: off) == .clash)

        let compensated = TransitionPlanner.signals(outgoing: outgoing, incoming: incoming)
        // −6 LUFS gets −8 dB, −14 LUFS gets 0: exactly the 8 dB gap.
        #expect(abs(compensated.outgoingTrimDB - -8) < 1e-6)
        #expect(abs(compensated.incomingTrimDB) < 1e-6)
        #expect(abs(compensated.rawLoudnessGapDB - 8) < 0.2)
        #expect(compensated.loudnessGapDB < 0.2)
        #expect(TransitionPlanner.tier(of: compensated) == .compatible)
    }

    /// What the trim cannot reach, the gate still sees. A master so quiet that
    /// the +3 dB boost ceiling bites leaves a residual, and that residual —
    /// not the full raw gap — is what the thresholds are measured against.
    @Test func theGateStillSeesWhatTheTrimCannotAbsorb() {
        let loudEnv = [Float](repeating: 0.5, count: 200)
        let quietEnv = [Float](repeating: 0.5 * 0.0794, count: 200)  // −22 dB
        let outgoing = makeAnalysis(bpm: 120, rmsEnvelope: loudEnv, referenceLoudness: -8)
        // −33 LUFS wants +19 dB and may have +3 (the peak leaves room).
        let incoming = makeAnalysis(bpm: 120, rmsEnvelope: quietEnv,
                                    referenceLoudness: -33, peakDBFS: -30)

        let s = TransitionPlanner.signals(outgoing: outgoing, incoming: incoming)
        #expect(abs(s.outgoingTrimDB - -6) < 1e-6)
        #expect(abs(s.incomingTrimDB - 3) < 1e-6)
        #expect(abs(s.rawLoudnessGapDB - 22) < 0.3)
        // 22 raw − 6 (cut) − 3 (boost) = 13 dB the compensation could not close.
        #expect(abs(s.loudnessGapDB - 13) < 0.3)
        #expect(TransitionPlanner.tier(of: s) == .clash)
    }

    /// Tracks with no loudness reading (never analyzed at v6) behave exactly
    /// as they did before compensation existed.
    @Test func withoutAMeasurementTheGateIsUnchanged() {
        let loudEnv = [Float](repeating: 0.5, count: 200)
        let quietEnv = [Float](repeating: 0.5 * 0.398, count: 200)
        let s = TransitionPlanner.signals(
            outgoing: makeAnalysis(bpm: 120, rmsEnvelope: loudEnv),
            incoming: makeAnalysis(bpm: 120, rmsEnvelope: quietEnv))
        #expect(s.outgoingTrimDB == 0)
        #expect(s.incomingTrimDB == 0)
        #expect(abs(s.loudnessGapDB - s.rawLoudnessGapDB) < 1e-9)
        #expect(abs(s.loudnessGapDB - 8) < 0.2)
    }

    @Test func timbreClashForcesShortFade() {
        // Spectral shapes 0.6 apart — past the 0.45 clash line, and well past
        // anything a single track reaches against its own other half (≤ 0.09
        // across the audition corpus).
        let outgoing = makeAnalysis(bpm: 120, melProfile: Self.defaultProfile)
        let incoming = makeAnalysis(bpm: 120, melProfile: Self.profile(distance: 0.6))
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected short crossfade, not beatMatched")
            return
        }
        #expect(duration <= TransitionPlanner.clashOverlapCap)
    }

    @Test func mildTimbreDifferenceCapsAtNeutral() {
        // Cosine distance 0.35 — between the neutral (0.25) and clash (0.45)
        // thresholds. A slow-building incoming would otherwise earn an 18 s
        // fade; the neutral tier caps it at 6 s.
        var env = [Float](repeating: 0.1, count: 12)
        env += [Float](repeating: 0.9, count: 188)
        let outgoing = makeAnalysis(bpm: 120, melProfile: Self.defaultProfile)
        let incoming = makeAnalysis(bpm: 100, rmsEnvelope: env, introEnd: 2,
                                    melProfile: Self.profile(distance: 0.35))
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration == TransitionPlanner.neutralOverlapCap)
    }

    @Test func withinStyleTimbreDifferenceStaysCompatible() {
        // 0.10 apart: the scale a single track reaches between its own two
        // halves on the audition corpus (median 0.03, worst 0.09). Two
        // arrangements of one style must keep the full AutoMix treatment.
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, melProfile: Self.defaultProfile),
            incoming: makeAnalysis(bpm: 124, introEnd: 2,
                                   melProfile: Self.profile(distance: 0.10)))
        guard case .beatMatched = planned.plan else {
            Issue.record("expected beatMatched for a within-style timbre gap")
            return
        }
    }

    @Test func confidentTempoClashForcesShortFade() {
        // 120 vs 88 BPM: folded distance 26.7% — two confident but
        // incompatible grooves must not blend for long.
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 88)
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration <= TransitionPlanner.clashOverlapCap)
    }

    // MARK: - Style strategy

    @Test func beatMatchedGetsStagedEQ() {
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120),
            incoming: makeAnalysis(bpm: 124, introEnd: 2))
        guard case .beatMatched = planned.plan else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(planned.style.stagedEQ)
        #expect(planned.style.outroEffect == .fade)
    }

    @Test func clashTierExitsOnBeatSyncedEcho() throws {
        // Far-apart timbres → clash tier; a confident outgoing tempo turns
        // the short fade into an echo-out with a dotted-eighth delay.
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, melProfile: Self.defaultProfile),
            incoming: makeAnalysis(bpm: 120, melProfile: Self.profile(distance: 0.6)))
        #expect(planned.style.outroEffect == .echoOut)
        #expect(!planned.style.stagedEQ)
        let delay = try #require(planned.style.echoDelayTime)
        #expect(abs(delay - 0.75 * 60 / 120) < 1e-9)
    }

    @Test func neutralTierHotTailGetsFilterSweep() {
        // Mild timbre difference → neutral tier; no natural outro means the
        // outgoing track leaves via the high-pass sweep.
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, melProfile: Self.defaultProfile),
            incoming: makeAnalysis(bpm: 100, melProfile: Self.profile(distance: 0.35)))
        #expect(planned.style.outroEffect == .filterSweep)
    }

    @Test func compatibleLongCrossfadeGetsStagedEQ() {
        // Quiet-opening incoming earns a 15 s fade (see
        // quietOpeningEarnsLongCrossfade); long compatible fades upgrade to
        // the staged EQ hand-over.
        var env = [Float](repeating: 0.1, count: 12)
        env += [Float](repeating: 0.9, count: 188)
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120),
            incoming: makeAnalysis(bpm: 100, rmsEnvelope: env, introEnd: 2))
        guard case .crossfade(let duration, _, _) = planned.plan else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration == 18)
        #expect(planned.style.stagedEQ)
        #expect(planned.style.outroEffect == .fade)
    }

    // MARK: - Key gate

    @Test func distantKeysDemoteCompatibleToNeutral() {
        // Identical timbre/loudness, but C major against A major — three
        // fifths apart: the long blend is denied (neutral cap), though not
        // forced down to the clash tier.
        var env = [Float](repeating: 0.1, count: 12)
        env += [Float](repeating: 0.9, count: 188)
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.8),
            incoming: makeAnalysis(bpm: 100, rmsEnvelope: env, introEnd: 2,
                                   keyPitchClass: 9, keyConfidence: 0.8))
        guard case .crossfade(let duration, _, _) = planned.plan else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration == TransitionPlanner.neutralOverlapCap)
    }

    @Test func relativeMinorKeysStayCompatible() {
        // A minor folds to C major: distance 0, no demotion — the pair still
        // beat-matches.
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.8),
            incoming: makeAnalysis(bpm: 124, introEnd: 2,
                                   keyPitchClass: 9, keyIsMinor: true, keyConfidence: 0.8))
        guard case .beatMatched = planned.plan else {
            Issue.record("expected beatMatched")
            return
        }
    }

    @Test func lowConfidenceKeysNeverDemote() {
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.3),
            incoming: makeAnalysis(bpm: 124, introEnd: 2,
                                   keyPitchClass: 6, keyConfidence: 0.3))
        guard case .beatMatched = planned.plan else {
            Issue.record("expected beatMatched")
            return
        }
    }

    // MARK: - Vocal gate

    /// Vocal contour with a modest baseline and a hot region.
    private func vocalEnvelope(
        duration: Int, hot: Range<Int>
    ) -> [Float] {
        (0..<duration).map { hot.contains($0) ? 0.9 : 0.2 }
    }

    @Test func vocalsOnBothSidesCapTheFade() {
        // Both overlap windows are vocal-heavy relative to their tracks:
        // the fade collapses to the vocal-clash cap instead of the 18 s the
        // energy shapes would earn. (Confidence below the BPM threshold so
        // the pair crossfades rather than beat-matching.)
        var env = [Float](repeating: 0.1, count: 12)
        env += [Float](repeating: 0.9, count: 188)
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, confidence: 0.3,
                                   vocalActivity: vocalEnvelope(duration: 200, hot: 130..<200)),
            incoming: makeAnalysis(bpm: 120, confidence: 0.3, rmsEnvelope: env, introEnd: 2,
                                   vocalActivity: vocalEnvelope(duration: 200, hot: 0..<40)))
        guard case .crossfade(let duration, _, _) = planned.plan else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration <= TransitionPlanner.vocalClashFadeCap)
    }

    @Test func vocalClashBlocksLongBeatMatchedOverlap() {
        // Beat-matchable pair, but vocals ride both overlap windows: the
        // 8-bar upgrade is denied and the plan falls to the 4-bar floor.
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120,
                                   vocalActivity: vocalEnvelope(duration: 200, hot: 140..<200)),
            incoming: makeAnalysis(bpm: 124, introEnd: 2,
                                   vocalActivity: vocalEnvelope(duration: 200, hot: 0..<40)))
        guard case .beatMatched(let plan) = planned.plan else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(plan.overlapBars == 4)
    }

    // MARK: - Stem layer

    /// Slow-building incoming: earns the 18 s fade the stem tests reason about.
    private func slowBuildEnvelope() -> [Float] {
        [Float](repeating: 0.1, count: 12) + [Float](repeating: 0.9, count: 188)
    }

    /// Outgoing whose last third is sung, incoming whose opening is sung —
    /// the two-lead-vocals case. Without stems this is punished; with them it
    /// is ducked.
    private func clashingVocalPair(
        confidence: Double = 0.3, incomingBPM: Double = 120,
        outgoingOutroFadeStart: TimeInterval? = nil
    ) -> (TrackAnalysis, TrackAnalysis) {
        (makeAnalysis(bpm: 120, confidence: confidence,
                      outroFadeStart: outgoingOutroFadeStart,
                      vocalActivity: vocalEnvelope(duration: 200, hot: 130..<200)),
         makeAnalysis(bpm: incomingBPM, confidence: confidence,
                      rmsEnvelope: slowBuildEnvelope(), introEnd: 2,
                      vocalActivity: vocalEnvelope(duration: 200, hot: 0..<40)))
    }

    /// The hard contract: at `.none` the planner is the pre-stem planner,
    /// field for field, across every shape the rules can reach.
    @Test func stemsNoneIsIndistinguishableFromTheOldPlanner() {
        var cases: [(TrackAnalysis, TrackAnalysis)] = [
            (makeAnalysis(bpm: 120), makeAnalysis(bpm: 124, introEnd: 2)),
            (makeAnalysis(bpm: 120), makeAnalysis(bpm: 100, introEnd: 3)),
            (makeAnalysis(bpm: 120, melProfile: Self.defaultProfile),
             makeAnalysis(bpm: 120, melProfile: Self.profile(distance: 0.6))),
            (makeAnalysis(bpm: 120, duration: 200, outroFadeStart: 180),
             makeAnalysis(bpm: 100, introEnd: 1.5)),
            (makeAnalysis(bpm: 120, rmsEnvelope: choppyEnvelope(duration: 200)),
             makeAnalysis(bpm: 100)),
        ]
        cases.append(clashingVocalPair())
        cases.append(clashingVocalPair(confidence: 0.9, incomingBPM: 124))

        for (outgoing, incoming) in cases {
            let implicit = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming)
            let explicit = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                                  stems: .none)
            #expect(implicit.style == explicit.style)
            #expect(implicit.style.stemTechnique == nil)
            switch (implicit.plan, explicit.plan) {
            case (.crossfade(let d1, let o1, let i1), .crossfade(let d2, let o2, let i2)):
                #expect(d1 == d2 && o1 == o2 && i1 == i2)
            case (.beatMatched(let a), .beatMatched(let b)):
                #expect(a.outPoint == b.outPoint && a.inPoint == b.inPoint)
                #expect(a.overlapBars == b.overlapBars)
                #expect(a.overlapDuration == b.overlapDuration)
                #expect(a.outgoingRate == b.outgoingRate && a.incomingRate == b.incomingRate)
                #expect(a.bassSwapOffset == b.bassSwapOffset)
            case (.gapless, .gapless):
                break
            default:
                Issue.record("plan kind changed between omitted and explicit .none")
            }
        }
    }

    /// The headline rule: the vocal clash that used to cut a crossfade to
    /// `vocalClashFadeCap` becomes a technique instead, and the overlap the
    /// energy shapes earned is kept.
    @Test func vocalClashUpgradesToADuckAndKeepsTheLongOverlap() {
        let (outgoing, incoming) = clashingVocalPair()
        guard case .crossfade(let capped, _, _) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming).plan else {
            Issue.record("expected a crossfade")
            return
        }
        #expect(capped <= TransitionPlanner.vocalClashFadeCap)

        let ducked = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                            stems: .ready)
        guard case .crossfade(let full, let outPoint, _) = ducked.plan else {
            Issue.record("expected a crossfade")
            return
        }
        #expect(full == 18)                       // the uncapped, energy-derived length
        #expect(outPoint == 150)                  // a phrase boundary that is being sung
        #expect(ducked.style.stemTechnique
                == .vocalDuck(depthDB: -Float(TransitionPlanner.Config.standard.stemDuckDepthDB)))
        // Composition: the technique layers under the style, it does not replace it.
        #expect(ducked.style.outroEffect == .fade)
        #expect(ducked.style.stagedEQ)
    }

    /// Same rule on the beat-matched path: the 8-bar upgrade the vocal gate
    /// refused is granted, because the clash is now handled rather than avoided.
    @Test func duckRestoresTheLongBeatMatchedOverlap() {
        let outgoing = makeAnalysis(
            bpm: 120, vocalActivity: vocalEnvelope(duration: 200, hot: 140..<200))
        let incoming = makeAnalysis(
            bpm: 124, introEnd: 2, vocalActivity: vocalEnvelope(duration: 200, hot: 0..<40))
        guard case .beatMatched(let short) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming).plan else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(short.overlapBars == 4)

        let ducked = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                            stems: .ready)
        guard case .beatMatched(let long) = ducked.plan else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(long.overlapBars == 8)
        #expect(long.outPoint == 150)
        #expect(ducked.style.stemTechnique
                == .vocalDuck(depthDB: -Float(TransitionPlanner.Config.standard.stemDuckDepthDB)))
        #expect(ducked.style.stagedEQ)            // still the staged hand-over underneath
    }

    /// A sung outgoing tail over an instrumental-leaning opening, at the one
    /// tier that licenses a full blend, is what `acapellaOver` is for.
    @Test func vocalTailOverAnInstrumentalOpeningEarnsAcapella() {
        let outgoing = makeAnalysis(
            bpm: 120, confidence: 0.3,
            vocalActivity: vocalEnvelope(duration: 200, hot: 130..<200))
        // Incoming sings from 40 s on, so its opening reads well below its own
        // mean — 0.26 against the 0.90 ceiling.
        let incoming = makeAnalysis(
            bpm: 120, confidence: 0.3, rmsEnvelope: slowBuildEnvelope(), introEnd: 2,
            vocalActivity: vocalEnvelope(duration: 200, hot: 40..<200))
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             stems: .ready)
        guard case .crossfade(let fade, let outPoint, _) = planned.plan else {
            Issue.record("expected a crossfade")
            return
        }
        #expect(planned.style.stemTechnique == .acapellaOver)
        #expect(outPoint == 150)
        #expect(fade == 18)
    }

    /// The corpus's real problem: the plain out-point search pins the hand-over
    /// to the outro fade, where there is no vocal left to work on. The stem
    /// search must land before it.
    @Test func stemSearchLandsBeforeTheOutroFadePin() {
        let outgoing = makeAnalysis(
            bpm: 120, confidence: 0.3, outroFadeStart: 160,
            vocalActivity: vocalEnvelope(duration: 200, hot: 130..<200))
        let incoming = makeAnalysis(
            bpm: 120, confidence: 0.3, rmsEnvelope: slowBuildEnvelope(), introEnd: 2,
            vocalActivity: vocalEnvelope(duration: 200, hot: 40..<200))
        guard case .crossfade(_, let pinned, _) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming).plan,
              case .crossfade(_, let reaimed, _) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming, stems: .ready).plan
        else {
            Issue.record("expected crossfades")
            return
        }
        #expect(pinned == 160)                    // the outro fade
        #expect(reaimed == 150)                   // the last sung phrase boundary before it
    }

    /// A vocal-heavy incoming opening is a ducking case, never an acapella one:
    /// floating one lead over another is the thing the whole gate exists to stop.
    @Test func aSingingIncomingNeverGetsAcapella() {
        let (outgoing, incoming) = clashingVocalPair()
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             stems: .ready)
        #expect(planned.style.stemTechnique != .acapellaOver)
    }

    /// Acapella is a compatible-tier technique — its separation residue is the
    /// one that is genuinely exposed (S1 §4).
    @Test func acapellaIsRefusedBelowTheCompatibleTier() {
        let outgoing = makeAnalysis(
            bpm: 120, confidence: 0.3, melProfile: Self.defaultProfile,
            vocalActivity: vocalEnvelope(duration: 200, hot: 130..<200))
        let incoming = makeAnalysis(
            bpm: 120, confidence: 0.3, rmsEnvelope: slowBuildEnvelope(), introEnd: 2,
            melProfile: Self.profile(distance: 0.35),        // → neutral tier
            vocalActivity: vocalEnvelope(duration: 200, hot: 40..<200))
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             stems: .ready)
        #expect(planned.style.stemTechnique == nil)
    }

    /// Nothing to sing over the hand-over, nothing for a stem technique to do.
    @Test func anInstrumentalTailDeclinesEveryStemTechnique() {
        // Vocals finish long before any tail-window boundary.
        let outgoing = makeAnalysis(
            bpm: 120, confidence: 0.3,
            vocalActivity: vocalEnvelope(duration: 200, hot: 10..<80))
        let incoming = makeAnalysis(
            bpm: 120, confidence: 0.3, rmsEnvelope: slowBuildEnvelope(), introEnd: 2,
            vocalActivity: vocalEnvelope(duration: 200, hot: 0..<40))
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             stems: .ready)
        #expect(planned.style.stemTechnique == nil)
    }

    /// `stemMinOverlap` is the "is this worth a separation pass" gate: raise it
    /// past the overlap and the pair falls all the way back to the whole-mix
    /// decision, vocal cap included.
    @Test func aShortOverlapIsNotWorthASeparationPass() {
        let (outgoing, incoming) = clashingVocalPair()
        var strict = TransitionPlanner.Config.standard
        strict.stemMinOverlap = 25
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             stems: .ready, config: strict)
        guard case .crossfade(let fade, let outPoint, _) = planned.plan else {
            Issue.record("expected a crossfade")
            return
        }
        #expect(planned.style.stemTechnique == nil)
        #expect(fade <= strict.vocalClashFadeCap)
        #expect(outPoint == 150)
    }

    /// `instrumentalOut` never won a pair in S1's blind test, so the planner
    /// never asks for it — it stays a hand-picked technique.
    @Test func instrumentalOutIsNeverChosenAutomatically() {
        let fixtures: [(TrackAnalysis, TrackAnalysis)] = [
            clashingVocalPair(),
            clashingVocalPair(confidence: 0.9, incomingBPM: 124),
            (makeAnalysis(bpm: 120, confidence: 0.3,
                          vocalActivity: vocalEnvelope(duration: 200, hot: 130..<200)),
             makeAnalysis(bpm: 120, confidence: 0.3, rmsEnvelope: slowBuildEnvelope(),
                          introEnd: 2,
                          vocalActivity: vocalEnvelope(duration: 200, hot: 40..<200))),
            (makeAnalysis(bpm: 120), makeAnalysis(bpm: 124, introEnd: 2)),
        ]
        for (outgoing, incoming) in fixtures {
            let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                                 stems: .ready)
            #expect(planned.style.stemTechnique != .instrumentalOut)
        }
    }

    /// A track with no vocal contour at all must not crash or invent a
    /// technique — absence of evidence is not a vocal.
    @Test func missingVocalContoursNeverEarnAStemTechnique() {
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, confidence: 0.3),
            incoming: makeAnalysis(bpm: 120, confidence: 0.3, introEnd: 2),
            stems: .ready)
        #expect(planned.style.stemTechnique == nil)
    }

    // MARK: - Rule 3: gapless

    @Test func nilOutgoingIsGapless() {
        guard case .gapless = planOnly(
            outgoing: nil, incoming: makeAnalysis()) else {
            Issue.record("expected gapless")
            return
        }
    }

    @Test func nilIncomingIsGapless() {
        guard case .gapless = planOnly(
            outgoing: makeAnalysis(), incoming: nil) else {
            Issue.record("expected gapless")
            return
        }
    }

    @Test func shortTrackIsGapless() {
        let short = makeAnalysis(duration: 40, phraseBoundaries: [20])
        guard case .gapless = planOnly(
            outgoing: short, incoming: makeAnalysis()) else {
            Issue.record("expected gapless for a <45 s track")
            return
        }
        guard case .gapless = planOnly(
            outgoing: makeAnalysis(), incoming: short) else {
            Issue.record("expected gapless for a <45 s track")
            return
        }
    }

    // MARK: - Config

    /// The flat constants the rest of the codebase reads must stay exactly
    /// `Config.standard`'s fields — the promotion to a struct is not allowed
    /// to have moved a shipped number.
    @Test func standardConfigMatchesTheShippedConstants() {
        let c = TransitionPlanner.Config.standard
        #expect(c.minTrackDuration == TransitionPlanner.minTrackDuration)
        #expect(c.bpmConfidenceThreshold == TransitionPlanner.bpmConfidenceThreshold)
        #expect(c.maxBPMDeltaRatio == TransitionPlanner.maxBPMDeltaRatio)
        #expect(c.maxRateDeviation == TransitionPlanner.maxRateDeviation)
        #expect(c.stableCV == TransitionPlanner.stableCV)
        #expect(c.maxOverlap == TransitionPlanner.maxOverlap)
        #expect(c.minOverlap == TransitionPlanner.minOverlap)
        #expect(c.maxOverlapShare == TransitionPlanner.maxOverlapShare)
        #expect(c.tailStableCV == TransitionPlanner.tailStableCV)
        #expect(c.neutralLoudnessDB == 3.0)
        #expect(c.clashLoudnessDB == 6.5)
        #expect(c.neutralTimbreDistance == 0.25)
        #expect(c.clashTimbreDistance == 0.45)
        #expect(c.clashTempoRatio == 0.2)
        #expect(c.neutralOverlapCap == 6)
        #expect(c.clashOverlapCap == 2.5)
        #expect(c.keyConfidenceThreshold == 0.5)
        #expect(c.clashKeyDistance == 3)
        #expect(c.vocalClashRatio == 1.1)
        #expect(c.vocalClashFadeCap == 4)
        #expect(c.stemVocalActiveRatio == 1.15)
        #expect(c.stemAcapellaIncomingVocalMax == 0.90)
        #expect(c.stemMinOverlap == 5)
        #expect(c.stemDuckDepthDB == 9)
        // The two rules must stay disjoint: an incoming opening cannot be both
        // quiet enough to float over and hot enough to duck against.
        #expect(c.stemAcapellaIncomingVocalMax < c.vocalClashRatio)
        // And "vocal-active enough for a stem technique" must be a stricter bar
        // than "loud enough to clash".
        #expect(c.stemVocalActiveRatio > c.vocalClashRatio)
    }

    /// Omitting `config:` must be indistinguishable from passing `.standard`.
    @Test func omittingConfigIsTheStandardConfig() {
        let outgoing = makeAnalysis(melProfile: Self.profile(distance: 0.3))
        let incoming = makeAnalysis()
        let implicit = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming)
        let explicit = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                              config: .standard)
        guard case .crossfade(let d1, let o1, let i1) = implicit.plan,
              case .crossfade(let d2, let o2, let i2) = explicit.plan else {
            Issue.record("expected crossfades")
            return
        }
        #expect(d1 == d2 && o1 == o2 && i1 == i2)
        #expect(implicit.style == explicit.style)
    }

    /// Moving the timbre clash line down must actually re-tier a pair that
    /// sits between the old and new line — this is the console's whole point.
    @Test func loweringTheTimbreClashLineDemotesAPair() {
        let outgoing = makeAnalysis(melProfile: Self.profile(distance: 0.35))
        let incoming = makeAnalysis()

        #expect(TransitionPlanner.compatibility(outgoing: outgoing, incoming: incoming)
                == .neutral)

        var strict = TransitionPlanner.Config.standard
        strict.clashTimbreDistance = 0.30
        #expect(TransitionPlanner.compatibility(outgoing: outgoing, incoming: incoming,
                                                config: strict) == .clash)

        // …and the plan follows the tier: the clash cap shortens the overlap.
        guard case .crossfade(let wide, _, _) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming).plan,
              case .crossfade(let tight, _, _) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming, config: strict).plan
        else {
            Issue.record("expected crossfades")
            return
        }
        #expect(wide == TransitionPlanner.neutralOverlapCap)
        #expect(tight <= strict.clashOverlapCap)
    }

    /// A widened beat-match window lets a pair that just missed the tempo
    /// gate through — the knob reaches the beat-matching path too.
    @Test func wideningTheBeatMatchWindowAdmitsAPair() {
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 132)     // 10 % apart: over the 8 % line
        guard case .crossfade = planOnly(outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected a crossfade at the shipped 8 % window")
            return
        }
        var loose = TransitionPlanner.Config.standard
        loose.maxBPMDeltaRatio = 0.12
        loose.maxRateDeviation = 0.06
        guard case .beatMatched = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming, config: loose).plan else {
            Issue.record("expected a beat-match once the window opens to 12 %")
            return
        }
    }

    /// `standard(overriding:)` is the console's entry point: unknown names
    /// are ignored and out-of-range values clamp, so a stale saved preset can
    /// never produce a config the planner would choke on.
    @Test func configOverridesAreNamedClampedAndForgiving() {
        let c = TransitionPlanner.Config.standard(overriding: [
            "clashTimbreDistance": 0.31,
            "neutralLoudnessDB": -50,          // below the field's min
            "notAKnob": 7,                     // stale preset entry
        ])
        #expect(c.clashTimbreDistance == 0.31)
        #expect(c.neutralLoudnessDB == 0)      // clamped to the field min
        #expect(c.clashLoudnessDB == TransitionPlanner.clashLoudnessDB)

        let diff = c.diffFromStandard.map(\.name).sorted()
        #expect(diff == ["clashTimbreDistance", "neutralLoudnessDB"])
        #expect(TransitionPlanner.Config.standard(overriding: [:]) == .standard)
        #expect(TransitionPlanner.Config.standard.diffFromStandard.isEmpty)
    }

    /// Every field the console shows must round-trip through the dictionary
    /// the browser posts back, or a slider would silently do nothing.
    @Test func everyFieldRoundTripsThroughTheOverrideDictionary() {
        let fields = TransitionPlanner.Config.fields
        #expect(!fields.isEmpty)
        for field in fields {
            let probe = (field.read(.standard) + field.step * 3)
                .clamped(to: field.min...field.max)
            guard abs(probe - field.read(.standard)) > 1e-9 else { continue }
            let c = TransitionPlanner.Config.standard(overriding: [field.name: probe])
            #expect(abs(field.read(c) - probe) <= max(1e-9, field.step),
                    "\(field.name) did not take \(probe)")
            #expect(c.asDictionary[field.name] != nil, "\(field.name) missing from asDictionary")
            #expect(field.min < field.max, "\(field.name) has an empty range")
            #expect(field.read(.standard) >= field.min && field.read(.standard) <= field.max,
                    "\(field.name)'s shipped value sits outside its own slider range")
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
