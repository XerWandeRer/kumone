import Testing
@testable import KumoneCore
import Foundation

// The AutoMix debug panel's mapping layer. The window itself cannot be tested
// here, but everything it *prints* is a pure function of a `PlannedTransition`
// and the two analyses it came from — including the one judgement the panel
// makes on its own, "did the engine run what it was handed".
@Suite struct AutoMixDebugModelTests {

    // MARK: - Fixtures

    private func analysis(
        duration: TimeInterval = 200,
        introEnd: TimeInterval = 8,
        phraseBoundaries: [TimeInterval] = [150, 90, 30],
        sections: [TrackAnalysis.Section] = [],
        keyPitchClass: Int? = nil,
        keyIsMinor: Bool = false,
        keyConfidence: Double = 0
    ) -> TrackAnalysis {
        var a = TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: 120, bpmConfidence: 0.9,
            beats: stride(from: 0.0, to: duration, by: 0.5).map { $0 },
            downbeats: stride(from: 0.0, to: duration, by: 2).map { $0 },
            phraseBoundaries: phraseBoundaries,
            rmsEnvelope: [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil, introEnd: introEnd, duration: duration,
            melProfile: [],
            keyPitchClass: keyPitchClass, keyIsMinor: keyIsMinor,
            keyConfidence: keyConfidence,
            vocalActivity: [],
            referenceLoudness: -9.5, peakDBFS: -1)
        a.sections = sections
        a.structureConfidence = sections.isEmpty ? 0 : 0.8
        return a
    }

    private func section(_ kind: TrackAnalysis.Section.Kind,
                         _ start: TimeInterval, _ end: TimeInterval,
                         repetition: Int = 1) -> TrackAnalysis.Section {
        TrackAnalysis.Section(start: start, end: end, kind: kind,
                              repetition: repetition, energy: 0.7, vocalDensity: 1)
    }

    // MARK: - Plan flattening

    @Test func beatMatchedPlanCarriesBarsAndRates() {
        let planned = PlannedTransition(
            plan: .beatMatched(BeatMatchedPlan(
                outPoint: 150, inPoint: 8, overlapBars: 8,
                outgoingRate: 1.01, incomingRate: 0.99,
                bassSwapOffset: 8, overlapDuration: 16)),
            style: TransitionStyle(outroEffect: .filterSweep, stagedEQ: true,
                                   stemTechnique: .vocalDuck(depthDB: -9)),
            rideDB: -1.5)
        let outgoing = analysis(sections: [section(.chorus, 130, 170, repetition: 3)])
        let plan = AutoMixDebugPlan(planned: planned, outgoing: outgoing,
                                    incoming: analysis(introEnd: 8))

        #expect(plan.kind == "beatMatched")
        #expect(plan.outPoint == 150)
        #expect(plan.inPoint == 8)
        #expect(plan.overlap == 16)
        #expect(plan.overlapBars == 8)
        #expect(plan.outgoingRate == 1.01)
        #expect(plan.outroEffect == "filterSweep")
        #expect(plan.stagedEQ)
        #expect(plan.stemTechnique == "vocalDuck(-9.0dB)")
        #expect(plan.rideDB == -1.5)
        // The out point sits inside the final chorus, and the panel says so.
        #expect(plan.outSection?.hasPrefix("chorus") == true)
        #expect(plan.inPointSource == "introEnd")
    }

    @Test func gaplessPlanHasNoGeometry() {
        let plan = AutoMixDebugPlan(planned: .plain(.gapless), outgoing: nil, incoming: nil)
        #expect(plan.kind == "gapless")
        #expect(plan.outPoint == nil)
        #expect(plan.inPoint == nil)
        #expect(plan.overlap == 0)
        #expect(plan.outSection == nil)
    }

    @Test func structurelessOutgoingReportsNoSection() {
        let planned = PlannedTransition.plain(
            .crossfade(duration: 6, outPoint: 150, inPoint: 0))
        let plan = AutoMixDebugPlan(planned: planned, outgoing: analysis(),
                                    incoming: analysis())
        #expect(plan.outSection == nil)
        #expect(plan.inPointSource == "track start")
    }

