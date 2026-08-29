import Foundation

// From a score to audio: bars and beats → seconds → per-sample gain lanes.
//
// The division of labour is `vocalExchange`'s, one level up (predev §2.2). The
// planner names an intent — "cut on the one, throw the last line into a delay"
// — as a `TransitionScore` of typed events on a bar grid. It cannot turn that
// into audio: where bar 0 beat 0 *is* depends on the final geometry, on both
// beat grids, on how far each deck is bent, and on where the outgoing singer
// stopped singing. All of that is known here, once, just before the render.
//
// The refusal path matters as much as the compile. A score that cannot be
// placed on the grid is thrown away whole and the hand-over is today's blend —
// never a half-placed score, never a cut nudged onto the nearest thing that
// looked like a downbeat. Half a beat out is the one error a cut cannot
// survive (predev §4.2), so everything below fails closed.

enum ScoreCompiler {

    // MARK: - Tolerances

    /// How far the seam may be moved off `Geometry.swapOffset` to land on a
    /// downbeat, as a fraction of one bar. Half a bar means "the nearest
    /// downbeat, whichever side"; past that there is no downbeat near the
    /// hand-over at all and the grid is not to be trusted.
    static let seamSnapBars: Double = 0.5

    /// How far the aim's own bar line may sit from the hand-over instant before
    /// the compiler stops believing the aim describes *this* geometry, in bars.
    ///
    /// Wider than `seamSnapBars` on purpose, and it is not a loosening: the
    /// planner put the aim within half a bar of the swap by construction (it
    /// rounded the lead to whole bars), so a full bar of slack absorbs that
    /// rounding while still catching the case this exists for — a plan override
    /// that moved the seam after the aim was chosen, leaving the aim pointing
    /// at a bar that is no longer the hand-over.
    static let aimSnapBars: Double = 1.0

    /// Grid self-check (predev §4.2): bar lengths around the seam must agree to
    /// within this fraction, or the grid is drifting and a cut on it would land
    /// off the beat.
    ///
    /// **Measured on bars, not beats, and that is not a softening.** The predev
    /// writes the check as "adjacent intervals jumping more than 3 %", and on
    /// the *beat* list that fires on everything: eight quantized dance tracks
    /// out of the user's own cache carry a 5–13 % worst beat interval and an
    /// 8 % typical one, because the tracker snaps each beat to an onset and the
    /// onsets are where the performance is, not where the clock is. That noise
    /// is the analyzer's, and a check that measures the analyzer refuses every
    /// score for no musical reason. The bar grid over the same eight tracks
    /// separates cleanly instead — 0.7–3.4 % around the seam for six of them,
    /// 12 % and 13 % for the two whose downbeats really do wander — and the bar
    /// grid is also what a score is addressed on, so it is the grid whose
    /// trustworthiness the gesture actually depends on.
    static let gridJitterTolerance: Double = 0.03
    /// How many bars either side of the seam the self-check looks at.
    static let gridCheckBars = 4

    /// **How much looser the self-check is for a score that does not cut.**
    ///
    /// The check above exists for one reason, and the predev states it as one:
    /// a cut on a drifting grid lands on the wrong beat, and half a beat out is
    /// the error the gesture cannot survive. Every number in it is calibrated
    /// against an 8 ms edge landing on the one.
    ///
    /// A decorating score has no such edge. `bedIntro`'s only event is a
    /// singer joining over 30 ms on a bar line the **aim** already chose and
    /// the aim's own half-bar snap already vetted; a 5 % wobble in the bars
    /// either side of it moves that instant by tens of milliseconds inside a
    /// gesture whose whole shape is bars long. Holding it to the cut's
    /// tolerance is not caution, it is measuring the wrong thing — and
    /// measurably so: over the user's 121-track cache the three pairs that
    /// ever reach a bed compile were refused at 3.3 %, 3.3 % and 4.3 %, which
    /// is the check rejecting a gesture it was not written about.
    ///
    /// Twice the cut's line, and no looser: past ~6 % the bar grid is not a bar
    /// grid, and an aim placed on it is pointing at nothing in particular.
    static let decoratingJitterMultiple: Double = 2

