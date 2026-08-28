import Foundation

// The `vocalExchange` template: from "these two are both singing" to four
// scheduled gain curves.
//
// The planner can decide that a pair *wants* a vocal hand-off — that is a rule
// about two vocal-activity contours, and it has both. It cannot decide *where*
// the hand-off goes, because that is a question about a sung phrase: the
// outgoing singer should finish the line, and the line ends where the next
// lyric timestamp says it does. `TransitionPlanner` is a pure function of two
// `TrackAnalysis` values and has never heard a word. So the planner emits
// `.vocalExchange` as a marker and this compiles it, here in the decision
// layer, where the `.lrc` sidecar is one file read away.
//
// Everything it produces is a plain `StemEnvelope`. There is no
// "exchange renderer": the template is one producer of the general contract,
// exactly like an AI's hand-written `stemEnvelope`, and the renderer cannot
// tell them apart.

extension Audition {

    /// What compiling a `.vocalExchange` came to, in enough detail for the
    /// console to say *why* the hand-over landed where it did.
    public struct ExchangeCompilation: Sendable, Equatable {
        /// Seconds into the overlap where the vocal changes hands.
        public let handover: TimeInterval
        /// The same instant in the outgoing track's own timeline.
        public let handoverAbsolute: TimeInterval
        /// `"lyric"` — a lyric line ends here; `"vocalTrough"` — no usable
        /// lyrics, so the outgoing vocal contour's quietest mid-overlap second;
        /// `"duck"` — neither was available and the technique degraded.
        public let source: String
        /// The outgoing line the singer finishes on, when `source == "lyric"`.
        public let lyricLine: String?
        /// Where the clamp moved the raw candidate to, if it did.
        public let clampedFrom: TimeInterval?
        /// Why the compile degraded to `.vocalDuck`, phrased for the console.
        public let fallbackReason: String?
        /// The compiled curves; nil exactly when `fallbackReason` is set.
        public let envelope: StemEnvelope?
    }

    enum VocalExchange {

        // MARK: - Template shape
        //
        // The numbers below are the template's whole taste, so they are named
        // and justified rather than sprinkled through the builder.

        /// The outgoing bed steps back early so the incoming one has somewhere
        /// to go — a bed swap that waits for the vocal swap makes the middle of
        /// the overlap the loudest part of it.
        ///
        /// −3 dB rather than the −9 the first draft used, and −8 rather than
        /// −30 at the hand-over, because of what the corpus said. Measured on
        /// 恋愛サーキュレーション → 春を告げる at a 16 s overlap, the −9/−30
        /// shape put an 11 dB crater in the middle of the hand-over (against
        /// 3 dB for the plain crossfade of the same seam): the outgoing deck is
        /// already being faded, so −30 dB of bed on top of that is silence, and
        /// the incoming track's opening bars there are *vocal-dominated* — with
        /// the incoming vocal correctly muted until the hand-over, almost
        /// nothing was left holding the middle up. The bed's job before the
        /// hand-over is not to get out of the way (the fader does that); it is
        /// to keep a floor under the outgoing singer until the singer leaves.
        /// So it steps back audibly and only collapses once the vocal has gone.
        /// The ablation, worst 1 s window relative to the take's own opening:
        /// −9/−30 −11.1 dB, −3/−8 −9.8 dB, −3/−8 with the incoming bed lift
        /// below −8.8 dB, plain crossfade −3.2 dB.
        static let bedEarlyShare: Double = 0.4
        static let bedEarlyDB: Float = -3
        static let bedAtHandoverDB: Float = -8
        /// Once the outgoing vocal has retired the bed follows it out, −30 dB
        /// (under any bed) and then away.
        static let bedRetiredDB: Float = -30
        static let bedAfterHandoverDB: Float = -40
        /// How long the outgoing vocal takes to leave once its line is done.
        /// Shorter reads as a cut; much longer and it is still there when the
        /// new singer arrives, which is the pile-up this whole technique exists
        /// to prevent.
        static let outgoingRetireSeconds: TimeInterval = 0.8
        /// The incoming bed comes in at its own level — the incoming fader is
        /// near zero at the top of the overlap, so an extra attenuation there
        /// buys nothing and measurably costs energy later — and is then pushed
        /// `incomingBedLiftDB` up over the stretch where it is the *only* bed
        /// under the outgoing singer (the outgoing bed has stepped back and the
        /// incoming vocal is still muted), releasing back to its own level as
        /// soon as the new vocal arrives to sit on it. Worth 1–2 dB exactly
        /// where the corpus ablation found the hand-over thinnest.
        static let incomingBedLiftShare: Double = 0.5
        static let incomingBedLiftDB: Float = 3
        /// The incoming vocal is inaudible until the hand-over (−40 dB), lifts
        /// to −30 dB *at* it, and is at full level a second later.
        static let incomingVocalMutedDB: Float = -40
        static let incomingVocalAtHandoverDB: Float = -30
        static let incomingRiseSeconds: TimeInterval = 1.0
        /// A short shelf before the hand-over so the muted lane's last
        /// breakpoint is not also its first — purely so the curve reads.
        static let incomingHoldSeconds: TimeInterval = 0.6
        /// How many points the compensated outgoing-vocal hold is sampled on.
        /// The compensation follows an equal-power cosine; six points across
        /// it are within ~0.2 dB of the continuous curve.
        static let holdSamples = 6