    // MARK: - In-point provenance

    @Test func inPointMatchesSectionStartAndPhraseBoundary() {
        let incoming = analysis(sections: [section(.verse, 40, 80)])
        #expect(AutoMixDebugFormat.inPointSource(40, incoming: incoming)
                == "section start (verse)")
        #expect(AutoMixDebugFormat.inPointSource(90, incoming: incoming) == "phrase boundary")
        // On the beat grid but none of the named landmarks.
        #expect(AutoMixDebugFormat.inPointSource(52, incoming: incoming) == "downbeat")
        #expect(AutoMixDebugFormat.inPointSource(52.3, incoming: incoming) == "free")
        #expect(AutoMixDebugFormat.inPointSource(40, incoming: nil) == nil)
    }

    // MARK: - Fallback detection

    @Test func identicalPlanIsNoFallback() {
        let planned = PlannedTransition.plain(
            .crossfade(duration: 6, outPoint: 150, inPoint: 0))
        let plan = AutoMixDebugPlan(planned: planned, outgoing: nil, incoming: nil)
        #expect(AutoMixDebugFormat.fallback(
            planned: plan,
            executed: .crossfade(duration: 6, outPoint: 150, inPoint: 0)) == nil)
    }

    @Test func degradedKindIsReported() {
        let planned = PlannedTransition(
            plan: .beatMatched(BeatMatchedPlan(
                outPoint: 150, inPoint: 0, overlapBars: 8,
                outgoingRate: 1, incomingRate: 1,
                bassSwapOffset: 8, overlapDuration: 16)),
            style: .plain)
        let plan = AutoMixDebugPlan(planned: planned, outgoing: nil, incoming: nil)
        let reason = AutoMixDebugFormat.fallback(planned: plan, executed: .gapless)
        #expect(reason == "beatMatched → gapless (out point unreachable)")
    }

    @Test func reAnchoredCrossfadeIsReported() {
        // The engine's own degradation: same kind, shorter, anchored at the end.
        let planned = PlannedTransition.plain(
            .crossfade(duration: 12, outPoint: 150, inPoint: 0))
        let plan = AutoMixDebugPlan(planned: planned, outgoing: nil, incoming: nil)
        let reason = AutoMixDebugFormat.fallback(
            planned: plan, executed: .crossfade(duration: 4, outPoint: 196, inPoint: 0))
        #expect(reason?.hasPrefix("re-anchored:") == true)
    }

    @Test func nothingArmedMeansNothingToCompare() {
        #expect(AutoMixDebugFormat.fallback(planned: nil, executed: .gapless) == nil)
    }

    // MARK: - Field formatting

    @Test func keyReadsAsPitchAndMode() {
        let minor = analysis(keyPitchClass: 6, keyIsMinor: true, keyConfidence: 0.71)
        #expect(AutoMixDebugFormat.key(minor) == "F♯ min (0.71)")
        #expect(AutoMixDebugFormat.key(analysis()) == nil)
    }

    @Test func clockFormatsMinutesAndSeconds() {
        #expect(AutoMixDebugFormat.clock(0) == "0:00")
        #expect(AutoMixDebugFormat.clock(125) == "2:05")
        #expect(AutoMixDebugFormat.clock(nil) == "—")
    }

    // MARK: - Model bookkeeping

    @Test @MainActor func seamHistoryKeepsTheLastThreeNewestFirst() {
        let model = AutoMixDebugModel.shared
        for index in 0..<5 {
            model.recordSeam(AutoMixDebugSeam(
                from: "from \(index)", to: "to \(index)", planned: nil,
                path: "liveOverlap", executedKind: "crossfade",
                executedOutPoint: nil, executedOverlap: 6,
                fallback: nil, prerender: "idle"))
        }
        let seams = model.currentSeamsForTesting
        #expect(seams.count == AutoMixDebugModel.seamHistoryLimit)
        #expect(seams.first?.from == "from 4")
        #expect(seams.last?.from == "from 2")
    }
}
