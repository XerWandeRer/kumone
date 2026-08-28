import Testing
@testable import KumoneCore
import Foundation

// The structure layer (predev §2.3): where out/in point *candidates* come from
// once a track carries `sections`, and what happens on every track that does
// not. Nothing here tests a gate — the gates are the same gates, and
// `TransitionPlannerTests` still pins them; these tests only ask which points
// the unchanged machinery was offered, and in what order.
@Suite struct TransitionPlannerStructureTests {

    // MARK: - Fixtures

    /// A 200 s track at 120 BPM (one bar = 2 s), steady energy, no vocal
    /// contour, and the same three phrase boundaries the older suite uses — so
    /// "structure moved this" is always visible against a known baseline.
    private func makeAnalysis(
        bpm: Double = 120,
        confidence: Double = 0.9,
        duration: TimeInterval = 200,
        phraseBoundaries: [TimeInterval] = [150, 90, 30],
        introEnd: TimeInterval = 2,
        sections: [TrackAnalysis.Section] = [],
        structureConfidence: Double = 0.8
    ) -> TrackAnalysis {
        let barLength = 4 * 60 / bpm
        var a = TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: bpm,
            bpmConfidence: confidence,
            beats: stride(from: 0.4, to: duration, by: 60 / bpm).map { $0 },
            downbeats: stride(from: 0.4, to: duration, by: barLength).map { $0 },
            phraseBoundaries: phraseBoundaries,
            rmsEnvelope: [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil,
            introEnd: introEnd,
            duration: duration,
            // Empty fingerprints read as distance 0, so both fixtures are always
            // the same style and the tier gate never interferes.
            melProfile: [],
            keyPitchClass: nil, keyIsMinor: false, keyConfidence: 0,
            vocalActivity: [],
            referenceLoudness: nil,
            peakDBFS: -6)
        a.sections = sections
        a.structureConfidence = structureConfidence
        return a
    }

    private func section(
        _ kind: TrackAnalysis.Section.Kind, _ start: TimeInterval, _ end: TimeInterval,
        repetition: Int = 1
    ) -> TrackAnalysis.Section {
        TrackAnalysis.Section(start: start, end: end, kind: kind, repetition: repetition,
                              energy: 0.7, vocalDensity: 1)
    }

    /// intro | verse | chorus | verse | **final chorus 130–170** | outro.
    /// The final chorus ends at 170 — well inside the tail window, and 20 s past
    /// the best-scored phrase boundary at 150.
    private var pop: [TrackAnalysis.Section] {
        [section(.intro, 0, 20), section(.verse, 20, 60, repetition: 2),
         section(.chorus, 60, 90, repetition: 2), section(.verse, 90, 130, repetition: 2),
         section(.chorus, 130, 170, repetition: 2), section(.outro, 170, 200)]
    }

    private func outPoint(of plan: TransitionPlan) -> TimeInterval? { plan.outPoint }

    private func inPoint(of plan: TransitionPlan) -> TimeInterval? {
        switch plan {
        case .beatMatched(let p): return p.inPoint
        case .crossfade(_, _, let inPoint): return inPoint
        case .gapless: return nil
        }
    }

    // MARK: - Out point

    /// The end of the final chorus outranks a phrase boundary that scores
    /// better on RMS jump — the whole point of the layer. Same pair, same
    /// gates, same 8-bar overlap; only the seam moves.
    @Test func finalChorusEndOutranksTheBestScoredPhraseBoundary() {
        let incoming = makeAnalysis(bpm: 124)
        let withStructure = TransitionPlanner.plan(
            outgoing: makeAnalysis(sections: pop), incoming: incoming)
        let without = TransitionPlanner.plan(
            outgoing: makeAnalysis(), incoming: incoming)

        guard case .beatMatched(let structured) = withStructure.plan,
              case .beatMatched(let baseline) = without.plan else {
            Issue.record("expected both to beat-match")
            return
        }
        #expect(baseline.outPoint == 150)     // best-scored phrase boundary
        #expect(structured.outPoint == 170)   // the final chorus finishes here
        #expect(structured.overlapBars == baseline.overlapBars)
    }