        /// Ceiling on how far a lane may be lifted to cancel the fade it is
        /// riding on — the same ceiling `StemTechniqueLayer.acapellaGainCeiling`
        /// puts on the acapella, and `StemEnvelope`'s own maximum.
        static let compensationCeilingDB: Float = StemEnvelope.maxGainDB

        // MARK: - Compilation

        /// Compile `.vocalExchange` for one hand-over.
        ///
        /// Returns the technique the render should actually use — `.custom`
        /// with the compiled curves, or `.vocalDuck` when there was nothing to
        /// aim at — together with the story of how it got there.
        static func compile(outgoingURL: URL, outgoing: TrackAnalysis,
                            planned: PlannedTransition,
                            config: TransitionPlanner.Config)
            -> (technique: StemTechnique, compilation: ExchangeCompilation) {
            let geometry = TransitionAutomation.Geometry(plan: planned.plan)
            let overlap = geometry.overlapDuration
            let outPoint = planned.plan.outPoint ?? 0

            func degrade(_ reason: String) -> (StemTechnique, ExchangeCompilation) {
                (.vocalDuck(depthDB: Float(-abs(config.stemDuckDepthDB))),
                 ExchangeCompilation(handover: 0, handoverAbsolute: outPoint,
                                     source: "duck", lyricLine: nil, clampedFrom: nil,
                                     fallbackReason: reason, envelope: nil))
            }

            guard overlap > 1 else {
                return degrade("这次叠加只有 \(String(format: "%.2f", overlap)) 秒，"
                               + "排不下一次人声交接，已降级为 vocal duck。")
            }

            let low = overlap * min(config.stemExchangeHandoverMin,
                                    config.stemExchangeHandoverMax)
            let high = overlap * max(config.stemExchangeHandoverMin,
                                     config.stemExchangeHandoverMax)

            var handover: TimeInterval
            var source: String
            var line: String?
            var clampedFrom: TimeInterval?

            if let pick = lyricHandover(outgoingURL: outgoingURL, outgoing: outgoing,
                                        outPoint: outPoint, overlap: overlap) {
                handover = pick.seconds
                source = "lyric"
                line = pick.line
            } else if let trough = vocalTrough(outgoing, outPoint: outPoint,
                                               from: low, to: high) {
                handover = trough
                source = "vocalTrough"
            } else {
                return degrade("这首出曲既没有 .lrc 歌词，也没有可用的人声活跃度曲线，"
                               + "定不出交接句，已降级为 vocal duck。")
            }

            let clamped = Swift.min(Swift.max(handover, low), high)
            if abs(clamped - handover) > 1e-6 { clampedFrom = handover }
            handover = clamped

            let envelope = template(overlap: overlap, handover: handover,
                                    plan: planned.plan, style: planned.style,
                                    geometry: geometry)
            return (.custom(envelope),
                    ExchangeCompilation(handover: handover,
                                        handoverAbsolute: outPoint + handover,
                                        source: source, lyricLine: line,
                                        clampedFrom: clampedFrom,
                                        fallbackReason: nil, envelope: envelope))
        }

