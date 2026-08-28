import Testing
@testable import KumoneCore
import Foundation

// The four approved loosenings, and the one principle behind all of them: a
// gate is only as tight as the risk it is holding back, so when a technique
// absorbs that risk the gate has to be re-priced or it is just superstition.
//
//   - the ride's cut side, because a cut is free of everything a boost costs;
//   - the neutral overlap cap, because it was priced for cue points the
//     structure layer replaced;
//   - the steadiness bar inside a single section, because the CV was a proxy
//     for a thing structure now measures directly;
//   - the ramped bend cap, because the pair of tempo caps has to be internally
//     consistent to mean anything.
//
// Each knob is also tested *off*, because "the old behaviour is one field
// away" is the property that makes any of this safe to ship.

@Suite struct AdmissionGateTests {

    // MARK: - Fixtures

    private func makeAnalysis(
        bpm: Double = 120,
        duration: TimeInterval = 200,
        rmsEnvelope: [Float]? = nil,
        referenceLoudness: Double? = nil,
        peakDBFS: Double? = -6,
        sections: [TrackAnalysis.Section] = [],
        structureConfidence: Double = 0.8
    ) -> TrackAnalysis {
        let barLength = 4 * 60 / bpm
        var a = TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: bpm, bpmConfidence: 0.9,
            beats: stride(from: 0.4, to: duration, by: 60 / bpm).map { $0 },
            downbeats: stride(from: 0.4, to: duration, by: barLength).map { $0 },
            phraseBoundaries: [150, 90, 30],
            rmsEnvelope: rmsEnvelope ?? [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil, introEnd: 2, duration: duration,
            melProfile: [], keyPitchClass: nil, keyIsMinor: false, keyConfidence: 0,
            vocalActivity: [], referenceLoudness: referenceLoudness, peakDBFS: peakDBFS)
        a.sections = sections
        a.structureConfidence = structureConfidence
        return a
    }

    private func section(_ kind: TrackAnalysis.Section.Kind,
                         _ start: TimeInterval, _ end: TimeInterval)
    -> TrackAnalysis.Section {
        TrackAnalysis.Section(start: start, end: end, kind: kind, repetition: 2,
                              energy: 0.7, vocalDensity: 1)
    }

    /// An envelope that wobbles hard enough to fail 0.40 and clear 0.50.
    /// ±22 % square wave: CV is exactly the amplitude ratio, so this is 0.44.
    private func wobbly(_ count: Int, ratio: Float = 0.44) -> [Float] {
        (0..<count).map { $0 % 2 == 0 ? 0.5 * (1 - ratio) : 0.5 * (1 + ratio) }
    }

    // MARK: - 1. Asymmetric ride cap

