import Foundation

// The JSON the tuning console draws from: everything the decision turned on,
// plus the derivation that got there. `audition plan --json` prints it and
// `audition serve` answers it over HTTP; nothing here re-derives a decision,
// it only re-narrates the one `Audition.decide` already made.

extension Audition {

    // MARK: - Tunables, for the slider panel

    public struct ConfigField: Encodable, Sendable {
        public let name: String
        public let group: String
        public let blurb: String
        public let min: Double
        public let max: Double
        public let step: Double
        public let digits: Int
        /// The shipped value — what the console's "reset" and diff compare to.
        public let standard: Double
    }

    /// Every planner knob, in panel order.
    public static var configFields: [ConfigField] {
        TransitionPlanner.Config.fields.map {
            ConfigField(name: $0.name, group: $0.group, blurb: $0.blurb,
                        min: $0.min, max: $0.max, step: $0.step, digits: $0.digits,
                        standard: $0.read(.standard))
        }
    }

    public static var standardConfig: [String: Double] {
        TransitionPlanner.Config.standard.asDictionary
    }

    // MARK: - Report DTOs

    public struct TrackReport: Encodable, Sendable {
        public let name: String
        public let path: String
        public let duration: TimeInterval
        public let bpm: Double
        public let bpmConfidence: Double
        public let key: String?
        public let keyConfidence: Double
        public let introEnd: TimeInterval
        public let outroFadeStart: TimeInterval?
        /// 1 s RMS, scaled so the track's own peak is 1.
        public let rms: [Double]
        /// 1 s vocal-presence likelihood, 0–1 as analyzed.
        public let vocal: [Double]
        public let downbeats: [TimeInterval]
        /// Candidate mix points, best first (the console draws the top ones).
        public let phraseBoundaries: [TimeInterval]
    }

    public struct SignalMark: Encodable, Sendable {
        public let label: String
        public let value: Double
        /// Which knob this line is, so the console can link mark → slider.
        public let field: String
    }

    public struct SignalReport: Encodable, Sendable {
        public let id: String
        public let label: String
        public let value: Double?
        public let display: String
        public let axisMax: Double
        public let marks: [SignalMark]
        /// What this one signal, on its own, argues for.
        public let state: String
        public let verdict: String
    }

    public struct ChainStep: Encodable, Sendable {
        /// "gate" | "tier" | "key" | "beatmatch" | "overlap" | "vocals" | "style"
        public let stage: String
        public let title: String
        /// The rule, quoted the way the source states it.
        public let rule: String
        /// What the numbers made of it here.
        public let detail: String
        public let outcome: String
        /// Whether this rule actually changed the outcome.
        public let fired: Bool
    }

    public struct PlanReport: Encodable, Sendable {
        public let kind: String
        public let outPoint: TimeInterval?
        public let inPoint: TimeInterval?
        public let overlapDuration: TimeInterval
        public let overlapBars: Int?
        public let outgoingRate: Float?
        public let incomingRate: Float?
        /// The three numbers a crossfade length is the minimum of.
        public let tailCapacity: TimeInterval?
        public let intakeCapacity: TimeInterval?
        public let ceiling: TimeInterval?
        public let tierCap: TimeInterval
    }

    public struct StyleReport: Encodable, Sendable {
        public let description: String
        public let outroEffect: String
        public let stagedEQ: Bool
        public let echoDelayTime: TimeInterval?
        public let reason: String
    }

    public struct ConfigDiffEntry: Encodable, Sendable {
        public let name: String
        public let standard: Double
        public let current: Double
    }

    public struct DecisionReport: Encodable, Sendable {
        public let outgoing: TrackReport
        public let incoming: TrackReport
        public let signals: [SignalReport]
        public let rawTier: String
        public let tier: String
        public let demotedByKey: Bool
        public let chain: [ChainStep]
        public let plan: PlanReport
        public let style: StyleReport
        public let nearMisses: [String]
        public let overridden: Bool
        public let config: [String: Double]
        public let configDiff: [ConfigDiffEntry]
    }

    // MARK: - Building the report

