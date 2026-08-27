import Foundation

// The tuning surface's description of `TransitionPlanner.Config`: one entry
// per knob, with the range a slider should span and the sentence that says
// what moving it does. Kept next to the audition facade rather than inside
// the planner because it exists purely for the tuning loop — the planner
// itself never reads it.
//
// Everything the web console shows is generated from this list, so adding a
// knob to `Config` and one row here is the whole change.

extension TransitionPlanner.Config {
    struct Field: Sendable {
        let name: String
        /// Which panel the console groups it under.
        let group: String
        /// One sentence: what does turning this up do?
        let blurb: String
        let min: Double
        let max: Double
        let step: Double
        /// Digits the console formats the value with.
        let digits: Int
        let read: @Sendable (TransitionPlanner.Config) -> Double
        let write: @Sendable (inout TransitionPlanner.Config, Double) -> Void
    }

    private static func field(
        _ name: String, _ group: String, _ blurb: String,
        _ min: Double, _ max: Double, _ step: Double, _ digits: Int = 2,
        _ path: WritableKeyPath<TransitionPlanner.Config, Double>
    ) -> Field {
        Field(name: name, group: group, blurb: blurb, min: min, max: max, step: step,
              digits: digits,
              read: { $0[keyPath: path] },
              write: { $0[keyPath: path] = $1 })
    }

    private static func intField(
        _ name: String, _ group: String, _ blurb: String,
        _ min: Double, _ max: Double,
        _ path: WritableKeyPath<TransitionPlanner.Config, Int>
    ) -> Field {
        Field(name: name, group: group, blurb: blurb, min: min, max: max, step: 1, digits: 0,
              read: { Double($0[keyPath: path]) },
              write: { $0[keyPath: path] = Int($1.rounded()) })
    }