    /// One phrase, in bars — the unit the slam prefers to land on (see the seam
    /// placement below), and the length nearly all of this repertoire's
    /// sections are built out of.
    static let phraseBars = 4
    /// How far the seam may be walked to reach a phrase line, in bars. Two bars
    /// either way covers every offset inside a four-bar phrase.
    static let phraseSnapBars = 2

    /// Beat fraction the echo throw's delay is synced to — a dotted eighth,
    /// the same 0.75 `TransitionAutomation.echoDelayTime` uses, so a throw and
    /// an `.echoOut` on the same pair ring at the same tempo.
    static let echoDelayBeatFraction: Double = 0.75
    /// The throw needs this much room on both sides: a line end within a
    /// quarter second of the seam is not a throw, it is a cut with a click on
    /// it, and one that lands before the overlap has started cannot be played.
    static let echoThrowMarginSeconds: TimeInterval = 0.25
    /// **The throw's qualification window**, in beats either side of the seam
    /// (predev's throw, with P2's discipline on it).
    ///
    /// One beat, because one beat is the whole tolerance a sung line has: a
    /// line that ends a beat before the seam ended *on* the phrase, and a line
    /// that ends a beat after it is the singer landing on the one the cut is
    /// taking. Two beats already admits lines that stop mid-bar, and four
    /// admits everything, which is P1's behaviour and the thing being fixed.
    static let echoThrowQualifyBeats: Double = 1.0

    // MARK: - P4 gestures

    /// How long the incoming track takes to come up when a score cuts the
    /// outgoing one and does **not** slam — one bar, on the incoming song's own
    /// clock.
    ///
    /// This is the slam's control arm made concrete. A `cutOut` with no
    /// `slamIn` is not "a cut with the incoming lane left at whatever the
    /// automation was doing" — the score owns the gain law, so there *is* no
    /// automation to leave it to. It is a cut followed by a one-bar raised
    /// cosine, which is the mildest honest thing an owned gain law can do, and
    /// the thing a slam has to prove itself against.
    static let softEntryBars: Double = 1

    /// Vocals joining a bed are given this long to arrive.
    ///
    /// Not zero: the lane is a gain on a separated stem, and a hard step on a
    /// signal that already has a room tail in it clicks. Not long either — 30 ms
    /// is under a thirty-second note at any tempo in this repertoire, so the
    /// singer still lands *on* the bar line rather than around it. The ramp runs
    /// **into** the landing point rather than out of it, so the first sample of
    /// the drop is the first sample at full voice.
    static let bedVocalRampSeconds: TimeInterval = 0.03

    /// How much longer than the bed it asked for a hand-over may be before the
    /// bed is refused, in bars.
    ///
    /// A bed is written as "N bars of accompaniment ending on the landing", and
    /// the bed's start is not negotiable: it is the instant the incoming deck
    /// starts, because that is the first moment there is anything to hold down.
    /// So on an overlap longer than N bars the gesture cannot be performed as
    /// written — muting from the start would be a longer bed than asked for,
    /// and muting from N bars back would put the incoming singer on the air,
    /// off again, and back, which is a fault rather than a gesture. Half a bar
    /// of slack absorbs the planner's own rounding; past that, refuse.
    static let bedOverrunBars: Double = 0.5

    // MARK: - Output

    /// One event, placed.
    struct Placed: Sendable, Equatable {
        var event: String
        var at: GridPosition
        /// Seconds into the overlap.
        var offset: TimeInterval
    }