        // MARK: - Where the phrase ends

        /// The outgoing lyric line-end nearest the middle of the overlap.
        ///
        /// A line *ends* where the next one starts — an `.lrc` only stamps
        /// beginnings — so this walks pairs. The final line has no successor,
        /// and gets the point where the vocal contour has fallen away instead,
        /// which is the same question asked of a different signal.
        static func lyricHandover(outgoingURL: URL, outgoing: TrackAnalysis,
                                  outPoint: TimeInterval, overlap: TimeInterval)
            -> (seconds: TimeInterval, line: String)? {
            guard let lines = Lyrics.load(for: outgoingURL), !lines.isEmpty else { return nil }
            var ends: [(end: TimeInterval, text: String)] = []
            for (index, line) in lines.enumerated() {
                if index + 1 < lines.count {
                    ends.append((lines[index + 1].time, line.text))
                } else if let decay = vocalDecay(outgoing, after: line.time) {
                    ends.append((decay, line.text))
                }
            }
            let middle = outPoint + overlap / 2
            // Only ends that actually fall inside this overlap are candidates:
            // clamping a line-end from a minute away would produce a number
            // that is not a phrase boundary at all, which is worse than saying
            // "no lyrics here" and letting the contour decide.
            let inside = ends.filter { $0.end >= outPoint && $0.end <= outPoint + overlap }
            guard let best = inside.min(by: {
                abs($0.end - middle) < abs($1.end - middle)
            }) else { return nil }
            return (best.end - outPoint, best.text)
        }

        /// Where the vocal contour has dropped to 60 % of its level at `time` —
        /// the last line's stand-in for "the next line's timestamp".
        static func vocalDecay(_ a: TrackAnalysis, after time: TimeInterval,
                               within limit: TimeInterval = 12) -> TimeInterval? {
            let grid = a.vocalActivity
            guard !grid.isEmpty else { return nil }
            let start = Int(time.rounded())
            guard start >= 0, start < grid.count else { return nil }
            let reference = grid[start]
            guard reference > 0 else { return time }
            let last = Swift.min(grid.count - 1, start + Int(limit))
            guard start < last else { return nil }
            for i in (start + 1)...last where grid[i] < reference * 0.6 {
                return TimeInterval(i)
            }
            return nil
        }

        /// The quietest second of the outgoing vocal contour inside the
        /// hand-over window — where a singer is least likely to be mid-word.
        static func vocalTrough(_ a: TrackAnalysis, outPoint: TimeInterval,
                                from low: TimeInterval, to high: TimeInterval) -> TimeInterval? {
            let grid = a.vocalActivity
            guard !grid.isEmpty, high > low else { return nil }
            // Walk the contour's own 1 s grid rather than a window-relative
            // one, so the answer is an instant the signal actually has a
            // measurement for.
            let first = Swift.max(0, Int((outPoint + low).rounded(.up)))
            let last = Swift.min(grid.count - 1, Int((outPoint + high).rounded(.down)))
            guard first <= last else { return nil }
            var best: (t: TimeInterval, v: Float)?
            for i in first...last where best == nil || grid[i] < best!.v {
                best = (TimeInterval(i) - outPoint, grid[i])
            }
            return best?.t
        }

        // MARK: - The curves

