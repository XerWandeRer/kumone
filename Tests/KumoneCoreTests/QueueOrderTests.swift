import Testing
@testable import KumoneCore
import Foundation

// The AutoMix queue-reorder mode's arithmetic and bookkeeping
// (docs/automix-queue-predev.md). Three properties carry the whole design and
// each gets its own test:
//
//   - **the tier dominates**. A stylistically perfect pair that can only be
//     crossfaded must never outrank a pair that can be beat-matched, or the
//     mode is optimising a proxy instead of the thing it claims to optimise.
//   - **aging is unbounded**. "Every track gets played" has to be a property
//     of the arithmetic, not a hope: keep losing and you eventually outrank a
//     whole tier.
//   - **mode off changes nothing**. The three-state replaces a Bool that has
//     been persisted for as long as the app has existed, so a session written
//     before the mode came back exactly as it was.
//
// No engine is constructed anywhere in here: the scorer is a pure function and
// the selector's bookkeeping is reachable without a player.

@Suite struct QueueOrderTests {

    // MARK: - Fixtures

    private func makeAnalysis(
        bpm: Double = 120,
        bpmConfidence: Double = 0.9,
        duration: TimeInterval = 200,
        keyPitchClass: Int? = nil,
        keyIsMinor: Bool = false,
        keyConfidence: Double = 0,
        melProfile: [Float] = [],
        energy: Float? = nil
    ) -> TrackAnalysis {
        let barLength = 4 * 60 / bpm
        var a = TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: bpm, bpmConfidence: bpmConfidence,
            beats: stride(from: 0.4, to: duration, by: 60 / bpm).map { $0 },
            downbeats: stride(from: 0.4, to: duration, by: barLength).map { $0 },
            phraseBoundaries: [150, 90, 30],
            rmsEnvelope: [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil, introEnd: 2, duration: duration,
            melProfile: melProfile, keyPitchClass: keyPitchClass, keyIsMinor: keyIsMinor,
            keyConfidence: keyConfidence, vocalActivity: [],
            referenceLoudness: -12, peakDBFS: -6)
        if let energy {
            a.sections = [TrackAnalysis.Section(start: 0, end: duration, kind: .verse,
                                                repetition: 2, energy: energy, vocalDensity: 1)]
            a.structureConfidence = 0.8
        }
        return a
    }

    /// A `PlannedTransition` of a given shape, built by hand — the scorer takes
    /// the plan as a parameter precisely so the tier can be stated rather than
    /// coaxed out of the planner.
    private func planned(_ tier: TransitionTier) -> PlannedTransition {
        switch tier {
        case .gapless:
            return .plain(.gapless)
        case .crossfade:
            return .plain(.crossfade(duration: 6, outPoint: 180, inPoint: 0))
        case .stagedCrossfade:
            return PlannedTransition(
                plan: .crossfade(duration: 6, outPoint: 180, inPoint: 0),
                style: TransitionStyle(outroEffect: .fade, stagedEQ: true))
        case .beatMatched, .rampedBeatMatched:
            var plan = BeatMatchedPlan(
                outPoint: 160, inPoint: 2, overlapBars: 8,
                outgoingRate: 1.01, incomingRate: 0.99,
                bassSwapOffset: 4, overlapDuration: 16)
            if tier == .rampedBeatMatched {
                plan.rampLeadSeconds = 13
                plan.rampReleaseSeconds = 3
            }
            return .plain(.beatMatched(plan))
        }
    }

    private func track(_ id: Int, artist: Int = 0, name: String? = nil) -> Track {
        let artists = artist == 0 ? [] : [["id": artist, "name": "artist \(artist)"]]
        let json: [String: Any] = [
            "id": id, "name": name ?? "track \(id)", "ar": artists,
            "al": ["id": 1, "name": "album"], "dt": 200_000,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Track.self, from: data)
    }

    // MARK: - Tier ordering