    /// What compiling a score came to — enough for the console and the panel to
    /// say why it landed where it did, or why it did not land at all.
    struct Compilation: Sendable, Equatable {
        var label: String
        /// **Which instant of the hand-over `bar 0 beat 0` was pinned to.**
        ///
        /// `.seam` for every score that ends the outgoing track: bar 0 is the
        /// bass-swap point, the one the cut lands on. `.overlapEnd` for a
        /// decorating score (`bedIntro`) riding a `dropAlign` blend, where the
        /// arrival the gesture is built around is the end of the overlap rather
        /// than the middle of it. One field so a report never has to guess
        /// which of the two `seamOffset` below is measuring.
        var origin: TransitionAim.Landing = .seam
        /// Seconds into the overlap where the origin (`origin`) sits.
        var seamOffset: TimeInterval = 0
        /// The same instant on the two songs' own clocks.
        var seamOutgoing: TimeInterval = 0
        var seamIncoming: TimeInterval = 0
        /// How far the seam had to move off the plan's own swap point to land
        /// on a downbeat.
        var seamSnapSeconds: TimeInterval = 0
        /// What the seam was aimed at, when the planner aimed it (P2). Nil is
        /// the degradation path: the seam then goes where P1 put it, on the
        /// phrase line nearest the plan's own swap point.
        var aim: TransitionAim?
        /// Why `aim` is what it is — the planner's own sentence, or the
        /// compiler's when it is the one that dropped the aim. Printed with
        /// `aim=none` so a report never says only "no".
        var aimNote: String?
        var events: [Placed] = []
        var echoThrow: EchoThrowDirective?
        /// The outgoing line thrown into the delay.
        var echoLine: String?
        /// Gestures that were asked for and quietly came out smaller — an echo
        /// throw with no lyrics to aim at degrades to a plain cut. Never
        /// silent: a listener has to be able to tell which gesture they heard.
        var degradations: [String] = []
        /// The compiled lanes; nil exactly when `refusalReason` is set. A
        /// decorating score's lanes are pass-through — it says everything it
        /// has to say through `stemEnvelope`.
        var lanes: WholeMixLanes?
        /// **The stem side of the compile**, written by `bedIntro` and by
        /// nothing else: the incoming deck's vocal lane, held at −60 dB until
        /// the singer joins. Non-nil is what makes this score's segment pay a
        /// separation pass.
        var stemEnvelope: StemEnvelope?
        /// What this score costs the pre-render's runway. Read off the score
        /// rather than derived here, so the arming path and the render path
        /// cannot disagree about the bill.
        var runwayClass: TransitionScore.RunwayClass = .scoreOnly
        /// Why the whole score was thrown away. Non-nil means the hand-over is
        /// the plain blend it would have been without a score at all.
        var refusalReason: String?

        var didCompile: Bool { lanes != nil }
    }

    // MARK: - Entry point