    /// The two directions are no longer the same number, and the gate sees the
    /// difference. A −6 dB seam is now ridden shut; a +6 dB one is not.
    @Test func theRideCutsDeeperThanItBoosts() {
        let c = TransitionPlanner.Config.standard
        #expect(c.rideMaxCutDB == 6)
        #expect(c.rideMaxDB == 4)
        let roomy = makeAnalysis(peakDBFS: -30)

        // Exactly at the new cut cap: taken in full, where the old shared cap
        // would have left 2 dB on the table.
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: -6, incoming: roomy,
                                         incomingTrimDB: 0, config: c) == -6)
        // Past it: clipped at the cut cap, not the boost one.
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: -9, incoming: roomy,
                                         incomingTrimDB: 0, config: c) == -6)
        // The boost side is untouched: still 4, still peak-guarded on top.
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: 6, incoming: roomy,
                                         incomingTrimDB: 0, config: c) == 4)
        let hot = makeAnalysis(peakDBFS: -1)
        let boosted = TransitionPlanner.rideDB(forTrimmedGapDB: 6, incoming: hot,
                                               incomingTrimDB: 0, config: c)
        #expect(boosted < 4, "a hot master's headroom must still bite before the cap")
        #expect(boosted >= 0)
    }

    /// `rideMaxDB` is the feature's off switch for *both* directions — a config
    /// that said "no ride" but still cut 6 dB would be a trap.
    @Test func zeroRideMaxTurnsBothDirectionsOff() {
        var off = TransitionPlanner.Config.standard
        off.rideMaxDB = 0
        let roomy = makeAnalysis(peakDBFS: -30)
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: -9, incoming: roomy,
                                         incomingTrimDB: 0, config: off) == 0)
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: 9, incoming: roomy,
                                         incomingTrimDB: 0, config: off) == 0)
        // …and so does turning compensation off, which is the user-facing one.
        var uncompensated = TransitionPlanner.Config.standard
        uncompensated.loudnessCompensation = false
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: -9, incoming: roomy,
                                         incomingTrimDB: 0, config: uncompensated) == 0)
    }

    /// The payoff, at the gate rather than at the knob: a 6 dB seam in the
    /// direction the ride can absorb is a compatible pair now, and was a
    /// demoted one when the cut shared the boost's 4 dB cap.
    @Test func aSixDBCutSeamIsNoLongerDemoted() {
        let quietTail = [Float](repeating: 0.5 * 0.501, count: 200)   // −6 dB
        let loudOpening = [Float](repeating: 0.5, count: 200)
        let outgoing = makeAnalysis(rmsEnvelope: quietTail, referenceLoudness: -14)
        let incoming = makeAnalysis(rmsEnvelope: loudOpening, referenceLoudness: -14)

        let now = TransitionPlanner.signals(outgoing: outgoing, incoming: incoming)
        #expect(now.loudnessGapDB < 0.3)
        #expect(TransitionPlanner.tier(of: now) == .compatible)

        var oldCaps = TransitionPlanner.Config.standard
        oldCaps.rideMaxCutDB = 4
        let before = TransitionPlanner.signals(outgoing: outgoing, incoming: incoming,
                                               config: oldCaps)
        #expect(abs(before.rideDB - -4) < 1e-6)
        #expect(before.loudnessGapDB > 1.5, "the old cap left ~2 dB for the gate to judge")
    }

    // MARK: - 2. Neutral overlap cap

    @Test func theNeutralCapIsTenSecondsAndTheClashCapIsUnchanged() {
        let c = TransitionPlanner.Config.standard
        #expect(c.neutralOverlapCap == 10)
        #expect(c.clashOverlapCap == 2.5)
        #expect(c.neutralOverlapCap > c.clashOverlapCap)
    }

    /// A neutral pair whose audio supports a long blend now gets up to 10 s of
    /// it. The cap has to be what actually binds for this to mean anything, so
    /// the fixture is built with plenty of tail and intake capacity.
    @Test func aNeutralPairMayNowBlendForTenSeconds() {
        // Far enough apart in timbre to be neutral, not far enough to clash.
        let outgoing = makeAnalysis(referenceLoudness: -14)
        // An 8 s build into a steady body: intake capacity is the climb plus
        // `intakeBodySeconds`, so it clears 10 s and the tier cap is what
        // actually binds. (A flat opening caps the fade at 8 s on intake alone
        // and would hide the knob entirely.)
        let incoming = makeAnalysis(
            rmsEnvelope: (0..<200).map { min(0.5, 0.05 + Float($0) * 0.056) },
            referenceLoudness: -14)

        func overlap(cap: TimeInterval) -> TimeInterval? {
            var config = TransitionPlanner.Config.standard
            config.neutralOverlapCap = cap
            // Force the neutral tier and nothing worse: any timbre distance is
            // "not very alike", none of them is a clash.
            config.neutralTimbreDistance = -1
            config.clashTimbreDistance = 2
            config.clashLoudnessDB = 60
            guard case .crossfade(let d, _, _) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming, config: config).plan
            else { return nil }
            return d
        }
        guard let wide = overlap(cap: 10), let old = overlap(cap: 6) else {
            Issue.record("expected crossfades on both configs")
            return
        }
        #expect(old <= 6.0001)
        #expect(wide > old, "the raised cap must actually buy length")
        #expect(wide <= 10.0001)
    }

    // MARK: - 3. Section-aware steadiness

    /// A window that wobbles past the 0.40 bar but sits wholly inside one
    /// labelled section clears the looser 0.50 one — and the ledger says which
    /// bar it was judged against, so two seams with different numbers are
    /// tellable apart.
    @Test func aSingleSectionWindowGetsTheLooserSteadinessBar() throws {
        // One long chorus covering the whole overlap window at 150 s.
        let sections = [section(.intro, 0, 30), section(.verse, 30, 120),
                        section(.chorus, 120, 190), section(.outro, 190, 200)]
        let outgoing = makeAnalysis(rmsEnvelope: wobbly(200), sections: sections)
        let incoming = makeAnalysis(rmsEnvelope: wobbly(200), sections: sections)

        var trace: PlanTrace? = PlanTrace()
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             trace: &trace)
        guard case .beatMatched(let plan) = planned.plan else {
            Issue.record("expected beatMatched")
            return
        }
        // 0.44 fails 0.40 and clears 0.50, so the upgrade only happens under
        // the section rule.
        #expect(plan.overlapBars > 4)
        let gate = try #require(
            trace?.gates.last { $0.id.hasSuffix(".stableOut") && $0.passed })
        #expect(gate.threshold == TransitionPlanner.Config.standard.sectionSteadyCV)
        #expect(gate.detail.contains("single-section window"))
        #expect(gate.detail.contains("0.50"))
    }

    /// The same audio with no sections is judged exactly as it was: the rule is
    /// unreachable without structure, which is most of the library.
    @Test func withoutSectionsTheOldBarApplies() throws {
        let outgoing = makeAnalysis(rmsEnvelope: wobbly(200))
        let incoming = makeAnalysis(rmsEnvelope: wobbly(200))
        var trace: PlanTrace? = PlanTrace()
        _ = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming, trace: &trace)
        let gate = try #require(trace?.gates.last { $0.id.hasSuffix(".stableOut") })
        #expect(gate.threshold == TransitionPlanner.Config.standard.stableCV)
        #expect(!gate.detail.contains("single-section"))
        #expect(gate.detail.contains("0.40"))
    }

    /// A window that *straddles* a section boundary gets no relief — crossing
    /// an arrangement change is exactly what the CV was there to catch, and the
    /// structure evidence says this window does cross one.
    @Test func aWindowStraddlingABoundaryKeepsTheStrictBar() throws {
        // Boundaries chopped so that any 8- or 16-bar window at the tail
        // candidates crosses one.
        let chopped = stride(from: 0.0, to: 200.0, by: 6.0).map {
            section(.verse, $0, $0 + 6)
        }
        let outgoing = makeAnalysis(rmsEnvelope: wobbly(200), sections: chopped)
        let incoming = makeAnalysis(rmsEnvelope: wobbly(200), sections: chopped)
        var trace: PlanTrace? = PlanTrace()
        _ = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming, trace: &trace)
        let gate = try #require(trace?.gates.last { $0.id.hasSuffix(".stableOut") })
        #expect(gate.threshold == TransitionPlanner.Config.standard.stableCV)
        #expect(!gate.detail.contains("single-section"))
    }

    /// The rule relaxes, it never vetoes: a genuinely lurching window inside
    /// one section is still refused.
    @Test func theSectionRuleStillRefusesALurchingWindow() {
        let sections = [section(.chorus, 0, 200)]
        // CV 0.8 — past even the looser bar.
        let outgoing = makeAnalysis(rmsEnvelope: wobbly(200, ratio: 0.8), sections: sections)
        let incoming = makeAnalysis(rmsEnvelope: wobbly(200, ratio: 0.8), sections: sections)
        guard case .beatMatched(let plan) = TransitionPlanner
            .plan(outgoing: outgoing, incoming: incoming).plan else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(plan.overlapBars == 4, "no upgrade for a window that really does lurch")
    }

    /// Turning the knob down to `stableCV` reproduces the pre-rule planner
    /// field for field, sections or no sections.
    @Test func matchingTheKnobsDisablesTheSectionRule() {
        let sections = [section(.chorus, 0, 200)]
        let outgoing = makeAnalysis(rmsEnvelope: wobbly(200), sections: sections)
        let incoming = makeAnalysis(rmsEnvelope: wobbly(200), sections: sections)
        var off = TransitionPlanner.Config.standard
        off.sectionSteadyCV = off.stableCV
        guard case .beatMatched(let withRule) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming).plan,
              case .beatMatched(let without) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming, config: off).plan
        else {
            Issue.record("expected two beat-matched plans")
            return
        }
        #expect(withRule.overlapBars > without.overlapBars)
        #expect(without.overlapBars == 4)
    }

    // MARK: - 4. Ramped bend cap

    /// 6.5 % admits the corpus's near-miss (a 133.3 → 118.0 seam needing
    /// 6.48 %), and the gap window is unchanged around it.
    @Test func theBendCapAdmitsTheNearMiss() {
        let c = TransitionPlanner.Config.standard
        #expect(c.rampMaxRateDeviation == 0.065)
        #expect(c.rampMaxBPMDeltaRatio == 0.115)

        guard case .beatMatched(let plan) = TransitionPlanner
            .plan(outgoing: makeAnalysis(bpm: 133.3),
                  incoming: makeAnalysis(bpm: 118.0)).plan else {
            Issue.record("expected the near-miss seam to beat-match now")
            return
        }
        let bend = abs(Double(plan.incomingRate) - 1)
        #expect(bend > 0.06 && bend <= 0.065,
                "the seam needs the extra half percent (\(bend))")

        // The same seam under the old cap is refused, so this is the knob.
        var old = TransitionPlanner.Config.standard
        old.rampMaxRateDeviation = 0.06
        if case .beatMatched = TransitionPlanner
            .plan(outgoing: makeAnalysis(bpm: 133.3),
                  incoming: makeAnalysis(bpm: 118.0), config: old).plan {
            Issue.record("the old cap must still refuse it")
        }
    }

    /// The gap window itself did not move: 10 % in, 12 % out, as before.
    @Test func theGapWindowIsUnchangedByTheBendCap() {
        if case .beatMatched = TransitionPlanner
            .plan(outgoing: makeAnalysis(bpm: 120), incoming: makeAnalysis(bpm: 132)).plan {
        } else {
            Issue.record("10 % apart must still beat-match")
        }
        if case .beatMatched = TransitionPlanner
            .plan(outgoing: makeAnalysis(bpm: 120), incoming: makeAnalysis(bpm: 134.4)).plan {
            Issue.record("12 % apart must still be refused")
        }
    }

    /// The two tempo caps are consistent by construction: nothing inside the
    /// gap window can fail the bend window. Checked by sweeping the window
    /// rather than asserted, because it is the kind of claim that quietly stops
    /// being true when someone moves one of the two numbers.
    @Test func insideTheGapWindowTheBendCapNeverBites() {
        let c = TransitionPlanner.Config.standard
        for step in 0...230 {
            let d = Double(step) / 2000.0        // 0 … 0.115
            guard d <= c.rampMaxBPMDeltaRatio else { continue }
            for folded in [100.0 * (1 - d), 100.0 * (1 + d)] {
                let target = (100.0 + folded) / 2
                let bend = max(abs(target / 100.0 - 1), abs(target / folded - 1))
                #expect(bend <= c.rampMaxRateDeviation + 1e-9,
                        "gap \(d) needs a \(bend) bend, past the cap")
            }
        }
    }
}