    @Test func theTierDominatesEveryContinuityTerm() {
        // The crossfade candidate is perfect on every continuous term; the
        // beat-matched one is as bad as it can be on all four. The tier must
        // still win — this is predev §2.3's "tier 是主项" as an assertion.
        let a = makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.9,
                             melProfile: [1, 0, 0, 0], energy: 0.6)
        let twin = makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.9,
                                melProfile: [1, 0, 0, 0], energy: 0.6)
        let stranger = makeAnalysis(bpm: 172, keyPitchClass: 6, keyConfidence: 0.9,
                                    melProfile: [-1, 0, 0, 0], energy: 0.05)

        let crossfade = QueueOrderScorer.score(
            outgoing: a, incoming: twin, planned: planned(.crossfade))
        let beatMatched = QueueOrderScorer.score(
            outgoing: a, incoming: stranger, planned: planned(.beatMatched))

        #expect(crossfade.tier == .crossfade)
        #expect(beatMatched.tier == .beatMatched)
        #expect(beatMatched.total > crossfade.total)
    }

    @Test func everyTierStepBeatsAPerfectScoreInTheTierBelow() {
        // Stated as a property over the whole ladder rather than one pair: the
        // four weights sum to 4 and the spacing is 10, so no arrangement of
        // continuity terms can reach the next rung.
        let a = makeAnalysis()
        let b = makeAnalysis()
        let ordered = TransitionTier.allCases.sorted()
        for (lower, upper) in zip(ordered, ordered.dropFirst()) {
            let best = QueueOrderScorer.score(outgoing: a, incoming: b, planned: planned(lower))
            let worst = QueueOrderScorer.score(outgoing: nil, incoming: nil,
                                               planned: planned(upper))
            #expect(worst.total > best.total,
                    "\(upper.label) must outrank \(lower.label) regardless of continuity")
        }
    }

    @Test func aRampedBeatMatchOutranksASteppedOne() {
        let a = makeAnalysis()
        let stepped = QueueOrderScorer.score(outgoing: a, incoming: a,
                                             planned: planned(.beatMatched))
        let ramped = QueueOrderScorer.score(outgoing: a, incoming: a,
                                            planned: planned(.rampedBeatMatched))
        #expect(ramped.total > stepped.total)
    }

    // MARK: - Aging

    @Test func agingIsUnboundedSoNothingStarves() {
        // A track that can only ever be crossfaded, losing to a beat-matchable
        // one over and over. The whole no-starvation claim is that this
        // eventually stops being true — so find the round where it does.
        let a = makeAnalysis()
        let winnerScore = QueueOrderScorer.score(outgoing: a, incoming: a,
                                                 planned: planned(.rampedBeatMatched))
        var rounds = 0
        var loser = QueueOrderScorer.score(outgoing: a, incoming: a,
                                           planned: planned(.crossfade))
        while loser.total <= winnerScore.total {
            rounds += 1
            #expect(rounds < 1000, "aging never overtook the better tier")
            loser = QueueOrderScorer.score(outgoing: a, incoming: a,
                                           planned: planned(.crossfade),
                                           lostRounds: rounds)
        }
        // Three tiers apart at the shipped ε — a bounded number of songs, not
        // a bounded *fraction*, which is what "no starvation" has to mean.
        #expect(rounds > 0)
        #expect(rounds < 200)
    }

    @Test func agingOnlyMovesWithTheRoundsLost() {
        let a = makeAnalysis()
        let fresh = QueueOrderScorer.score(outgoing: a, incoming: a,
                                           planned: planned(.crossfade))
        let aged = QueueOrderScorer.score(outgoing: a, incoming: a,
                                          planned: planned(.crossfade), lostRounds: 4)
        #expect(fresh.aging == 0)
        #expect(abs(aged.aging - 4 * QueueOrderConfig.standard.agingEpsilon) < 1e-9)
        #expect(abs((aged.total - fresh.total) - aged.aging) < 1e-9)
    }

    // MARK: - Same-artist penalty

    @Test func theSameArtistPenaltyIsSubtractedAndCanBeTurnedOff() {
        let a = makeAnalysis()
        let plain = QueueOrderScorer.score(outgoing: a, incoming: a,
                                           planned: planned(.crossfade))
        let penalised = QueueOrderScorer.score(outgoing: a, incoming: a,
                                               planned: planned(.crossfade),
                                               sharesArtist: true)
        #expect(penalised.sameArtistPenalty == -QueueOrderConfig.standard.sameArtistPenalty)
        #expect(abs((plain.total - penalised.total)
                    - QueueOrderConfig.standard.sameArtistPenalty) < 1e-9)

        var off = QueueOrderConfig.standard
        off.sameArtistPenalty = 0
        let unpenalised = QueueOrderScorer.score(outgoing: a, incoming: a,
                                                 planned: planned(.crossfade),
                                                 sharesArtist: true, config: off)
        #expect(unpenalised.sameArtistPenalty == 0)
    }

    @Test func sharingAnArtistIsWhatTripsThePenaltyAndIdZeroIsNotAnArtist() {
        #expect(QueueOrderSelector.sharesArtist(track(1, artist: 7), track(2, artist: 7)))
        #expect(!QueueOrderSelector.sharesArtist(track(1, artist: 7), track(2, artist: 8)))
        // 0 is the decoder's "unknown", not an artist two tracks have in common.
        #expect(!QueueOrderSelector.sharesArtist(track(1, artist: 0), track(2, artist: 0)))
        #expect(!QueueOrderSelector.sharesArtist(nil, track(2, artist: 7)))
    }

    // MARK: - Continuity terms

    @Test func continuityTermsAbstainAtTheNeutralHalfRatherThanGuessing() {
        // Every term has an "I cannot tell" answer, and it has to be 0.5 —
        // neither a bonus nor a penalty — or an unanalyzable track would be
        // systematically preferred or systematically buried.
        let noTempo = makeAnalysis(bpmConfidence: 0.1)
        #expect(QueueOrderScorer.tempoAffinity(noTempo, noTempo) == 0.5)
        let noKey = makeAnalysis(keyConfidence: 0)
        #expect(QueueOrderScorer.keyAffinity(noKey, noKey) == 0.5)
        let noStyle = makeAnalysis(melProfile: [])
        #expect(QueueOrderScorer.styleAffinity(noStyle, noStyle) == 0.5)
    }

    @Test func tempoAffinityFoldsDoubleTimeTheWayThePlannerDoes() {
        let slow = makeAnalysis(bpm: 85)
        let double = makeAnalysis(bpm: 170)
        let awkward = makeAnalysis(bpm: 97)
        #expect(QueueOrderScorer.tempoAffinity(slow, double) == 1)
        #expect(QueueOrderScorer.tempoAffinity(slow, awkward) < 0.5)
    }

    @Test func keyAffinityIsWeightedByTheWeakerConfidence() {
        let c = makeAnalysis(keyPitchClass: 0, keyConfidence: 0.9)
        let sameKey = makeAnalysis(keyPitchClass: 0, keyConfidence: 0.9)
        let tritone = makeAnalysis(keyPitchClass: 6, keyConfidence: 0.9)
        #expect(QueueOrderScorer.keyAffinity(c, sameKey) > 0.9)
        #expect(QueueOrderScorer.keyAffinity(c, tritone) < 0.1)
        // A guess pulls its own verdict back toward the neutral half.
        let unsure = makeAnalysis(keyPitchClass: 6, keyConfidence: 0.65)
        let confident = QueueOrderScorer.keyAffinity(c, tritone)
        let hedged = QueueOrderScorer.keyAffinity(c, unsure)
        #expect(hedged > confident)
        #expect(hedged < 0.5)
    }

    @Test func aHardEnergyDropCostsMoreThanTheSameSizedRise() {
        let mid = makeAnalysis(energy: 0.5)
        let quiet = makeAnalysis(energy: 0.2)
        let loud = makeAnalysis(energy: 0.8)
        let drop = QueueOrderScorer.energyContinuity(mid, quiet)
        let rise = QueueOrderScorer.energyContinuity(mid, loud)
        let flat = QueueOrderScorer.energyContinuity(mid, makeAnalysis(energy: 0.5))
        #expect(flat == 1)
        #expect(rise > drop)
        #expect(drop < 1)
    }

    // MARK: - Tier derivation

    @Test func theTierIsReadOffThePlanNeverReDecided() {
        #expect(TransitionTier(planned(.gapless)) == .gapless)
        #expect(TransitionTier(planned(.crossfade)) == .crossfade)
        #expect(TransitionTier(planned(.stagedCrossfade)) == .stagedCrossfade)
        #expect(TransitionTier(planned(.beatMatched)) == .beatMatched)
        #expect(TransitionTier(planned(.rampedBeatMatched)) == .rampedBeatMatched)
        #expect(TransitionTier(planned(.beatMatched)).isBeatMatched)
        #expect(!TransitionTier(planned(.stagedCrossfade)).isBeatMatched)
    }

    // MARK: - Pool bookkeeping

    @MainActor
    @Test func thePoolIsEverythingAlreadyAnalyzedInListOrder() {
        let selector = QueueOrderSelector()
        let remaining = (1...6).map { track($0) }
        // Cold: nothing is free, so the pool is empty and the escalation below
        // is the only way to fill it.
        #expect(selector.pool(remaining: remaining).isEmpty)

        // Anything with an analysis in hand joins for free, wherever it sits —
        // and the pool stays in list order, which is what the pick's tie-break
        // reads.
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 5)
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 2)
        #expect(selector.pool(remaining: remaining).map(\.id) == [2, 5])

        // An analysis for a track that is no longer in the queue is simply not
        // in the pool — no bookkeeping needed.
        #expect(selector.pool(remaining: [track(1), track(5)]).map(\.id) == [5])
    }

    // MARK: - Satisficing escalation (predev §2.2)

    /// A selector whose pool already satisfies, seen through `pick`: an
    /// outgoing and an incoming analysis that the *planner* will beat-match.
    /// The escalation's stop condition reads the tier off a real plan, so the
    /// fixtures have to be plannable rather than stated.
    @MainActor
    private func beatMatchableSelector() -> (QueueOrderSelector, TrackAnalysis) {
        let selector = QueueOrderSelector()
        return (selector, makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.9,
                                       melProfile: [1, 0, 0, 0], energy: 0.6))
    }

    @MainActor
    @Test func aPoolThatAlreadySatisfiesCostsNothing() {
        let (selector, outgoing) = beatMatchableSelector()
        let remaining = (1...20).map { track($0) }
        // Track 7 is a twin of what is playing: same tempo, same key, same
        // energy — the planner beat-matches it.
        selector.injectAnalysisForTesting(outgoing, forTrackID: 7)

        let pool = selector.pool(remaining: remaining)
        let winner = selector.pick(outgoing: nil, outgoingAnalysis: outgoing, pool: pool)
        #expect(winner?.id == 7)
        #expect(selector.lastPickSatisfies)
        // Zero rounds, zero downloads: the whole point of satisficing.
        #expect(selector.rounds == 0)
        #expect(selector.downloadsThisPick == 0)
        #expect(selector.frontier(remaining: remaining).isEmpty)
    }

    @MainActor
    @Test func aPoolThatDoesNotSatisfyIsNotMistakenForOne() {
        let (selector, outgoing) = beatMatchableSelector()
        // Far enough apart in tempo that the planner cannot lock the grids.
        selector.injectAnalysisForTesting(
            makeAnalysis(bpm: 155, keyPitchClass: 6, keyConfidence: 0.9,
                         melProfile: [-1, 0, 0, 0], energy: 0.1),
            forTrackID: 3)
        let remaining = (1...20).map { track($0) }
        _ = selector.pick(outgoing: nil, outgoingAnalysis: outgoing,
                          pool: selector.pool(remaining: remaining))
        #expect(!selector.lastPickSatisfies)
        // A pick with nothing scored at all cannot satisfy either.
        let empty = QueueOrderSelector()
        _ = empty.pick(outgoing: nil, outgoingAnalysis: outgoing, pool: [])
        #expect(!empty.lastPickSatisfies)
    }

    @MainActor
    @Test func theRoundsAreOneThenFourThenSixteenInListOrder() {
        let selector = QueueOrderSelector()
        let remaining = (1...40).map { track($0) }
        // No network in a test: `acquire` is driven with downloads forbidden,
        // which is exactly the politeness path — it opens rounds and reports
        // `.deferred` rather than fetching, so the ladder is observable
        // without a single byte.
        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).map(\.id) == [1])
        #expect(selector.rounds == 1)

        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).map(\.id) == Array(1...5))
        #expect(selector.rounds == 2)

        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).map(\.id) == Array(1...21))
        #expect(selector.rounds == 3)

        // Bounded by the remaining queue: the fourth round takes what is left
        // and the fifth has nothing to admit.
        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).count == 40)
        #expect(!selector.escalateForTesting(remaining: remaining))
    }

    @MainActor
    @Test func aRoundOnlySpendsItselfOnTracksItActuallyHasToBuy() {
        let selector = QueueOrderSelector()
        let remaining = (1...20).map { track($0) }
        // Tracks 1–3 are already analyzed (a previous session paid for them)
        // and track 4 was refused. A round of one must reach past all four
        // rather than spend itself on a track that costs nothing.
        for id in 1...3 { selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: id) }
        selector.injectRefusalForTesting(trackID: 4)

        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).map(\.id) == [5])
        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).map(\.id) == [5, 6, 7, 8, 9])
    }

    @MainActor
    @Test func satisfactionStopsTheRoundHalfWayThrough() {
        let (selector, outgoing) = beatMatchableSelector()
        let remaining = (1...20).map { track($0) }
        // Open the 1 and the 4: five tracks admitted, none resolved.
        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).count == 5)

        // The second track of the round of four comes back beat-matchable.
        selector.injectAnalysisForTesting(makeAnalysis(bpm: 155), forTrackID: 1)
        selector.injectAnalysisForTesting(outgoing, forTrackID: 3)
        _ = selector.pick(outgoing: nil, outgoingAnalysis: outgoing,
                          pool: selector.pool(remaining: remaining))
        #expect(selector.lastPickSatisfies)

        // Three of the five admitted tracks are still unresolved. The caller
        // stops here — it never asks `acquire` again — so they are never
        // bought. The round does not have to finish for the pick to be made.
        #expect(selector.frontier(remaining: remaining)
                    .filter { !selector.hasAnalysis(for: $0) }.map(\.id) == [2, 4, 5])
        #expect(selector.rounds == 2)
    }

    @MainActor
    @Test func theEscalationIsBoundedByTheQueueAndThenReportsExhausted() {
        let selector = QueueOrderSelector()
        let remaining = [track(1), track(2)]
        // Both already resolved, so there is nothing left to admit at all and
        // the very first tick says so — which is the caller's cue to pick the
        // best it has rather than wait for the deadline.
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 1)
        selector.injectRefusalForTesting(trackID: 2)
        #expect(selector.acquire(remaining: remaining, mayDownload: true) == .exhausted)
    }

    @MainActor
    @Test func theDeadlineStillTakesTheBestAnalyzedCandidateOrNothing() {
        // The deadline path is the one thing the escalation does not touch: it
        // never consults the satisfying tier, it takes `pick`'s answer — the
        // best analyzed candidate, or nil, which leaves the user's list order
        // alone rather than holding up a hand-over for a download.
        let (selector, outgoing) = beatMatchableSelector()
        let remaining = (1...6).map { track($0) }
        #expect(selector.pick(outgoing: nil, outgoingAnalysis: outgoing,
                              pool: selector.pool(remaining: remaining)) == nil)

        // Two candidates that cannot be beat-matched: nothing satisfies, and
        // the deadline takes the better of them anyway.
        selector.injectAnalysisForTesting(
            makeAnalysis(bpm: 155, keyPitchClass: 6, keyConfidence: 0.9,
                         melProfile: [-1, 0, 0, 0], energy: 0.05),
            forTrackID: 4)
        selector.injectAnalysisForTesting(
            makeAnalysis(bpm: 151, keyPitchClass: 0, keyConfidence: 0.9,
                         melProfile: [1, 0, 0, 0], energy: 0.6),
            forTrackID: 2)
        let winner = selector.pick(outgoing: nil, outgoingAnalysis: outgoing,
                                   pool: selector.pool(remaining: remaining))
        #expect(!selector.lastPickSatisfies)
        #expect(winner?.id == 2)
    }

    @MainActor
    @Test func theEscalationStandsAsideWhileThePlaybackDownloadRuns() {
        let selector = QueueOrderSelector()
        let remaining = (1...8).map { track($0) }
        selector.markScannedForTesting(remaining)
        // Impolite moment: a round opens (the bookkeeping is free) but no
        // transfer starts, and the tick says why.
        #expect(selector.acquire(remaining: remaining, mayDownload: false) == .deferred)
        #expect(selector.rounds == 1)
        #expect(selector.downloadsThisPick == 0)
        // Asking again while still impolite does not open a second round: the
        // frontier is unresolved, so there is nothing to escalate past.
        #expect(selector.acquire(remaining: remaining, mayDownload: false) == .deferred)
        #expect(selector.rounds == 1)
    }

    // MARK: - Per-pick download budget

    @MainActor
    @Test func aPickThatHasSpentItsBudgetStopsBuyingAndSaysSo() {
        let selector = QueueOrderSelector()
        selector.config.maxDownloadsPerPick = 3
        let remaining = (1...40).map { track($0) }
        selector.markScannedForTesting(remaining)

        // Under budget: the ladder runs as usual.
        #expect(selector.acquire(remaining: remaining, mayDownload: false) == .deferred)
        selector.markDownloadsForTesting(2)
        #expect(selector.acquire(remaining: remaining, mayDownload: false) == .deferred)

        // At the cap: `.spent`, which is the caller's cue to commit the best it
        // has. Distinct from `.exhausted` on purpose — the queue still has 39
        // unresolved tracks, they are simply not this pick's to buy.
        selector.markDownloadsForTesting(3)
        #expect(selector.acquire(remaining: remaining, mayDownload: true) == .spent)
        // And no further round is opened: admitting tracks it cannot buy would
        // only make the frontier lie.
        let roundsAtCap = selector.rounds
        #expect(selector.acquire(remaining: remaining, mayDownload: true) == .spent)
        #expect(selector.rounds == roundsAtCap)
    }

    @MainActor
    @Test func theBudgetBitesMidRoundNotAtARoundBoundary() {
        let selector = QueueOrderSelector()
        selector.config.maxDownloadsPerPick = 3
        let remaining = (1...40).map { track($0) }
        selector.markScannedForTesting(remaining)
        // Round 1 (one track) and round 2 (four) are open: five admitted, so
        // the cap of three falls in the middle of the second round.
        selector.escalateForTesting(remaining: remaining)
        selector.escalateForTesting(remaining: remaining)
        #expect(selector.frontier(remaining: remaining).count == 5)

        selector.markDownloadsForTesting(3)
        #expect(selector.acquire(remaining: remaining, mayDownload: true) == .spent)
        // Two of the round's tracks stay unbought — and they stay *unresolved*,
        // which is what lets the next pick escalate into them from a pool this
        // one made richer. The warming is spread, not lost.
        #expect(selector.frontier(remaining: remaining)
                    .filter { !selector.hasAnalysis(for: $0) }.count == 5)
        selector.beginPick()
        #expect(selector.downloadsThisPick == 0)
        #expect(selector.acquire(remaining: remaining, mayDownload: false) == .deferred)
        #expect(selector.rounds == 1)
    }

    @Test func theBudgetIsSweepableAndCannotBeSetToZero() {
        #expect(QueueOrderConfig.standard.maxDownloadsPerPick == 24)
        let moved = QueueOrderConfig.standard(overriding: ["maxDownloadsPerPick": 60])
        #expect(moved.maxDownloadsPerPick == 60)
        // A budget of zero would be a mode that can never buy anything; the
        // field's own floor rules it out.
        #expect(QueueOrderConfig.standard(
            overriding: ["maxDownloadsPerPick": 0]).maxDownloadsPerPick == 1)
    }

    // MARK: - Lookahead chain

    @MainActor
    @Test func theChainIsPureAndNeverAgesAnything() {
        let selector = QueueOrderSelector()
        let head = track(1)
        let remaining = (2...6).map { track($0) }
        for t in [head] + remaining {
            selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: t.id)
        }
        // Give the real counters a shape worth protecting.
        selector.noteRound(chosen: track(2), pool: remaining)
        let before = remaining.map { selector.lostRoundsForTesting($0.id) }
        let pickBefore = selector.lastPick

        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(!selector.lookahead.isEmpty)

        // The chain ages its own private copy of the counters, so a preview
        // cannot change the future it is previewing.
        #expect(remaining.map { selector.lostRoundsForTesting($0.id) } == before)
        #expect(selector.lastPick == pickBefore)
        // Idempotent: running it twice gives the same answer, which it would
        // not if it were leaving a mark.
        let first = selector.lookahead
        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead == first)
    }

    @MainActor
    @Test func theChainVisitsEachTrackOnceAndStopsAtTheConfiguredDepth() {
        let selector = QueueOrderSelector()
        selector.config.lookaheadDepth = 3
        let head = track(1)
        let remaining = (2...9).map { track($0) }
        for t in [head] + remaining {
            selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: t.id)
        }
        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead.count == 3)
        // The chain's own aging is what keeps it from proposing one track over
        // and over: each step drops its winner from the pool.
        let ids = selector.lookahead.map(\.track.id)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains(head.id))

        // Depth 0 turns it off outright.
        selector.config.lookaheadDepth = 0
        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead.isEmpty)
    }

    @MainActor
    @Test func theChainOnlyEverPlansWithAnalysesItAlreadyHas() {
        let selector = QueueOrderSelector()
        let head = track(1)
        let remaining = (2...9).map { track($0) }
        // Nothing analyzed: no chain at all, rather than a chain of guesses.
        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead.isEmpty)

        // The pool grows by two, and the chain grows with it — this is the
        // "recompute when the pool grows" contract, stated as an assertion
        // about the answer rather than about the plumbing.
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 1)
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 4)
        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead.map(\.track.id) == [4])

        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 7)
        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead.map(\.track.id) == [4, 7])

        // A queue edit is the same story: re-derived from what it is handed.
        selector.recomputeLookahead(head: head, remaining: remaining.filter { $0.id != 4 })
        #expect(selector.lookahead.map(\.track.id) == [7])
    }

    @MainActor
    @Test func aQueueEditIsHandledByReDerivingNotByFixingUpIndices() {
        let selector = QueueOrderSelector()
        var remaining = (1...20).map { track($0) }
        selector.escalateForTesting(remaining: remaining)
        selector.escalateForTesting(remaining: remaining)
        #expect(selector.frontier(remaining: remaining).map(\.id) == Array(1...5))

        // The user removes two admitted tracks and inserts a new one at the
        // head. The frontier is the admitted set intersected with the queue as
        // it is *now*: the departed tracks are gone, and the newcomer is not
        // admitted until a round reaches it.
        remaining = [track(99)] + remaining.filter { $0.id != 2 && $0.id != 4 }
        #expect(selector.frontier(remaining: remaining).map(\.id) == [1, 3, 5])

        // The next round admits the newcomer along with the rest of the list,
        // in the order the list has now — no index anywhere survived the edit.
        selector.escalateForTesting(remaining: remaining)
        #expect(selector.frontier(remaining: remaining).map(\.id)
                == [99, 1, 3, 5] + Array(6...20))

        // A pick that lands on a departed track is impossible: the pool is
        // derived from `remaining` too.
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 2)
        #expect(!selector.pool(remaining: remaining).contains { $0.id == 2 })
    }

    @MainActor
    @Test func aNewTrackRestartsTheEscalationButKeepsWhatItPaidFor() {
        let selector = QueueOrderSelector()
        let remaining = (1...20).map { track($0) }
        selector.escalateForTesting(remaining: remaining)
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 1)
        #expect(selector.rounds == 1)

        selector.beginPick()
        #expect(selector.rounds == 0)
        #expect(selector.downloadsThisPick == 0)
        #expect(selector.frontier(remaining: remaining).isEmpty)
        // The sidecar it bought is the whole reason the next pick is cheaper.
        #expect(selector.pool(remaining: remaining).map(\.id) == [1])
    }

    @MainActor
    @Test func aPoolIsSettledOnlyOnceEveryCandidateHasBeenResolved() {
        let selector = QueueOrderSelector()
        let pool = [track(1), track(2)]
        #expect(!selector.isSettled(pool))
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 1)
        #expect(!selector.isSettled(pool))
        selector.injectRefusalForTesting(trackID: 2)
        #expect(selector.isSettled(pool))
    }

    @MainActor
    @Test func onlyThePoolAgesAndTheWinnerIsForgiven() {
        let selector = QueueOrderSelector()
        let one = track(1), two = track(2), three = track(3)
        for t in [one, two, three] {
            selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: t.id)
        }
        selector.noteRound(chosen: one, pool: [one, two, three])
        selector.noteRound(chosen: two, pool: [two, three])

        // Track 3 lost twice; track 1 was never in the second pool, so it did
        // not age for a round it was not offered.
        #expect(selector.lostRoundsForTesting(three.id) == 2)
        #expect(selector.lostRoundsForTesting(one.id) == 0)
        // A winner starts clean again.
        #expect(selector.lostRoundsForTesting(two.id) == 0)
    }

    @MainActor
    @Test func aPickOnlyEverConsidersAnalyzedCandidatesAndTiesBreakOnListOrder() {
        let selector = QueueOrderSelector()
        let outgoing = makeAnalysis()
        let pool = [track(1), track(2), track(3)]
        // Nothing analyzed: nil, which is the caller's cue to leave the list
        // order alone rather than wait for a download.
        #expect(selector.pick(outgoing: nil, outgoingAnalysis: outgoing, pool: pool) == nil)

        // Two identical candidates: the earlier one in the pool wins, so a
        // pool the scorer cannot tell apart reproduces the user's list.
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 2)
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 3)
        let winner = selector.pick(outgoing: nil, outgoingAnalysis: outgoing, pool: pool)
        #expect(winner?.id == 2)
        #expect(selector.lastPick.map(\.track.id) == [2, 3])
    }

    @MainActor
    @Test func resettingKeepsAnalysesAndDropsEverythingAboutTheOldQueue() {
        let selector = QueueOrderSelector()
        let one = track(1), two = track(2)
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 1)
        selector.injectRefusalForTesting(trackID: 2)
        selector.noteRound(chosen: one, pool: [one, two])
        #expect(selector.lostRoundsForTesting(two.id) == 1)

        selector.reset()
        // The analysis is on disk anyway; forgetting it would buy nothing and
        // cost a re-download.
        #expect(selector.hasAnalysis(for: one))
        #expect(selector.lostRoundsForTesting(two.id) == 0)
        // A refusal described a queue that no longer exists.
        #expect(!selector.isSettled([two]))
        #expect(selector.lastPick.isEmpty)
    }

    // MARK: - Stem pre-render runway

    @Test func theRunwayEstimateScalesWithTheSeamRatherThanBeingOneFlatNumber() {
        // Separation is ~1× realtime per side and a segment wants both, plus a
        // margin: a 16 s overlap needs 47 s. The point of the estimate is that
        // 49 s of runway is *enough* for it — under the old flat 60 s lead that
        // seam was refused, and the stem gesture silently became a whole-mix
        // crossfade.
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 16) == 47)
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 16) < 49)
        // The nominal seam the flat lead was sized for still fits inside it, so
        // the ordinary path is unchanged.
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 15) == 45)
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 15) <= 60)
        // A long overlap costs more than the lead can offer, and is refused up
        // front rather than started and abandoned at the guard.
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 30) == 75)
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 30) > 60)
        // Monotone, and never negative for a degenerate plan.
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 8)
                < PlayerService.stemPrerenderRunway(overlapDuration: 9))
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 0) == 15)
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: -5) == 15)
    }

    // MARK: - Migration

    @Test func aSessionWrittenBeforeTheModeExistedMigratesFromItsShuffleBool() {
        // No `queueOrder` key at all — the shape every state file on disk has
        // today.
        let legacyShuffling = PlayerService.PersistedState(
            queue: [], currentID: nil, repeatMode: "off", shuffle: true,
            recentContexts: nil, queueOrder: nil)
        let legacyListed = PlayerService.PersistedState(
            queue: [], currentID: nil, repeatMode: "off", shuffle: false,
            recentContexts: nil, queueOrder: nil)
        #expect(PlayerService.restoredQueueOrder(legacyShuffling) == .shuffled)
        #expect(PlayerService.restoredQueueOrder(legacyListed) == .listed)
        #expect(QueueOrder(migratingShuffle: true) == .shuffled)
        #expect(QueueOrder(migratingShuffle: false) == .listed)
    }

    @Test func anExplicitQueueOrderWinsOverTheLegacyBool() {
        // Both keys present and disagreeing: a build that wrote `autoMix` also
        // wrote `shuffle: false`, and a build that has since been downgraded
        // and re-upgraded must not lose the mode.
        let state = PlayerService.PersistedState(
            queue: [], currentID: nil, repeatMode: "off", shuffle: false,
            recentContexts: nil, queueOrder: "autoMix")
        #expect(PlayerService.restoredQueueOrder(state) == .autoMix)
    }

    @Test func anUnknownQueueOrderFallsBackToTheBoolRatherThanFailing() {
        let state = PlayerService.PersistedState(
            queue: [], currentID: nil, repeatMode: "off", shuffle: true,
            recentContexts: nil, queueOrder: "someFutureMode")
        #expect(PlayerService.restoredQueueOrder(state) == .shuffled)
    }

    // MARK: - Config surface

    @Test func theWeightsAreSweepableTheSameWayThePlannersAre() {
        let moved = QueueOrderConfig.standard(
            overriding: ["agingEpsilon": 1.25, "escalationFirstRound": 7,
                         "escalationFactor": 2, "satisfyingTier": 2])
        #expect(moved.agingEpsilon == 1.25)
        #expect(moved.escalationFirstRound == 7)
        #expect(moved.escalationFactor == 2)
        #expect(moved.satisfyingTier == .stagedCrossfade)
        // The default is "the grids can be locked", which both beat-matched
        // tiers clear.
        #expect(QueueOrderConfig.standard.satisfyingTier == .beatMatched)
        #expect(TransitionTier.rampedBeatMatched >= QueueOrderConfig.standard.satisfyingTier)
        // A tier out of range is clamped rather than crashing a swept preset.
        #expect(QueueOrderConfig.standard(overriding: ["satisfyingTier": 99]).satisfyingTier
                == .rampedBeatMatched)
        // Unknown names are ignored and values are clamped, so a stale preset
        // can never take the mode down.
        let clamped = QueueOrderConfig.standard(
            overriding: ["agingEpsilon": 9_999, "nonsense": 3])
        #expect(clamped.agingEpsilon == 5)
        #expect(QueueOrderConfig.standard.asDictionary["tierSpacing"] == 10)
    }
}
