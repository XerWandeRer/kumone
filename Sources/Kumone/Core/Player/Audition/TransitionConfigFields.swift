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

    /// A flag, shown as a 0/1 slider. The console renders every knob from this
    /// list, so an on/off knob is a two-value one rather than a new widget.
    private static func boolField(
        _ name: String, _ group: String, _ blurb: String,
        _ path: WritableKeyPath<TransitionPlanner.Config, Bool>
    ) -> Field {
        Field(name: name, group: group, blurb: blurb, min: 0, max: 1, step: 1, digits: 0,
              read: { $0[keyPath: path] ? 1 : 0 },
              write: { $0[keyPath: path] = $1 >= 0.5 })
    }

    static let fields: [Field] = [
        // --- Tier gate: the five signals and the lines they cross.
        field("neutralLoudnessDB", "tier",
              "两首歌音量差多少就不算“很搭”了。调大 = 更容忍音量落差，愿意给更长的叠加。",
              0, 15, 0.1, 2, \.neutralLoudnessDB),
        field("clashLoudnessDB", "tier",
              "音量差大到这个地步就直接放弃，只给最短的礼貌淡出。",
              0, 20, 0.1, 2, \.clashLoudnessDB),
        field("neutralTimbreDistance", "tier",
              "两首歌的音色差多远就不算“很搭”。参考：同一首歌自己跟自己比大约 0.03，最差 0.11。",
              0, 1, 0.005, 3, \.neutralTimbreDistance),
        field("clashTimbreDistance", "tier",
              "音色差到这个地步就当成“差异很大”。目前只会命中语料里最不搭的一成。",
              0, 1, 0.005, 3, \.clashTimbreDistance),
        field("clashTempoRatio", "tier",
              "速度差到这个比例（已按倍速关系折算）就当成“差异很大”，前提是两边拍子都数得准。",
              0, 1, 0.005, 3, \.clashTempoRatio),
        intField("clashKeyDistance", "tier",
                 "两首歌的调在五度圈上隔几步就算不合，把“很搭”降一级。和声永远不会单独判定“差异很大”。",
                 0, 6, \.clashKeyDistance),
        field("keyConfidenceThreshold", "tier",
              "对调性的把握低于这个数，就当作没听出调，和声完全不参与判断。",
              0, 1, 0.01, 2, \.keyConfidenceThreshold),
        field("vocalClashRatio", "tier",
              "交接窗口里的人声密度是各自平常的几倍就算“太密”。两边都超过 = 两个主唱会打架，叠加缩短。",
              0.5, 2.5, 0.01, 2, \.vocalClashRatio),
        intField("loudnessWindow", "tier",
                 "比音量时，出曲结尾和入曲开头各取多少秒来算平均值。",
                 3, 45, \.loudnessWindow),
        field("rideMaxDB", "tier",
              "交接时最多把入曲的音量临时压低（或抬高）多少 dB，过渡走完再用每秒 0.3 dB 悄悄推回原位——"
                  + "就是真人 DJ 手放在推子上的那一下。整首歌的响度补偿拉不平“安静的尾奏对上火热的开场”"
                  + "这种局部落差，这一项专治它。调大 = 敢压得更狠，交接更平；"
                  + "设成 0 = 关掉这一手，音量差这条线退回只看整曲补偿之后的残差。"
                  + "抬高那一侧还会再受入曲自己的峰值余量限制，不会把歌顶爆。",
              0, 8, 0.25, 2, \.rideMaxDB),
        boolField("loudnessCompensation", "tier",
                  "开 = 先按每首歌的母带响度做一次播放增益补偿、交接时再做一次临时的音量微调（见 rideMaxDB），"
                  + "然后才看剩下的音量差；"
                  + "关 = 两级增益都不做，直接拿原始音量差去撞上面两条线（补偿功能上线前的老行为）。",
                  \.loudnessCompensation),

        // --- Beat-match gate.
        field("bpmConfidenceThreshold", "beatmatch",
              "两首歌的拍子都要数到这个把握以上，才谈得上让它们踩同一个拍子。",
              0, 1, 0.01, 2, \.bpmConfidenceThreshold),
        field("maxBPMDeltaRatio", "beatmatch",
              "速度差在这个比例以内才允许对拍。调大 = 更多曲子够得着对拍，但也更容易听出变速。",
              0, 0.5, 0.005, 3, \.maxBPMDeltaRatio),
        field("maxRateDeviation", "beatmatch",
              "为了对上拍子，每首歌最多允许被拉快/放慢多少。调大 = 更多曲子对得上，但音色开始走味。",
              0, 0.2, 0.002, 3, \.maxRateDeviation),
        field("stableCV", "beatmatch",
              "要叠满 8 或 16 小节，两首歌这段的音量起伏得多平稳。调大 = 更宽松，更容易拿到长叠加。",
              0.05, 1, 0.01, 2, \.stableCV),

        // --- Overlap length.
        field("maxOverlap", "overlap",
              "不管怎么算，两首歌最多叠这么久（秒）。",
              2, 60, 0.5, 1, \.maxOverlap),
        field("minOverlap", "overlap",
              "不管怎么算，至少也要叠这么久（秒），免得过渡短到像切歌。",
              0.2, 10, 0.1, 1, \.minOverlap),
        field("maxOverlapShare", "overlap",
              "叠加最多能占掉较短那首歌的多大比例，避免短曲子被过渡吞掉一半。",
              0.02, 0.6, 0.01, 2, \.maxOverlapShare),
        field("neutralOverlapCap", "overlap",
              "“一般般”这一档最多叠多久（秒）。",
              0.5, 20, 0.25, 2, \.neutralOverlapCap),
        field("clashOverlapCap", "overlap",
              "“差异很大”这一档最多叠多久（秒）。",
              0.2, 12, 0.25, 2, \.clashOverlapCap),
        field("vocalClashFadeCap", "overlap",
              "两个主唱会打架时，叠加被砍到多少秒以内。",
              0.5, 15, 0.25, 2, \.vocalClashFadeCap),
        field("tailStableCV", "overlap",
              "判断出曲尾巴“够平稳”的宽松度；越宽松，就认为尾巴能扛住越长的淡出。",
              0.05, 1, 0.01, 2, \.tailStableCV),
        field("tailCapacityFallback", "overlap",
              "出曲尾巴一直忽大忽小、算不出承载力时，退而求其次用多长的淡出（秒）。",
              0.5, 15, 0.25, 2, \.tailCapacityFallback),
        field("intakePeakShare", "overlap",
              "入曲从开头爬到全曲多大音量之前，都还能藏在出曲的淡出底下不被察觉。",
              0.2, 1, 0.01, 2, \.intakePeakShare),
        field("intakeBodySeconds", "overlap",
              "在入曲“爬起来”所需的时间之外，再多给几秒正身，让交接不那么局促。",
              0, 20, 0.5, 1, \.intakeBodySeconds),
        field("minTrackDuration", "overlap",
              "任何一首短于这个秒数，就不做过渡了，直接一首接一首播完。",
              5, 180, 1, 0, \.minTrackDuration),

        // --- Where and how it lands.
        field("tailWindowShare", "shape",
              "出曲最早可以从整首歌的百分之多少处开始交接，防止过渡点提前到副歌以前。",
              0.1, 0.95, 0.01, 2, \.tailWindowShare),
        field("tailWindowSeconds", "shape",
              "对拍时，从曲尾往前找交接点的搜索范围有多长（秒）。",
              5, 180, 1, 0, \.tailWindowSeconds),
        field("crossfadeOutPointShare", "shape",
              "普通淡入淡出的交接点必须落在整首歌百分之多少之后。",
              0.1, 0.95, 0.01, 2, \.crossfadeOutPointShare),
        field("stagedEQMinOverlap", "shape",
              "叠加至少这么长（秒），才值得把高、中、低三段分批交接；更短就只做普通淡出。",
              0, 30, 0.5, 1, \.stagedEQMinOverlap),
        field("echoBeatFraction", "shape",
              "戛然而止的回声，间隔是出曲一拍的多少倍（0.75 就是附点八分，最常见的 DJ 手感）。",
              0.1, 2, 0.01, 2, \.echoBeatFraction),
        field("echoDelayMin", "shape",
              "回声间隔的下限（秒），太短会糊成一团。",
              0.02, 1, 0.01, 2, \.echoDelayMin),
        field("echoDelayMax", "shape",
              "回声间隔的上限（秒），太长会拖沓。",
              0.1, 3, 0.01, 2, \.echoDelayMax),

        // --- Stem layer. Only read when人声分离可用；关掉时这四项完全不参与判断。
        field("stemVocalActiveRatio", "stem",
              "出曲的交接窗口里人声要有平常的几倍密，才值得动用人声分离。"
                  + "调小 = 更容易升级到 stem 手法，但也更容易选到其实没什么人声的段落。"
                  + "参考：语料里每首歌自己的 8 秒窗口，中位数 1.00，第 95 百分位 1.16–1.58。",
              0.8, 2, 0.01, 2, \.stemVocalActiveRatio),
        field("stemAcapellaIncomingVocalMax", "stem",
              "要让出曲的清唱飘在入曲上，入曲开头的人声必须低于自己平常的这个倍数（即“基本是伴奏”）。"
                  + "调大 = 更多曲子够得着 acapella，但入曲一开口就会变成两个主唱抢戏。",
              0.2, 1.5, 0.01, 2, \.stemAcapellaIncomingVocalMax),
        field("stemMinOverlap", "stem",
              "叠加短于这个秒数就不用 stem 手法：手法本身展不开，也不值得为它跑一次人声分离。",
              2, 20, 0.5, 1, \.stemMinOverlap),
        field("stemDuckDepthDB", "stem",
              "两边都在唱时，出曲的人声被压低多少 dB（S1 盲听选的是 9）。"
                  + "调大 = 出曲人声让得更彻底，但也更容易听出“被人按住了”。",
              0, 24, 0.5, 1, \.stemDuckDepthDB),
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