    /// One knob puts it back, so a listening test can revert exactly this.
    @Test func theOutPointKnobRevertsToPhraseBoundaries() {
        var config = TransitionPlanner.Config.standard
        config.useStructureOutPoints = false
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(sections: pop), incoming: makeAnalysis(bpm: 124),
            config: config)
        #expect(outPoint(of: planned.plan) == 150)
    }

    /// Candidates naming the same moment collapse: the final chorus's end, the
    /// outro's start and (here) a phrase boundary are three names for 170.
    @Test func nearIdenticalCandidatesAreDeduplicated() {
        let a = makeAnalysis(phraseBoundaries: [170.2, 150], sections: pop)
        let candidates = TransitionPlanner.outPointCandidates(
            a, context: .none, config: .standard)
        #expect(candidates.points.filter { abs($0 - 170) < 1 }.count == 1)
        #expect(candidates.points.first == 170)
        #expect(candidates.structuralCount > 0)
    }

    // MARK: - Climax guard

    /// Nothing may be cut in the sixteen bars leading into the final chorus —
    /// the pre-chorus lift, which scores *well* on RMS jump and is the worst
    /// place in the song to send a track away from.
    @Test func theClimaxGuardRejectsCandidatesBeforeTheFinalChorus() {
        // 16 bars at 120 BPM = 32 s, so the window is [98 s, 130 s).
        let a = makeAnalysis(phraseBoundaries: [110, 150], sections: pop)
        let guarded = TransitionPlanner.outPointCandidates(
            a, context: .none, config: .standard)
        #expect(guarded.climaxStart == 130)
        #expect(guarded.guardWindow?.start == 98)
        #expect(guarded.guardWindow?.end == 130)
        #expect(!guarded.points.contains(110))
        #expect(guarded.guardRejected == 1)
        #expect(!guarded.guardFellBack)

        var off = TransitionPlanner.Config.standard
        off.climaxGuardBarsBefore = 0
        #expect(TransitionPlanner.outPointCandidates(a, context: .none, config: off)
            .points.contains(110))
    }

    /// A transition still has to happen: when the guard would leave the search
    /// with nothing at all, the guard is the thing that gives way.
    @Test func theClimaxGuardStandsDownWhenItWouldEmptyTheList() {
        var config = TransitionPlanner.Config.standard
        // A window wide enough to swallow the whole track.
        config.climaxGuardBarsBefore = 100
        config.climaxGuardBarsAfter = 100
        let a = makeAnalysis(sections: pop)
        let guarded = TransitionPlanner.outPointCandidates(a, context: .none, config: config)
        let unguarded = TransitionPlanner.outPointCandidates(
            a, context: .none, config: .standard)
        #expect(guarded.guardFellBack)
        #expect(guarded.guardRejected == unguarded.points.count)
        #expect(guarded.points == unguarded.points)
        #expect(!guarded.points.isEmpty)
    }

    // MARK: - Lyric snapping

    /// Backward only, and never further than the cap: a cut lands on a full
    /// stop or it stays where it was.
    @Test func lyricSnappingPullsCandidatesBackAndNeverForward() {
        let a = makeAnalysis(sections: pop)
        // Line ends just before 90 / 170 / 200, plus one *after* 170 that must
        // be ignored, plus one far behind 130 that is past the cap.
        let context = TransitionPlanner.PlanContext(
            outgoingLyricLineEnds: [10, 50, 88.5, 167.5, 172, 196])
        let snapped = TransitionPlanner.outPointCandidates(
            a, context: context, config: .standard)

        #expect(snapped.points.contains(167.5))
        #expect(!snapped.points.contains(170))
        #expect(snapped.snapOrigin(of: 167.5) == 170)
        #expect(snapped.points.contains(88.5))
        // 172 sits after 170; snapping never reaches forward for it.
        #expect(!snapped.points.contains(172))
        // 130 is 41.5 s past the nearest line end — beyond the cap, so it stays.
        #expect(snapped.points.contains(130))

        // Every point either stayed put or moved earlier.
        for point in snapped.points {
            if let origin = snapped.snapOrigin(of: point) { #expect(point < origin) }
        }

        var noSnap = TransitionPlanner.Config.standard
        noSnap.lyricSnapMaxSeconds = 0
        #expect(TransitionPlanner.outPointCandidates(a, context: context, config: noSnap)
            .points.contains(170))
    }

    /// The snap reaches the plan, not just the candidate list.
    @Test func theChosenOutPointCarriesTheLyricSnap() {
        let context = TransitionPlanner.PlanContext(
            outgoingLyricLineEnds: [10, 50, 88.5, 167.5, 196])
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(sections: pop), incoming: makeAnalysis(bpm: 124),
            context: context)
        #expect(outPoint(of: planned.plan) == 167.5)
    }

    /// The snap grid itself: a line ends when the next one starts, but never
    /// later than twice the median spacing — otherwise the line before an
    /// instrumental break would "end" only when the singer came back, and the
    /// whole break would read as one held line.
    @Test func lyricLineEndsCloseEachLineAndCapTheInstrumentalBreak() {
        let lines = [0.0, 4, 8, 12, 40, 44].map {
            Audition.LyricLine(time: $0, text: "l")
        }
        // Spacings 4, 4, 4, 28, 4 → median 4, cap 8.
        #expect(Audition.Lyrics.lineEnds(lines) == [4, 8, 12, 20, 44, 48])
        #expect(Audition.Lyrics.lineEnds([]).isEmpty)
    }

    // MARK: - In point

    /// The in point is where the song proper starts, not where it first gets
    /// loud. Here the intro runs to 20 s while `introEnd` fires at 2 s.
    @Test func theInPointIsTheFirstCoreSectionStart() {
        let incoming = makeAnalysis(bpm: 160, sections: pop)
        // Far tempos → crossfade, which reads the in point directly.
        let planned = TransitionPlanner.plan(outgoing: makeAnalysis(bpm: 100),
                                             incoming: incoming)
        #expect(inPoint(of: planned.plan) == 20)

        var off = TransitionPlanner.Config.standard
        off.useStructureInPoint = false
        let reverted = TransitionPlanner.plan(outgoing: makeAnalysis(bpm: 100),
                                              incoming: incoming, config: off)
        #expect(inPoint(of: reverted.plan) == 2)
    }

    /// The beat-matched search snaps the same anchor to a downbeat, exactly as
    /// it always snapped `introEnd`.
    @Test func theBeatMatchedInPointSnapsTheStructuralAnchorToADownbeat() {
        let incoming = makeAnalysis(bpm: 124, sections: pop)
        let planned = TransitionPlanner.plan(outgoing: makeAnalysis(), incoming: incoming)
        // The intro section ends at 20 s; the plan enters on the first downbeat
        // at or after it, not on the raw section start.
        let expected = incoming.downbeats.first { $0 >= 20 - 0.05 }
        #expect(inPoint(of: planned.plan) == expected)
        #expect((expected ?? 0) > 20 - 0.05)
        #expect((expected ?? 0) < 22)
    }

    /// A mislabelled "first verse" a minute and a half in must not skip that
    /// much of the song: outside the sanity clamp the planner takes `introEnd`.
    @Test func aFarAwayFirstCoreSectionFallsBackToIntroEnd() {
        let mislabelled = [section(.intro, 0, 100), section(.verse, 100, 160),
                           section(.outro, 160, 200)]
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 100),
            incoming: makeAnalysis(bpm: 160, sections: mislabelled))
        #expect(inPoint(of: planned.plan) == 2)   // introEnd, not 100
    }

    /// Below the planner's own confidence re-gate the sections are ignored on
    /// both sides at once.
    @Test func lowStructureConfidenceIsIgnoredEntirely() {
        let incoming = makeAnalysis(bpm: 124, sections: pop, structureConfidence: 0.1)
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(sections: pop, structureConfidence: 0.1),
            incoming: incoming)
        #expect(outPoint(of: planned.plan) == 150)
        // The first downbeat past `introEnd` (2 s), as it always was.
        #expect(inPoint(of: planned.plan) == incoming.downbeats.first { $0 >= 2 - 0.05 })
        #expect((inPoint(of: planned.plan) ?? 0) < 3)
    }

    // MARK: - Trace

    @Test func theTraceRecordsTheStructureStage() {
        var trace: PlanTrace? = PlanTrace()
        let context = TransitionPlanner.PlanContext(
            outgoingLyricLineEnds: [10, 50, 88.5, 167.5, 196])
        _ = TransitionPlanner.plan(
            outgoing: makeAnalysis(phraseBoundaries: [110, 150], sections: pop),
            incoming: makeAnalysis(bpm: 124, sections: pop),
            context: context, trace: &trace)
        let gates = trace?.gates.filter { $0.stage == .structure } ?? []
        let ids = Set(gates.map(\.id))
        #expect(ids == ["structureCandidates", "climaxGuard", "lyricSnap", "inPointSource"])
        // Candidate provenance, the guard's kill count, the snap distance and
        // where the in point came from.
        #expect((gates.first { $0.id == "structureCandidates" }?.value ?? 0) > 0)
        #expect(gates.first { $0.id == "climaxGuard" }?.value == 1)
        #expect(gates.first { $0.id == "lyricSnap" }?.value == 2.5)
        // The anchor the search snaps from — the first core section's start.
        #expect(gates.first { $0.id == "inPointSource" }?.value == 20)
        #expect(gates.first { $0.id == "inPointSource" }?.detail.hasPrefix("section:") == true)
        // Nothing on this stage may ever be blamed for an elimination.
        #expect(trace?.blocker == nil)
    }

    // MARK: - Fallback

    /// The contract the whole layer rests on: with no sections and no lyrics,
    /// the knobs are unreachable and the decision is field-for-field what it
    /// was. (`TransitionPlannerTests` pins the values themselves, unchanged.)
    @Test func withoutSectionsOrLyricsEveryKnobIsUnreachable() {
        var off = TransitionPlanner.Config.standard
        off.useStructureOutPoints = false
        off.useStructureInPoint = false
        off.lyricSnapMaxSeconds = 0
        off.climaxGuardBarsBefore = 0
        for (outBPM, inBPM) in [(120.0, 124.0), (100.0, 160.0)] {
            let outgoing = makeAnalysis(bpm: outBPM)
            let incoming = makeAnalysis(bpm: inBPM)
            let on = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming)
            let reverted = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                                  config: off)
            #expect(outPoint(of: on.plan) == outPoint(of: reverted.plan))
            #expect(inPoint(of: on.plan) == inPoint(of: reverted.plan))
            #expect(on.style == reverted.style)
            #expect(on.rideDB == reverted.rideDB)
        }
        // …and the candidate list is the boundary array itself, untouched.
        let a = makeAnalysis()
        #expect(TransitionPlanner.outPointCandidates(a, context: .none, config: .standard)
            .points == a.phraseBoundaries)
    }
}