    /// Compile one score against the final geometry and both beat grids.
    ///
    /// Pure: two analyses, a plan, and (for the echo throw's anchor) the
    /// outgoing track's URL, which is read for its `.lrc` exactly as
    /// `VocalExchange` reads it. Never throws — a score that cannot be placed
    /// comes back as a `Compilation` carrying `refusalReason`, because the
    /// caller's answer to both outcomes is the same shape: play the blend.
    static func compile(_ score: TransitionScore, planned: PlannedTransition,
                        outgoing: TrackAnalysis, incoming: TrackAnalysis,
                        outgoingURL: URL?) -> Compilation {
        func refuse(_ reason: String) -> Compilation {
            // The aim rides along even on a refusal: "what did this seam want
            // to land on, and why did it not" is one question, and a report
            // that dropped half of it would be answering the easier one.
            Compilation(label: score.label, aim: planned.style.aim,
                        aimNote: planned.style.aimDetail,
                        runwayClass: score.runwayClass, refusalReason: reason)
        }

        do { try score.validate() } catch {
            return refuse("乐谱本身不合法："
                          + ((error as? LocalizedError)?.errorDescription
                             ?? error.localizedDescription))
        }
        if let unsupported = score.events.first(where: { !$0.event.isSupportedInV1 }) {
            return refuse("\(unsupported.event.label) 还没有编译器实现，整谱作废。")
        }
        guard case .beatMatched(let p) = planned.plan else {
            return refuse("乐谱只在 beatMatched 的转场上有格子可以落。")
        }
        let geometry = TransitionAutomation.Geometry(plan: planned.plan)
        let overlap = geometry.overlapDuration
        guard overlap > 1 else {
            return refuse(String(format: "这次叠加只有 %.2f 秒，排不下一张乐谱。", overlap))
        }
        let glide = TransitionAutomation.incomingGlide(for: planned.plan, geometry: geometry)
        let outRate = Double(max(0.5, min(2, p.outgoingRate)))
        let inRate = Double(max(0.5, min(2, p.incomingRate)))

        // --- The two grids, each on its own song's clock.
        let outDownbeats = outgoing.downbeats
        let inDownbeats = incoming.downbeats
        guard outDownbeats.count > score.preBars, inDownbeats.count > score.postBars else {
            return refuse("两侧的小节网格不够长，落不下 \(score.preBars)/\(score.postBars) 小节的乐谱。")
        }

        /// Overlap-relative seconds → the outgoing track's own clock, on its
        /// (constant, already-bent) overlap rate.
        func outgoingSource(_ t: TimeInterval) -> TimeInterval { p.outPoint + t * outRate }
        func outgoingOverlapTime(_ source: TimeInterval) -> TimeInterval {
            (source - p.outPoint) / outRate
        }
        /// …and the incoming track's, which under a post-swap glide is the
        /// integral of a moving rate rather than a straight line. Exactly the
        /// map `StemTechniqueLayer.Side.sourceAdvance` uses, and its inverse.
        let incomingClock = StemTechniqueLayer.SourceClock(rate: inRate, glide: glide)
        func incomingSource(_ t: TimeInterval) -> TimeInterval {
            p.inPoint + incomingClock.sourceAdvance(to: t)
        }
        func incomingOverlapTime(_ source: TimeInterval) -> TimeInterval {
            incomingClock.overlapElapsed(atSource: source - p.inPoint, within: overlap)
        }

        // --- Where the seam goes.
        //
        // The seam *instant* is the plan's, and the plan's is the outgoing
        // track's: the out point came out of the candidate list, the climax
        // guard and the lyric snap, and nothing here has a vote on it. What is
        // decided below is which bar of the **incoming** song that instant
        // falls on — which, because the incoming deck has been running silently
        // since the top of the overlap, is the whole question of what the slam
        // sounds like it is arriving at.
        //
        // Two ways to answer it, in order:
        //
        //   1. **the aim** (P2, predev §2.3). The planner already composed the
        //      entry backwards from a drop / chorus / core start, so that grid
        //      point is *at* the swap by construction; the compiler only has to
        //      honour it exactly rather than re-derive it. This is the whole
        //      point of the layer: the cut lands on the thing the listener came
        //      for, not on the nearest available bar line.
        //   2. **the phrase line** (P1's placement, and the degradation path).
        //      With no aim — no structure on the incoming track, or a gate that
        //      refused the aimed entry — the seam starts from the plan's own
        //      swap point and is snapped onto the nearest four-bar phrase line
        //      counted from the in point, falling back to the nearest downbeat.
        //      A cut is a cut on the one or it is nothing.
        //
        // Nothing constrains the seam's position beyond that, because a score
        // that owns the gain law replaces the crossfade rather than sitting on
        // it — there is no fader to compensate at any offset.
        //
        // **Where bar 0 is, before it is snapped to anything.**
        //
        // A score that ends the outgoing track pins bar 0 to the bass swap —
        // the seam, the one, the instant the cut happens. A score that only
        // *decorates* a blend has no seam to pin to: `bedIntro` is built around
        // the moment the incoming singer joins, and on a `dropAlign` hand-over
        // that moment is the end of the overlap, where P2's aim put the drop.
        // Same machinery, same snapping, same self-checks; one different
        // anchor, taken from the aim rather than invented here.
        let origin: TransitionAim.Landing = score.ownsSeam
            ? .seam
            : (planned.style.aim?.landing ?? .seam)
        let originOffsetWanted = origin == .seam ? geometry.swapOffset : overlap
        let swapSource = incomingSource(originOffsetWanted)
        guard var seamIndex = nearestIndex(inDownbeats, to: swapSource) else {
            return refuse("入曲没有小节线可以对齐。")
        }
        let inBar = barSeconds(inDownbeats, around: seamIndex, bpm: incoming.bpm)
        guard abs(inDownbeats[seamIndex] - swapSource) <= inBar * seamSnapBars else {
            return refuse(String(format: "交接点附近 %.2f 秒内没有入曲的小节线（最近的差 %.2f 秒）。",
                                 inBar * seamSnapBars, abs(inDownbeats[seamIndex] - swapSource)))
        }
        var degradations: [String] = []
        var aim = planned.style.aim
        var aimNote = planned.style.aimDetail
        if let wanted = aim {
            // The aim's own bar line, and a sanity check that it really is the
            // instant this geometry hands over on. It is, whenever the plan is
            // the one the aim was computed for; a plan override that moved the
            // seam afterwards is the case this catches, and the answer there is
            // P1's placement rather than a cut aimed at a bar that has drifted
            // out of the window.
            let aimed = nearestIndex(inDownbeats, to: wanted.time)
            if let aimed, abs(inDownbeats[aimed] - swapSource) <= inBar * aimSnapBars {
                seamIndex = aimed
            } else {
                degradations.append(String(
                    format: "瞄准点 %@ 落在交接点 %.2f 秒之外，这一刀改回按乐句线对齐。",
                    wanted.label,
                    aimed.map { abs(inDownbeats[$0] - swapSource) } ?? .infinity))
                aim = nil
                aimNote = "the aim no longer described this geometry"
            }
        }
        if aim == nil, let entry = nearestIndex(inDownbeats, to: p.inPoint) {
            let lo = Swift.max(0, seamIndex - phraseSnapBars)
            let hi = Swift.min(inDownbeats.count - 1, seamIndex + phraseSnapBars)
            let phrased = (lo...Swift.max(lo, hi))
                .filter { ($0 - entry) % phraseBars == 0 }
                .min { abs(inDownbeats[$0] - swapSource) < abs(inDownbeats[$1] - swapSource) }
            if let phrased { seamIndex = phrased }
        }
        let seamIncoming = inDownbeats[seamIndex]
        let edge = WholeMixLane.cutEdgeSeconds
        // A decorating score's origin is *supposed* to sit on the far edge of
        // the overlap — that is what "the singer joins on the drop, and the
        // drop is where the blend completes" means — so the trailing guard is
        // a cut's guard and applies to cuts only. It still has to be inside the
        // window, and snapping to a bar line can push it a hair past the end.
        let seamOffset = min(incomingOverlapTime(seamIncoming), overlap)
        guard seamOffset > edge * 4 else {
            return refuse(String(format: "对齐后的 bar 0 落在 +%.2f 秒，贴着叠加的开头，摆不下手势。",
                                 seamOffset))
        }
        if score.ownsSeam {
            guard seamOffset < overlap - edge * 4 else {
                return refuse(String(format: "对齐后的 seam 落在 +%.2f 秒，贴着叠加的边缘，切不出来。",
                                     seamOffset))
            }
        } else {
            guard incomingOverlapTime(seamIncoming) <= overlap + inBar * 0.5 else {
                return refuse(String(format: "落点 +%.2f 秒落在叠加（%.2f 秒）之外，"
                                     + "垫子没有可以铺的地方。",
                                     incomingOverlapTime(seamIncoming), overlap))
            }
        }
        let seamOutgoing = outgoingSource(seamOffset)

        // --- Grid self-check, both sides: a cut on a drifting grid is a cut on
        // the wrong beat, and the drift is measurable before anything is
        // rendered.
        let jitterLimit = gridJitterTolerance
            * (score.ownsSeam ? 1 : decoratingJitterMultiple)
        for (label, grid, at) in [("出曲", outDownbeats, seamOutgoing),
                                  ("入曲", inDownbeats, seamIncoming)] {
            guard let jitter = worstJitter(grid, around: at, bars: gridCheckBars)
            else { continue }
            guard jitter <= jitterLimit else {
                return refuse(String(format: "%@在交接点附近的小节长度抖动 %.1f%%，超过 %.1f%% 的上限，"
                                     + "格点不可信。", label, jitter * 100,
                                     jitterLimit * 100))
            }
        }

        // --- Grid coverage: the score's whole span has to exist on the grids.
        guard let outSeamIndex = nearestIndex(outDownbeats, to: seamOutgoing) else {
            return refuse("出曲没有小节线可以对齐。")
        }
        guard outSeamIndex - score.preBars >= 0,
              seamIndex + score.postBars < inDownbeats.count else {
            return refuse("乐谱要用到的小节超出了拍网格的范围。")
        }
        let outBar = barSeconds(outDownbeats, around: outSeamIndex, bpm: outgoing.bpm)

        /// A grid position, in overlap-relative seconds. Nil when the grid does
        /// not reach it — which invalidates the score, not just the event.
        func place(_ position: GridPosition) -> TimeInterval? {
            // Bar 0 beat 0 *is* the origin, and the origin has already been
            // resolved (and, for a decorating score, clamped to the end of the
            // window). Re-deriving it here would be a second answer to a
            // question that has one.
            if position == .seam { return seamOffset }
            if position.bar >= 0 {
                let index = seamIndex + position.bar
                guard index >= 0, index < inDownbeats.count else { return nil }
                let beat = (inBar / Double(TransitionScore.beatsPerBar)) * position.beat
                return incomingOverlapTime(inDownbeats[index] + beat)
            }
            let index = outSeamIndex + position.bar
            guard index >= 0, index < outDownbeats.count else { return nil }
            let beat = (outBar / Double(TransitionScore.beatsPerBar)) * position.beat
            return outgoingOverlapTime(outDownbeats[index] + beat)
        }

        // --- The tension cut's one rule, re-checked where the aim is final.
        //
        // `ScoreTemplate` only offered this score because the planner's aim
        // said drop or chorus. Between there and here the aim can be dropped —
        // a plan override moved the seam, and the compiler fell back to phrase
        // placement above — and a beat of silence in front of a bar line
        // nobody was waiting for is the predev's malfunction, not a smaller
        // gesture. So the silence degrades out and the cut plays alone, said
        // out loud, exactly as an unearned echo throw does.
        func isSilence(_ scored: ScoredEvent) -> Bool {
            if case .silence = scored.event { return true }
            return false
        }
        var events = score.events
        if events.contains(where: isSilence),
           aim?.target != .drop, aim?.target != .chorus {
            events.removeAll(where: isSilence)
            degradations.append(
                "这一刀最后没有落在 drop / 副歌上（\(TransitionAim.report(aim, reason: aimNote))），"
                + "一拍静默降级掉——落拍前的空白只有在听众等着什么的时候才是张力，"
                + "否则那是播放器坏了。")
        }

        var placed: [Placed] = []
        for scored in events {
            guard let offset = place(scored.at) else {
                return refuse("格点 bar \(scored.at.bar) 落在拍网格之外，整谱作废。")
            }
            guard offset >= 0, offset <= overlap else {
                return refuse(String(format: "格点 bar %d 落在叠加窗口之外（+%.2f 秒，窗口 0–%.2f 秒），"
                                     + "整谱作废。", scored.at.bar, offset, overlap))
            }
            placed.append(Placed(event: scored.event.label, at: scored.at, offset: offset))
        }

        // --- The echo throw's anchor, and the discipline P2 puts on it.
        //
        // P1 threw whatever the last line end before the seam was, however far
        // back it sat, so **every** score came out carrying a throw — which is
        // the second half of the field verdict on the first three scored seams.
        // Two things are wrong with a throw at an arbitrary line end. A line
        // that ended eight beats ago leaves the delay wide open over eight
        // beats of dry outgoing track: that is an `.echoOut` wash, not a throw,
        // and it muddies the bars the cut is supposed to be sharpening. And a
        // line the singer is still in the middle of at the seam is the worst
        // offender of all — a half-sung phrase smeared into a delay is the one
        // thing a listener will notice and dislike.
        //
        // So the throw has to be *earned*: the outgoing track's last line end
        // must land within a beat of the throw point, which is the seam itself.
        // Within a beat either side is the gesture — the singer finishes on the
        // one and the tail rings on over the new track. Anywhere else and this
        // is a cut, cleanly and by name.
        var directive: EchoThrowDirective?
        var echoLine: String?
        if events.contains(where: { $0.event == .echoThrow }) {
            let sourceBeat = outBar / Double(TransitionScore.beatsPerBar)
            let delayTime = min(max(sourceBeat / outRate * echoDelayBeatFraction, 0.05), 2.0)
            let window = sourceBeat * echoThrowQualifyBeats
            let margin = echoThrowMarginSeconds * outRate
            let anchor = lineEnd(nearest: seamOutgoing, within: window,
                                 outgoingURL: outgoingURL,
                                 notBefore: p.outPoint + margin)
            if let anchor {
                // A line that ends *after* the seam has nothing left to throw
                // by the time the cut happens, so the delay is engaged just
                // before the edge instead. Within the qualifying window this is
                // at most one beat of difference and it keeps the tail audible.
                let engageAt = Swift.min(anchor.end, seamOutgoing - margin)
                directive = EchoThrowDirective(
                    throwAt: outgoingOverlapTime(engageAt), delayTime: delayTime)
                echoLine = anchor.text
            } else {
                degradations.append(String(
                    format: "出曲的末句行尾不在 seam 前后 %.2f 秒（一拍）内，echo throw 降级为直切"
                        + "——甩一句唱了一半的词比不甩更冒犯。", window))
            }
        }

        // A throw that did not qualify leaves a **cut**, and it is named as
        // one: a report that still said "cutOnOne+echoThrow" would be
        // describing a gesture the listener did not hear. Same for a silence
        // that degraded out above — so the label is built from what is actually
        // going to be performed rather than from what was asked for.
        if directive == nil {
            events = events.map {
                $0.event == .echoThrow ? ScoredEvent(at: $0.at, .cutOut) : $0
            }
        }
        let performed = TransitionScore(preBars: score.preBars, postBars: score.postBars,
                                        events: events)

        // --- The gain law.
        //
        // Two shapes, and which one a score gets is decided by whether it ends
        // the outgoing track (`ownsSeam`), not by which gestures are in it. A
        // cut replaces the blend: both decks' automation is neutralized and
        // these two lanes say everything. A bed rides on top of the blend the
        // planner already made, so it writes no whole-mix lane at all — its
        // whole content is one muted stem lane, below.
        var lanes = WholeMixLanes(ownsGainLaw: score.ownsSeam)
        var stemEnvelope: StemEnvelope?

        if score.ownsSeam {
            // **The tension cut, as arithmetic.** The silence is a span ending
            // on the seam, so performing it is not a new mechanism — it is the
            // outgoing lane's cut edge, moved back N beats. The beat is the
            // outgoing song's own bar over four, divided by the rate it is bent
            // to, which is what makes "exactly one beat" true in the rendered
            // file rather than in the score's intentions.
            var cutAt = seamOffset
            var silenceBeats: Double?
            for scored in events {
                guard case .silence(let beats) = scored.event else { continue }
                let outBeat = outBar / Double(TransitionScore.beatsPerBar)
                cutAt = outgoingOverlapTime(seamOutgoing - beats * outBeat)
                silenceBeats = beats
            }
            if let silenceBeats, cutAt - edge <= 0 {
                return refuse(String(format: "%g 拍的静默要从 +%.2f 秒开始，那时候叠加还没开始，"
                                     + "整谱作废。", silenceBeats, cutAt))
            }
            lanes.outgoing = WholeMixLane([
                .init(t: 0, gainDB: 0),
                .init(t: cutAt - edge, gainDB: 0),
                .init(t: cutAt, gainDB: WholeMixLane.minGainDB),
                .init(t: overlap, gainDB: WholeMixLane.minGainDB),
            ])

            // **The slam, as arithmetic.** The incoming lane rises where the
            // `slamIn` event says and nowhere else. With no slam in the score
            // the same lane rises over a bar starting at the cut — the control
            // arm — so the difference between the two renders is one lane's
            // middle two breakpoints and nothing else in the whole pipeline.
            let slamAt = placed.first { $0.event == ScoreEvent.slamIn.label }?.offset
            if let slamAt {
                lanes.incoming = WholeMixLane([
                    .init(t: 0, gainDB: WholeMixLane.minGainDB),
                    .init(t: slamAt - edge, gainDB: WholeMixLane.minGainDB),
                    .init(t: slamAt, gainDB: 0),
                    .init(t: overlap, gainDB: 0),
                ])
            } else {
                let rise = min(softEntryBars * inBar / inRate, max(0, overlap - cutAt))
                lanes.incoming = WholeMixLane([
                    .init(t: 0, gainDB: WholeMixLane.minGainDB),
                    .init(t: cutAt, gainDB: WholeMixLane.minGainDB),
                    .init(t: cutAt + rise, gainDB: 0),
                    .init(t: overlap, gainDB: 0),
                ])
            }
            lanes.echoThrow = directive
        }

        // **The bed, as a stem lane.** The only gesture in the library that
        // needs a separator, and the only one whose compile can hand back
        // something other than gain on a whole mix.
        for scored in events {
            guard case .bedIntro(let bars) = scored.event,
                  let landing = placed.first(where: { $0.at == scored.at
                                                      && $0.event == scored.event.label })?.offset
            else { continue }
            let barSecondsOnTheClock = inBar / inRate
            guard landing >= barSecondsOnTheClock * 0.99 else {
                return refuse(String(format: "人声进入点落在 +%.2f 秒，连一小节垫子都铺不下，整谱作废。",
                                     landing))
            }
            let wanted = Double(bars) * barSecondsOnTheClock
            guard landing <= wanted + bedOverrunBars * barSecondsOnTheClock else {
                return refuse(String(format: "这次叠加要垫 %.2f 秒，比 %d 小节的伴奏垫（%.2f 秒）"
                                     + "长得多；从头压住入曲人声就不是这个手势了，整谱作废。",
                                     landing, bars, wanted))
            }
            var envelope = StemEnvelope()
            var points: [StemEnvelope.Breakpoint] = [
                .init(t: 0, gainDB: StemEnvelope.minGainDB),
                .init(t: max(0, landing - bedVocalRampSeconds), gainDB: StemEnvelope.minGainDB),
                .init(t: landing, gainDB: 0),
            ]
            if landing < overlap - 1e-6 { points.append(.init(t: overlap, gainDB: 0)) }
            envelope.incomingVocal = points
            stemEnvelope = envelope
        }

        return Compilation(
            label: performed.label, origin: origin, seamOffset: seamOffset,
            seamOutgoing: seamOutgoing, seamIncoming: seamIncoming,
            seamSnapSeconds: seamOffset - originOffsetWanted,
            aim: aim, aimNote: aimNote,
            events: placed, echoThrow: directive, echoLine: echoLine,
            degradations: degradations, lanes: lanes,
            stemEnvelope: stemEnvelope, runwayClass: score.runwayClass,
            refusalReason: nil)
    }