    static let fields: [Field] = [
        // --- Tier gate: the five signals and the lines they cross.
        field("neutralLoudnessDB", "tier",
              "响度差超过它 → compatible 降为 neutral（拒绝长混音）。调高 = 更容忍音量落差。",
              0, 15, 0.1, 2, \.neutralLoudnessDB),
        field("clashLoudnessDB", "tier",
              "响度差超过它 → 直接判 clash（只给最短的礼貌淡出）。",
              0, 20, 0.1, 2, \.clashLoudnessDB),
        field("neutralTimbreDistance", "tier",
              "音色余弦距离超过它 → 降为 neutral。语料同曲自比中位 0.028、最坏 0.11。",
              0, 1, 0.005, 3, \.neutralTimbreDistance),
        field("clashTimbreDistance", "tier",
              "音色距离超过它 → 判 clash。当前只抓语料的最高一成。",
              0, 1, 0.005, 3, \.clashTimbreDistance),
        field("clashTempoRatio", "tier",
              "折叠后的 BPM 相对差超过它（且两边节奏都可信）→ 判 clash。",
              0, 1, 0.005, 3, \.clashTempoRatio),
        intField("clashKeyDistance", "tier",
                 "五度圈距离达到它 → 和声独自把 compatible 降为 neutral（永远不会独自判 clash）。",
                 0, 6, \.clashKeyDistance),
        field("keyConfidenceThreshold", "tier",
              "调性置信度低于它，检测出的调根本不参与决策。",
              0, 1, 0.01, 2, \.keyConfidenceThreshold),
        field("vocalClashRatio", "tier",
              "两边人声活跃度（相对各自均值）都超过它 = 撞人声：缩短叠加、禁止长 beat-match。",
              0.5, 2.5, 0.01, 2, \.vocalClashRatio),
        intField("loudnessWindow", "tier",
                 "响度差各取多少秒 RMS 求均值。",
                 3, 45, \.loudnessWindow),

        // --- Beat-match gate.
        field("bpmConfidenceThreshold", "beatmatch",
              "两边 BPM 置信度都要过它，才谈得上对拍。",
              0, 1, 0.01, 2, \.bpmConfidenceThreshold),
        field("maxBPMDeltaRatio", "beatmatch",
              "折叠后 BPM 相对差在它之内才允许 beat-match。",
              0, 0.5, 0.005, 3, \.maxBPMDeltaRatio),
        field("maxRateDeviation", "beatmatch",
              "每个 deck 最多变速多少（向中间靠）。调高 = 更多曲子够得着对拍。",
              0, 0.2, 0.002, 3, \.maxRateDeviation),
        field("stableCV", "beatmatch",
              "8/16 小节升级要求的能量平稳度（变异系数上限）。调高 = 更容易拿到长叠加。",
              0.05, 1, 0.01, 2, \.stableCV),

        // --- Overlap length.
        field("maxOverlap", "overlap",
              "任何叠加的硬上限（秒）。",
              2, 60, 0.5, 1, \.maxOverlap),
        field("minOverlap", "overlap",
              "任何叠加的硬下限（秒）。",
              0.2, 10, 0.1, 1, \.minOverlap),
        field("maxOverlapShare", "overlap",
              "叠加最多吃掉较短那首歌的多少比例。",
              0.02, 0.6, 0.01, 2, \.maxOverlapShare),
        field("neutralOverlapCap", "overlap",
              "neutral 档的叠加上限（秒）。",
              0.5, 20, 0.25, 2, \.neutralOverlapCap),
        field("clashOverlapCap", "overlap",
              "clash 档的叠加上限（秒）。",
              0.2, 12, 0.25, 2, \.clashOverlapCap),
        field("vocalClashFadeCap", "overlap",
              "撞人声时叠加被砍到的秒数上限。",
              0.5, 15, 0.25, 2, \.vocalClashFadeCap),
        field("tailStableCV", "overlap",
              "出曲尾部「还算平稳」的判据；决定尾巴能扛多长的淡出。",
              0.05, 1, 0.01, 2, \.tailStableCV),
        field("tailCapacityFallback", "overlap",
              "出曲尾部始终不平稳时退回的淡出长度（秒）。",
              0.5, 15, 0.25, 2, \.tailCapacityFallback),
        field("intakePeakShare", "overlap",
              "入曲爬到全曲峰值的这个比例前，都算「还能藏在淡出底下」。",
              0.2, 1, 0.01, 2, \.intakePeakShare),
        field("intakeBodySeconds", "overlap",
              "入曲爬升时间之外再加的正身秒数。",
              0, 20, 0.5, 1, \.intakeBodySeconds),
        field("minTrackDuration", "overlap",
              "任一首短于它 → 整个 AutoMix 放弃，走 gapless。",
              5, 180, 1, 0, \.minTrackDuration),

        // --- Where and how it lands.
        field("tailWindowShare", "shape",
              "出点最早允许出现在全曲的这个比例处。",
              0.1, 0.95, 0.01, 2, \.tailWindowShare),
        field("tailWindowSeconds", "shape",
              "beat-match 出点向前搜索的窗口长度（秒）。",
              5, 180, 1, 0, \.tailWindowSeconds),
        field("crossfadeOutPointShare", "shape",
              "crossfade 出点候选必须落在全曲的这个比例之后。",
              0.1, 0.95, 0.01, 2, \.crossfadeOutPointShare),
        field("stagedEQMinOverlap", "shape",
              "compatible crossfade 长到这个秒数才配得上三段 EQ 交接。",
              0, 30, 0.5, 1, \.stagedEQMinOverlap),
        field("echoBeatFraction", "shape",
              "echo-out 延迟 = 出曲一拍的这个倍数（0.75 = 附点八分）。",
              0.1, 2, 0.01, 2, \.echoBeatFraction),
        field("echoDelayMin", "shape",
              "echo-out 延迟下限（秒）。",
              0.02, 1, 0.01, 2, \.echoDelayMin),
        field("echoDelayMax", "shape",
              "echo-out 延迟上限（秒）。",
              0.1, 3, 0.01, 2, \.echoDelayMax),
    ]

    /// This config as `name: value`, in field order.
    var asDictionary: [String: Double] {
        var out: [String: Double] = [:]
        for f in Self.fields { out[f.name] = f.read(self) }
        return out
    }

    /// `.standard` with the named fields replaced. Unknown names are ignored
    /// (a stale saved preset must never take the console down); every value
    /// is clamped into the field's own range.
    static func standard(overriding overrides: [String: Double]) -> TransitionPlanner.Config {
        var config = TransitionPlanner.Config.standard
        for f in fields {
            guard let raw = overrides[f.name] else { continue }
            f.write(&config, Swift.min(Swift.max(raw, f.min), f.max))
        }
        return config
    }

    /// Fields that differ from `.standard`, as (name, standard, current).
    var diffFromStandard: [(name: String, standard: Double, current: Double)] {
        Self.fields.compactMap { f in
            let std = f.read(.standard), cur = f.read(self)
            return abs(std - cur) < 1e-12 ? nil : (f.name, std, cur)
        }
    }
}