        /// The four lanes, for one overlap and one hand-over instant.
        ///
        /// The two vocal lanes are **fade-compensated**: an envelope stacks on
        /// top of the deck fader, and the whole point of the technique is that
        /// the outgoing singer finishes the line at full voice rather than
        /// receding through an equal-power fade while doing it. So the lane
        /// carries the inverse of the fader it will be multiplied by, sampled
        /// here at compile time where the plan, the style and therefore the
        /// exact fade law are all known — and capped at
        /// `compensationCeilingDB`, past which "hold the level" would just be
        /// amplifying a nearly-gone deck.
        static func template(overlap: TimeInterval, handover h: TimeInterval,
                             plan: TransitionPlan, style: TransitionStyle,
                             geometry: TransitionAutomation.Geometry) -> StemEnvelope {
            func faders(_ t: TimeInterval) -> (out: Float, incoming: Float) {
                let f = TransitionAutomation.frame(plan: plan, style: style,
                                                   elapsed: Swift.min(Swift.max(t, 0), overlap),
                                                   geometry: geometry)
                return (f.outgoing.fader, f.incoming.fader)
            }
            func compensation(_ fader: Float) -> Float {
                guard fader > 0 else { return compensationCeilingDB }
                let db = Float(-20 * log10(Double(fader)))
                return Swift.min(compensationCeilingDB, Swift.max(0, db))
            }
            typealias Point = StemEnvelope.Breakpoint

            // --- Outgoing vocal: hold the *audible* level to the hand-over,
            //     then retire inside `outgoingRetireSeconds`.
            var outgoingVocal: [Point] = []
            for k in 0..<holdSamples {
                let t = h * Double(k) / Double(holdSamples - 1)
                outgoingVocal.append(Point(t: t, gainDB: compensation(faders(t).out)))
            }
            let retired = Swift.min(overlap, h + outgoingRetireSeconds)
            outgoingVocal.append(Point(t: retired, gainDB: StemEnvelope.minGainDB))
            if retired < overlap - 0.05 {
                outgoingVocal.append(Point(t: overlap, gainDB: StemEnvelope.minGainDB))
            }

            // --- Outgoing bed: steps back early so the incoming one can
            //     arrive, then follows the vocal out once it has gone.
            var outgoingBed: [Point] = [
                Point(t: 0, gainDB: 0),
                Point(t: h * bedEarlyShare, gainDB: bedEarlyDB),
                Point(t: h, gainDB: bedAtHandoverDB),
            ]
            if retired > h + 0.05 { outgoingBed.append(Point(t: retired, gainDB: bedRetiredDB)) }
            if retired < overlap - 0.05 {
                outgoingBed.append(Point(t: overlap, gainDB: bedAfterHandoverDB))
            }

            // --- Incoming bed: in first, and pushed up while it is the only
            //     bed holding the middle of the hand-over together.
            var incomingBed: [Point] = [Point(t: 0, gainDB: 0)]
            let lift = h * incomingBedLiftShare
            if lift > 0.05 {
                incomingBed.append(Point(t: lift, gainDB: incomingBedLiftDB))
                incomingBed.append(Point(t: h, gainDB: incomingBedLiftDB))
            }
            let released = Swift.min(overlap, h + incomingRiseSeconds)
            incomingBed.append(Point(t: released, gainDB: 0))
            if released < overlap - 0.05 { incomingBed.append(Point(t: overlap, gainDB: 0)) }

            // --- Incoming vocal: silent, then takes over.
            var incomingVocal: [Point] = [Point(t: 0, gainDB: incomingVocalMutedDB)]
            let hold = h - incomingHoldSeconds
            if hold > 0.05 { incomingVocal.append(Point(t: hold, gainDB: incomingVocalMutedDB)) }
            incomingVocal.append(Point(t: h, gainDB: incomingVocalAtHandoverDB))
            let risen = Swift.min(overlap, h + incomingRiseSeconds)
            incomingVocal.append(Point(t: risen,
                                       gainDB: compensation(faders(risen).incoming)))
            if risen < overlap - 0.05 {
                incomingVocal.append(Point(t: overlap,
                                           gainDB: compensation(faders(overlap).incoming)))
            }

            return StemEnvelope(outgoingVocal: outgoingVocal, outgoingBed: outgoingBed,
                                incomingVocal: incomingVocal, incomingBed: incomingBed)
        }
    }
}