    // MARK: - Grid helpers

    /// Index of the entry nearest `t`; nil for an empty grid.
    static func nearestIndex(_ grid: [TimeInterval], to t: TimeInterval) -> Int? {
        guard !grid.isEmpty else { return nil }
        var best = 0
        var bestDistance = abs(grid[0] - t)
        for i in 1..<grid.count {
            let d = abs(grid[i] - t)
            if d < bestDistance { best = i; bestDistance = d }
            // The grid is ascending, so once it starts walking away it is done.
            else if grid[i] > t { break }
        }
        return best
    }

    /// One bar in seconds, measured on the grid itself around `index` and
    /// falling back to the analysis tempo where the grid cannot say.
    static func barSeconds(_ downbeats: [TimeInterval], around index: Int,
                           bpm: Double) -> TimeInterval {
        let fallback = bpm > 1 ? 60 / bpm * Double(TransitionScore.beatsPerBar) : 2
        guard downbeats.count > 1 else { return fallback }
        let i = max(0, min(downbeats.count - 2, index))
        let measured = downbeats[i + 1] - downbeats[i]
        return measured > 0.2 && measured < 12 ? measured : fallback
    }

    /// The worst relative deviation between bar lengths in a window of `bars`
    /// either side of `t`, or nil when there are too few bars there to judge.
    static func worstJitter(_ downbeats: [TimeInterval], around t: TimeInterval,
                            bars: Int) -> Double? {
        guard let index = nearestIndex(downbeats, to: t) else { return nil }
        let lo = Swift.max(0, index - bars)
        let hi = Swift.min(downbeats.count - 1, index + bars)
        guard hi - lo >= 3 else { return nil }
        var intervals: [TimeInterval] = []
        for i in lo..<hi where downbeats[i + 1] > downbeats[i] {
            intervals.append(downbeats[i + 1] - downbeats[i])
        }
        guard intervals.count > 2 else { return nil }
        let median = intervals.sorted()[intervals.count / 2]
        guard median > 1e-6 else { return nil }
        return intervals.map { abs($0 - median) / median }.max()
    }

    /// The outgoing lyric line end nearest `seam`, and only if it is inside
    /// `within` seconds of it — the throw's qualification (see the call site).
    ///
    /// `notBefore` keeps the anchor inside the rendered window: a throw engaged
    /// before the overlap started cannot be played.
    static func lineEnd(nearest seam: TimeInterval, within: TimeInterval,
                        outgoingURL: URL?,
                        notBefore: TimeInterval) -> (end: TimeInterval, text: String)? {
        guard let outgoingURL, let lines = Audition.Lyrics.load(for: outgoingURL),
              !lines.isEmpty else { return nil }
        let ends = Audition.Lyrics.lineEnds(lines)
        var best: (end: TimeInterval, text: String)?
        for (line, end) in zip(lines, ends)
        where end >= notBefore && abs(end - seam) <= within {
            if best == nil || abs(end - seam) < abs(best!.end - seam) {
                best = (end, line.text)
            }
        }
        return best
    }
}