    public static func report(_ d: Decision) -> DecisionReport {
        let c = d.resolvedConfig
        let out = d.outgoingAnalysis, inc = d.incomingAnalysis

        return DecisionReport(
            outgoing: track(out, url: d.outgoingURL),
            incoming: track(inc, url: d.incomingURL),
            signals: signalReports(d, config: c),
            rawTier: d.rawTier,
            tier: d.tier,
            demotedByKey: d.demotedByKey,
            chain: chain(d, config: c),
            plan: planReport(d, config: c),
            style: styleReport(d, config: c),
            nearMisses: d.nearMisses,
            overridden: d.overridden,
            config: d.config,
            configDiff: c.diffFromStandard.map {
                ConfigDiffEntry(name: $0.name, standard: $0.standard, current: $0.current)
            })
    }

    /// The report as pretty JSON — what `--json` prints and `/api/plan` returns.
    public static func reportJSON(_ d: Decision) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report(d))
    }

    // MARK: - Track curves

    private static let pitchNames =
        ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    private static func track(_ a: TrackAnalysis, url: URL) -> TrackReport {
        let peak = Double(a.rmsEnvelope.max() ?? 1)
        let scale = peak > 1e-9 ? peak : 1
        return TrackReport(
            name: url.lastPathComponent,
            path: url.path,
            duration: a.duration,
            bpm: a.bpm,
            bpmConfidence: a.bpmConfidence,
            key: a.keyPitchClass.map { "\(pitchNames[$0 % 12]) \(a.keyIsMinor ? "minor" : "major")" },
            keyConfidence: a.keyConfidence,
            introEnd: a.introEnd,
            outroFadeStart: a.outroFadeStart,
            rms: a.rmsEnvelope.map { Double($0) / scale },
            vocal: a.vocalActivity.map { Double($0) },
            // Whole-track grids get big; one downbeat every other bar is
            // plenty for a 900-px timeline.
            downbeats: thin(a.downbeats, to: 400),
            phraseBoundaries: Array(a.phraseBoundaries.prefix(60)))
    }

    private static func thin(_ xs: [TimeInterval], to limit: Int) -> [TimeInterval] {
        guard xs.count > limit, limit > 0 else { return xs }
        let stride = Int((Double(xs.count) / Double(limit)).rounded(.up))
        return xs.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
    }

    // MARK: - Signals

    private static func signalReports(
        _ d: Decision, config c: TransitionPlanner.Config
    ) -> [SignalReport] {
        func state(_ v: Double, neutral: Double, clash: Double) -> String {
            v > clash ? "clash" : (v > neutral ? "neutral" : "compatible")
        }

        var out: [SignalReport] = []

        // 1. Loudness
        let loud = d.loudnessGapDB
        out.append(SignalReport(
            id: "loudness", label: "响度差",
            value: loud, display: String(format: "%.2f dB", loud),
            axisMax: Swift.max(c.clashLoudnessDB * 1.6, loud * 1.15, 1),
            marks: [SignalMark(label: "neutral", value: c.neutralLoudnessDB,
                               field: "neutralLoudnessDB"),
                    SignalMark(label: "clash", value: c.clashLoudnessDB,
                               field: "clashLoudnessDB")],
            state: state(loud, neutral: c.neutralLoudnessDB, clash: c.clashLoudnessDB),
            verdict: loud > c.clashLoudnessDB
                ? String(format: "%.2f dB 越过 clash 线 %.2f — 独自判 clash", loud, c.clashLoudnessDB)
                : (loud > c.neutralLoudnessDB
                   ? String(format: "%.2f dB 越过 neutral 线 %.2f — 拒绝长混音", loud, c.neutralLoudnessDB)
                   : String(format: "%.2f dB 在 neutral 线 %.2f 之内 — 不反对", loud, c.neutralLoudnessDB))))

        // 2. Timbre
        let timbre = d.timbreDistance
        out.append(SignalReport(
            id: "timbre", label: "音色距离",
            value: timbre, display: String(format: "%.3f", timbre),
            axisMax: Swift.max(c.clashTimbreDistance * 1.6, timbre * 1.15, 0.2),
            marks: [SignalMark(label: "neutral", value: c.neutralTimbreDistance,
                               field: "neutralTimbreDistance"),
                    SignalMark(label: "clash", value: c.clashTimbreDistance,
                               field: "clashTimbreDistance")],
            state: state(timbre, neutral: c.neutralTimbreDistance, clash: c.clashTimbreDistance),
            verdict: timbre > c.clashTimbreDistance
                ? String(format: "%.3f 越过 clash 线 %.3f — 两首歌的频谱形状差得太远", timbre, c.clashTimbreDistance)
                : (timbre > c.neutralTimbreDistance
                   ? String(format: "%.3f 越过 neutral 线 %.3f — 只给短交接", timbre, c.neutralTimbreDistance)
                   : String(format: "%.3f 在 neutral 线 %.3f 之内 — 不反对", timbre, c.neutralTimbreDistance))))

        // 3. Tempo
        let tempoAxis = Swift.max(c.clashTempoRatio * 1.6, (d.tempoRatio ?? 0) * 1.15, 0.1)
        let tempoVerdict: String
        let tempoState: String
        if let r = d.tempoRatio {
            if r > c.clashTempoRatio {
                tempoState = "clash"
                tempoVerdict = String(format: "折叠后差 %.3f 越过 clash 线 %.3f — 判 clash", r, c.clashTempoRatio)
            } else if r > c.maxBPMDeltaRatio {
                tempoState = "compatible"
                tempoVerdict = String(format: "折叠后差 %.3f 超过对拍线 %.3f — 不判 clash，但拿不到 beat-match",
                                      r, c.maxBPMDeltaRatio)
            } else {
                tempoState = "compatible"
                tempoVerdict = String(format: "折叠后差 %.3f 在对拍线 %.3f 之内 — 可以对拍", r, c.maxBPMDeltaRatio)
            }
        } else {
            tempoState = "na"
            tempoVerdict = String(format: "至少一边 BPM 置信度不足 %.2f（出 %.2f / 入 %.2f）— 节奏不参与决策",
                                  c.bpmConfidenceThreshold,
                                  d.outgoingBPMConfidence, d.incomingBPMConfidence)
        }
        out.append(SignalReport(
            id: "tempo", label: "节奏差（折叠）",
            value: d.tempoRatio,
            display: d.tempoRatio.map { String(format: "%.3f", $0) } ?? "—",
            axisMax: tempoAxis,
            marks: [SignalMark(label: "beat-match", value: c.maxBPMDeltaRatio,
                               field: "maxBPMDeltaRatio"),
                    SignalMark(label: "clash", value: c.clashTempoRatio,
                               field: "clashTempoRatio")],
            state: tempoState, verdict: tempoVerdict))

        // 4. Key
        let keyState = (d.keyDistance ?? 0) >= c.clashKeyDistance ? "neutral" : "compatible"
        out.append(SignalReport(
            id: "key", label: "五度圈距离",
            value: d.keyDistance.map(Double.init),
            display: d.keyDistance.map(String.init) ?? "—",
            axisMax: 6,
            marks: [SignalMark(label: "demote", value: Double(c.clashKeyDistance),
                               field: "clashKeyDistance")],
            state: d.keyDistance == nil ? "na" : keyState,
            verdict: d.keyDistance == nil
                ? String(format: "至少一边调性置信度不足 %.2f — 和声不参与决策", c.keyConfidenceThreshold)
                : (d.keyDistance! >= c.clashKeyDistance
                   ? "距离 \(d.keyDistance!) ≥ \(c.clashKeyDistance) — 和声独自把 compatible 降为 neutral"
                   : "距离 \(d.keyDistance!) < \(c.clashKeyDistance) — 和声不反对")))

        // 5. Vocals
        let ov = d.outgoingVocalScore, iv = d.incomingVocalScore
        let bothHot = (ov ?? 0) > c.vocalClashRatio && (iv ?? 0) > c.vocalClashRatio
        out.append(SignalReport(
            id: "vocals", label: "人声活跃度（出 / 入）",
            value: ov.flatMap { o in iv.map { Swift.min(o, $0) } },
            display: "\(ov.map { String(format: "%.2f", $0) } ?? "—") / "
                + "\(iv.map { String(format: "%.2f", $0) } ?? "—")",
            axisMax: Swift.max(c.vocalClashRatio * 1.8, (ov ?? 0) * 1.15, (iv ?? 0) * 1.15),
            marks: [SignalMark(label: "clash", value: c.vocalClashRatio,
                               field: "vocalClashRatio")],
            state: bothHot ? "clash" : "compatible",
            verdict: (ov == nil || iv == nil)
                ? "至少一边没有可用的人声轮廓（纯器乐或基线过低）— 人声门槛不生效"
                : (bothHot
                   ? String(format: "两边都在 %.2f 线之上 — 撞人声，叠加被砍到 %.2fs 以内",
                            c.vocalClashRatio, c.vocalClashFadeCap)
                   : String(format: "至少一边在 %.2f 线之下 — 不会双主唱重叠", c.vocalClashRatio))))

        return out
    }

    // MARK: - Derivation chain

    private static func chain(
        _ d: Decision, config c: TransitionPlanner.Config
    ) -> [ChainStep] {
        var steps: [ChainStep] = []
        let out = d.outgoingAnalysis, inc = d.incomingAnalysis

        // 0. Duration gate.
        let tooShort = out.duration < c.minTrackDuration || inc.duration < c.minTrackDuration
        steps.append(ChainStep(
            stage: "gate", title: "长度门槛",
            rule: "任一首短于 minTrackDuration → 整个 AutoMix 放弃，走 gapless",
            detail: String(format: "出 %.1fs / 入 %.1fs，门槛 %.0fs",
                           out.duration, inc.duration, c.minTrackDuration),
            outcome: tooShort ? "→ gapless，后续规则全部跳过" : "两首都够长，继续",
            fired: tooShort))
        if tooShort { return steps }

        // 1. Tier from the three signals.
        let s = d.signals
        var reasons: [String] = []
        if s.loudnessGapDB > c.clashLoudnessDB {
            reasons.append(String(format: "响度差 %.2f > %.2f", s.loudnessGapDB, c.clashLoudnessDB))
        }
        if s.timbreDistance > c.clashTimbreDistance {
            reasons.append(String(format: "音色 %.3f > %.3f", s.timbreDistance, c.clashTimbreDistance))
        }
        if (s.tempoRatio ?? 0) > c.clashTempoRatio {
            reasons.append(String(format: "节奏 %.3f > %.3f", s.tempoRatio ?? 0, c.clashTempoRatio))
        }
        var neutralReasons: [String] = []
        if s.loudnessGapDB > c.neutralLoudnessDB {
            neutralReasons.append(String(format: "响度差 %.2f > %.2f",
                                         s.loudnessGapDB, c.neutralLoudnessDB))
        }
        if s.timbreDistance > c.neutralTimbreDistance {
            neutralReasons.append(String(format: "音色 %.3f > %.3f",
                                         s.timbreDistance, c.neutralTimbreDistance))
        }
        let tierDetail: String
        if !reasons.isEmpty {
            tierDetail = reasons.joined(separator: "；")
        } else if !neutralReasons.isEmpty {
            tierDetail = neutralReasons.joined(separator: "；")
        } else {
            tierDetail = String(format: "响度 %.2f、音色 %.3f、节奏 %@ 全部在 neutral 线之内",
                                s.loudnessGapDB, s.timbreDistance,
                                s.tempoRatio.map { String(format: "%.3f", $0) } ?? "—")
        }
        steps.append(ChainStep(
            stage: "tier", title: "三信号定档",
            rule: "任一信号越 clash 线 → clash；否则响度或音色越 neutral 线 → neutral；都没越 → compatible",
            detail: tierDetail,
            outcome: "→ \(d.rawTier)",
            fired: d.rawTier != "compatible"))

        // 2. Key gate.
        if d.rawTier == "compatible" {
            steps.append(ChainStep(
                stage: "key", title: "调性门槛",
                rule: "两边调性都可信且五度圈距离 ≥ clashKeyDistance → compatible 降为 neutral（永不独自判 clash）",
                detail: d.keyDistance.map { "距离 \($0)，门槛 \(c.clashKeyDistance)" }
                    ?? String(format: "调性置信度不足 %.2f（出 %.2f / 入 %.2f），门槛不生效",
                              c.keyConfidenceThreshold, out.keyConfidence, inc.keyConfidence),
                outcome: d.demotedByKey ? "→ neutral（被和声降档）" : "维持 compatible",
                fired: d.demotedByKey))
        }

        // 3. Beat-match attempt (only tried at compatible).
        if d.tier == "compatible" {
            let confOK = out.bpmConfidence >= c.bpmConfidenceThreshold
                && inc.bpmConfidence >= c.bpmConfidenceThreshold
                && out.bpm > 0 && inc.bpm > 0
            var detail: String
            var outcome: String
            if !confOK {
                detail = String(format: "BPM 置信度 出 %.2f / 入 %.2f，门槛 %.2f",
                                out.bpmConfidence, inc.bpmConfidence, c.bpmConfidenceThreshold)
                outcome = "置信度不够 → 退回 crossfade"
            } else {
                let folded = [0.5, 1.0, 2.0].map { inc.bpm * $0 }
                    .min { abs($0 - out.bpm) < abs($1 - out.bpm) }!
                let delta = abs(folded - out.bpm) / out.bpm
                let target = (out.bpm + folded) / 2
                let outRate = target / out.bpm, inRate = target / folded
                let rateOK = abs(outRate - 1) <= c.maxRateDeviation + 1e-9
                    && abs(inRate - 1) <= c.maxRateDeviation + 1e-9
                detail = String(format: "%.1f → %.1f BPM（折叠到 %.1f），相对差 %.3f，门槛 %.3f；"
                                + "变速 %.4f / %.4f，上限 ±%.3f",
                                out.bpm, inc.bpm, folded, delta, c.maxBPMDeltaRatio,
                                outRate, inRate, c.maxRateDeviation)
                if delta > c.maxBPMDeltaRatio {
                    outcome = "BPM 差超过对拍线 → 退回 crossfade"
                } else if !rateOK {
                    outcome = "变速超过上限 → 退回 crossfade"
                } else if d.planKind == "beatMatched" {
                    outcome = "→ beatMatched，\(d.overlapBars ?? 0) 小节"
                } else {
                    outcome = "门槛都过了，但尾窗内没有能容下叠加的乐句边界 / 入点 → 退回 crossfade"
                }
            }
            steps.append(ChainStep(
                stage: "beatmatch", title: "对拍尝试",
                rule: "两边节奏可信、折叠后 BPM 差 ≤ maxBPMDeltaRatio、各自变速 ≤ maxRateDeviation，"
                    + "且尾窗内存在能装下 16/8/4 小节叠加的乐句边界",
                detail: detail, outcome: outcome,
                fired: d.planKind == "beatMatched"))
        } else {
            steps.append(ChainStep(
                stage: "beatmatch", title: "对拍尝试",
                rule: "只有 compatible 档才尝试 beat-match",
                detail: "当前档位 \(d.tier)",
                outcome: "跳过 → crossfade",
                fired: false))
        }

        // 4. Overlap length.
        if d.planKind == "crossfade" {
            let tierCap = cap(for: d.tier, config: c)
            let tail = TransitionPlanner.tailCapacity(out, config: c)
            let intake = TransitionPlanner.intakeCapacity(inc, inPoint: inc.introEnd, config: c)
            let ceiling = Swift.min(c.maxOverlap, tierCap,
                                    c.maxOverlapShare * Swift.min(out.duration, inc.duration))
            let raw = Swift.max(c.minOverlap, Swift.min(tail, intake, ceiling))
            let binding: String
            if raw <= c.minOverlap + 1e-9 { binding = "minOverlap 下限" }
            else if abs(raw - tail) < 1e-9 { binding = "出曲尾部承载力 tailCapacity" }
            else if abs(raw - intake) < 1e-9 { binding = "入曲开头吸收力 intakeCapacity" }
            else { binding = "档位上限 / 时长比例 ceiling" }
            steps.append(ChainStep(
                stage: "overlap", title: "叠加长度",
                rule: "叠加 = max(minOverlap, min(tailCapacity, intakeCapacity, "
                    + "min(maxOverlap, 档位上限, maxOverlapShare × 较短曲长)))",
                detail: String(format: "tail %.2fs · intake %.2fs · ceiling %.2fs"
                               + "（%@ 档上限 %.2fs）→ %.2fs",
                               tail, intake, ceiling, d.tier, tierCap, raw),
                outcome: "由 \(binding) 决定 → \(String(format: "%.2fs", raw))",
                fired: true))

            // 5. Vocal cap.
            let capped = raw > d.overlapDuration + 1e-6
            steps.append(ChainStep(
                stage: "vocals", title: "人声门槛",
                rule: "两边人声活跃度都 > vocalClashRatio → 叠加砍到 vocalClashFadeCap 以内",
                detail: "出 \(d.outgoingVocalScore.map { String(format: "%.2f", $0) } ?? "—")"
                    + " / 入 \(d.incomingVocalScore.map { String(format: "%.2f", $0) } ?? "—")"
                    + String(format: "，门槛 %.2f，砍到 %.2fs", c.vocalClashRatio, c.vocalClashFadeCap),
                outcome: capped
                    ? String(format: "撞人声 → 叠加从 %.2fs 砍到 %.2fs", raw, d.overlapDuration)
                    : String(format: "不撞 → 叠加保持 %.2fs", d.overlapDuration),
                fired: capped))
        }

        // 6. Style.
        steps.append(ChainStep(
            stage: "style", title: "手法",
            rule: styleRule(d.tier),
            detail: styleReport(d, config: c).reason,
            outcome: "→ \(d.styleDescription)",
            fired: true))
        if d.overridden {
            steps.append(ChainStep(
                stage: "style", title: "人工覆盖",
                rule: "--style / --fade 直接改写 planner 的选择",
                detail: "本次结果不是纯 planner 输出",
                outcome: "→ \(d.styleDescription), \(String(format: "%.2fs", d.overlapDuration))",
                fired: true))
        }
        return steps
    }

    private static func cap(for tier: String,
                            config c: TransitionPlanner.Config) -> TimeInterval {
        switch tier {
        case "neutral": return c.neutralOverlapCap
        case "clash": return c.clashOverlapCap
        default: return c.maxOverlap
        }
    }

    private static func styleRule(_ tier: String) -> String {
        switch tier {
        case "clash":
            return "clash：出曲节奏可信 → 附点八分的 echo-out 尾巴；否则素淡出"
        case "neutral":
            return "neutral：出曲没有自带的 outro fade → filterSweep 掏空退出；已经自己淡出的就不再扫"
        default:
            return "compatible：叠加 ≥ stagedEQMinOverlap → fade + 三段 EQ 交接；更短就素淡出"
        }
    }

    private static func planReport(
        _ d: Decision, config c: TransitionPlanner.Config
    ) -> PlanReport {
        var tail: TimeInterval?, intake: TimeInterval?, ceiling: TimeInterval?
        let tierCap = cap(for: d.tier, config: c)
        if d.planKind == "crossfade" {
            tail = TransitionPlanner.tailCapacity(d.outgoingAnalysis, config: c)
            intake = TransitionPlanner.intakeCapacity(
                d.incomingAnalysis, inPoint: d.incomingAnalysis.introEnd, config: c)
            ceiling = Swift.min(c.maxOverlap, tierCap,
                                c.maxOverlapShare * Swift.min(d.outgoingDuration,
                                                              d.incomingDuration))
        }
        return PlanReport(
            kind: d.planKind, outPoint: d.outPoint, inPoint: d.inPoint,
            overlapDuration: d.overlapDuration, overlapBars: d.overlapBars,
            outgoingRate: d.outgoingRate, incomingRate: d.incomingRate,
            tailCapacity: tail, intakeCapacity: intake, ceiling: ceiling, tierCap: tierCap)
    }

    private static func styleReport(
        _ d: Decision, config c: TransitionPlanner.Config
    ) -> StyleReport {
        let style = d.planned.style
        let effect: String
        switch style.outroEffect {
        case .fade: effect = "fade"
        case .filterSweep: effect = "filterSweep"
        case .echoOut: effect = "echoOut"
        }
        var reason: String
        if d.planKind == "beatMatched" {
            reason = "beat-match 一律走 fade + 三段 EQ 交接"
        } else if d.overridden {
            reason = "被 --style / --fade 覆盖"
        } else {
            switch d.tier {
            case "clash":
                reason = d.outgoingBPMConfidence >= c.keyConfidenceThreshold
                    && d.outgoingBPM > 0
                    ? String(format: "clash 且出曲 %.1f BPM 可信 → 附点八分延迟 %.0fms",
                             d.outgoingBPM,
                             (style.echoDelayTime ?? 0) * 1000)
                    : String(format: "clash 但出曲节奏置信度 %.2f 低于 %.2f → 素淡出",
                             d.outgoingBPMConfidence, c.keyConfidenceThreshold)
            case "neutral":
                reason = d.outgoingAnalysis.outroFadeStart == nil
                    ? "neutral 且出曲没有自带 outro fade → filterSweep 掏空退出"
                    : String(format: "neutral，但出曲 %.1fs 起已经自己淡出 → 不再扫，素淡出",
                             d.outgoingAnalysis.outroFadeStart ?? 0)
            default:
                reason = d.overlapDuration >= c.stagedEQMinOverlap
                    ? String(format: "compatible 且叠加 %.2fs ≥ %.2fs → fade + 三段 EQ",
                             d.overlapDuration, c.stagedEQMinOverlap)
                    : String(format: "compatible 但叠加 %.2fs < %.2fs → 素淡出",
                             d.overlapDuration, c.stagedEQMinOverlap)
            }
        }
        return StyleReport(description: d.styleDescription, outroEffect: effect,
                           stagedEQ: style.stagedEQ, echoDelayTime: style.echoDelayTime,
                           reason: reason)
    }
}
