import Foundation

// The AutoMix queue-reorder scorer (docs/automix-queue-predev.md §2.3).
//
// **The planner is the scorer.** There is no second compatibility model here:
// for a current track A and a candidate B this runs `TransitionPlanner.plan`
// — the very pure function that will decide the real hand-over — and scores
// the pair by the *tier of transition it came back with*. A high score
// therefore means "a good transition is actually reachable for this pair",
// not "some proxy metric likes it".
//
// Everything in this file is a pure function of its arguments. The stateful
// half (which candidates are downloaded, what has lost how many rounds) lives
// in `QueueOrderSelector`; the offline `audition order` command drives this
// file directly, so the numbers the console prints are the numbers the player
// picks on.

/// How good a hand-over the planner was able to build for a pair — the score's
/// **dominant** term (predev §2.3: "tier 是主项").
///
/// Ordered worst to best, and deliberately coarse: the continuous terms below
/// only ever sort *within* one of these, so a stylistically similar pair that
/// can only be crossfaded must never outrank a pair that can be beat-matched.
enum TransitionTier: Int, Comparable, Sendable, CaseIterable {
    /// One side has no analysis, or is too short — no hand-over at all.
    case gapless = 0
    /// A plain volume crossfade: the planner found nothing to exploit.
    case crossfade = 1
    /// A crossfade with the staged three-band EQ hand-over.
    case stagedCrossfade = 2
    /// Grids aligned by a rate *step*.
    case beatMatched = 3
    /// Grids aligned by a tempo *glide* — the best thing the planner can make.
    case rampedBeatMatched = 4

    static func < (a: TransitionTier, b: TransitionTier) -> Bool {
        a.rawValue < b.rawValue
    }

    /// Read the tier back off a plan the planner produced. Deliberately a
    /// *derivation*, never a re-implementation of the gates: whatever the
    /// planner decided is what this reports.
    init(_ planned: PlannedTransition) {
        switch planned.plan {
        case .beatMatched(let p):
            self = p.rampLeadSeconds > 0 ? .rampedBeatMatched : .beatMatched
        case .crossfade:
            self = planned.style.stagedEQ ? .stagedCrossfade : .crossfade
        case .gapless:
            self = .gapless
        }
    }

    var label: String {
        switch self {
        case .gapless: return "gapless"
        case .crossfade: return "crossfade"
        case .stagedCrossfade: return "stagedCrossfade"
        case .beatMatched: return "beatMatched"
        case .rampedBeatMatched: return "rampedBeatMatched"
        }
    }

    /// Whether the grids were actually locked — the share this whole feature
    /// exists to raise.
    var isBeatMatched: Bool { self >= .beatMatched }
}

/// Every tunable the queue-order decision turns on, in one value — the same
/// shape as `TransitionPlanner.Config`, and swept the same way (`fields`,
/// `standard(overriding:)`, `asDictionary`).
struct QueueOrderConfig: Sendable, Equatable {

    /// How far apart two adjacent tiers are on the score scale.
    ///
    /// This is what makes the tier the main term: the four continuous terms
    /// below are each bounded in `[0, 1]` and their weights sum to well under
    /// this, so no combination of them can promote a crossfade over a
    /// beat-match. **Aging is exempt on purpose** — it is unbounded, which is
    /// exactly what "no track starves" means.
    var tierSpacing: Double = 10

    /// BPM affinity: the folded tempo gap (the planner's own `[0.5, 1, 2]`
    /// folding) at which affinity has fallen to 0. Just past the ramped
    /// beat-match cap, so a pair that only *just* misses the gate still reads
    /// as tempo-adjacent when both candidates are stuck in the crossfade tier.
    var tempoFullScale: Double = 0.13
    var tempoWeight: Double = 1.0

    /// Harmony: circle-of-fifths distance, 0–6. Interpolated toward the
    /// neutral 0.5 by the weaker of the two key confidences, so a guess never
    /// speaks as loudly as a certainty.
    var keyWeight: Double = 1.0

    /// Style: `melProfile` cosine, the planner's own timbre signal.
    var styleWeight: Double = 1.0

    /// Energy: the drop (or rise) between the outgoing tail and the incoming
    /// entry, in units of "fraction of the track's own peak RMS", at which
    /// continuity has fallen to 0.
    var energyFullScale: Double = 0.45
    /// A rise is not a fault the way a fall is — a set that lifts is a set
    /// that works — so a rise is charged this fraction of a fall of the same
    /// size.
    var energyRiseLeniency: Double = 0.4
    var energyWeight: Double = 1.0

    /// Added to a candidate's score per round it has lost (predev §2.3:
    /// "每落选一轮 +ε,保证不饿死"). Unbounded by design: keep losing and
    /// eventually you outrank a whole tier, which is what makes "every track
    /// gets played" a property of the arithmetic rather than a hope.
    var agingEpsilon: Double = 0.35

    /// Subtracted when the candidate shares an artist with the track now
    /// playing — `melProfile` likes an album rather too much (predev §4).
    /// 0 turns the rule off.
    var sameArtistPenalty: Double = 1.5

    // MARK: - Acquisition (predev §2.2)
    //
    // Read by `QueueOrderSelector`, not by the scoring below; they live here
    // so one value describes the whole mode.

    /// The tier at which a candidate is **good enough** and the escalation
    /// stops. The default is "the grids can be locked" — the share this whole
    /// feature exists to raise — which `beatMatched` and `rampedBeatMatched`
    /// both clear.
    ///
    /// Satisficing rather than optimising is sound here because the tier is the
    /// dominant term by construction (`tierSpacing`): once a candidate reaches
    /// the satisfying tier, everything a further round could buy is either a
    /// *higher* tier or a second-order reshuffle inside the same one. Paying
    /// several downloads for that is a bad trade against playing sooner.
    var satisfyingTier: TransitionTier = .beatMatched

    /// How many tracks the first escalation round downloads.
    var escalationFirstRound: Int = 1

    /// What each subsequent round multiplies the last one by: 1, 4, 16, 64 …
    /// Exponential so a cold queue that needs a lot of material gets it in a
    /// handful of rounds, while the common case — the very next track is
    /// already fine — costs exactly one download.
    var escalationFactor: Int = 4

    static let standard = QueueOrderConfig()
}

/// One candidate's score, kept broken out so the debug panel and the console
/// can print *why* — a bare total is not reviewable.
struct QueueOrderScore: Sendable, Equatable {
    var tier: TransitionTier = .gapless
    /// Each in `[0, 1]`, before its weight.
    var tempoAffinity: Double = 0.5
    var keyAffinity: Double = 0.5
    var styleAffinity: Double = 0.5
    var energyContinuity: Double = 0.5
    /// Rounds this candidate has already lost, times `agingEpsilon`.
    var aging: Double = 0
    /// Already negative when it applies.
    var sameArtistPenalty: Double = 0

    /// The tier's own contribution — `tier.rawValue × tierSpacing`, kept
    /// rather than recomputed so a score made under a swept config can still
    /// be decomposed.
    var tierScore: Double = 0

    /// The number the pick is made on.
    var total: Double = 0

    /// Everything except the tier — what sorts candidates *inside* one tier.
    var continuity: Double { total - tierScore }
}

/// The pure half of the queue-order mode.
enum QueueOrderScorer {

    // MARK: - Scoring

    /// Score one candidate against the track now playing.
    ///
    /// - Parameter planned: the transition `TransitionPlanner.plan(A, B)` came
    ///   back with. Taken as a parameter rather than planned here so the caller
    ///   controls the planner config, the stem availability and the lyric
    ///   context — and so this stays testable without two real analyses.
    /// - Parameter lostRounds: how many picks this candidate has already been
    ///   passed over for.
    static func score(
        outgoing: TrackAnalysis?, incoming: TrackAnalysis?,
        planned: PlannedTransition,
        lostRounds: Int = 0,
        sharesArtist: Bool = false,
        config: QueueOrderConfig = .standard,
        plannerConfig: TransitionPlanner.Config = .standard
    ) -> QueueOrderScore {
        var s = QueueOrderScore()
        s.tier = TransitionTier(planned)
        if let outgoing, let incoming {
            s.tempoAffinity = tempoAffinity(outgoing, incoming,
                                            config: config, plannerConfig: plannerConfig)
            s.keyAffinity = keyAffinity(outgoing, incoming, plannerConfig: plannerConfig)
            s.styleAffinity = styleAffinity(outgoing, incoming)
            s.energyContinuity = energyContinuity(outgoing, incoming, config: config)
        }
        s.aging = Double(max(0, lostRounds)) * config.agingEpsilon
        s.sameArtistPenalty = sharesArtist ? -config.sameArtistPenalty : 0
        s.tierScore = Double(s.tier.rawValue) * config.tierSpacing
        s.total = s.tierScore
            + config.tempoWeight * s.tempoAffinity
            + config.keyWeight * s.keyAffinity
            + config.styleWeight * s.styleAffinity
            + config.energyWeight * s.energyContinuity
            + s.aging
            + s.sameArtistPenalty
        return s
    }

    // MARK: - Continuity terms
    //
    // Every one of these is a shift-invariant statistic of the analysis —
    // which is why scoring may run on a low-bitrate copy of the file while
    // the *plan* may not (predev §2.2): a lossy encoder's leading delay moves
    // the beat grid, and none of the four terms below can see it.

    /// 1 at an identical (or exactly double/half) tempo, falling to 0 at
    /// `tempoFullScale`. Neutral 0.5 when either side's beat tracking is not
    /// confident enough for the planner to use it either.
    static func tempoAffinity(
        _ a: TrackAnalysis, _ b: TrackAnalysis,
        config: QueueOrderConfig = .standard,
        plannerConfig: TransitionPlanner.Config = .standard
    ) -> Double {
        guard a.bpmConfidence >= plannerConfig.bpmConfidenceThreshold,
              b.bpmConfidence >= plannerConfig.bpmConfidenceThreshold,
              a.bpm > 0, b.bpm > 0 else { return 0.5 }
        let ratio = [0.5, 1.0, 2.0].map { abs(b.bpm * $0 - a.bpm) / a.bpm }.min()!
        guard config.tempoFullScale > 0 else { return ratio == 0 ? 1 : 0 }
        return clamp01(1 - ratio / config.tempoFullScale)
    }

    /// 1 for the same key, 0 for the tritone, interpolated toward 0.5 by the
    /// weaker of the two key confidences. 0.5 when the planner's own key gate
    /// abstains, so harmony neither helps nor hurts an untonal pair.
    static func keyAffinity(
        _ a: TrackAnalysis, _ b: TrackAnalysis,
        plannerConfig: TransitionPlanner.Config = .standard
    ) -> Double {
        guard let distance = TransitionPlanner.keyDistance(a, b, config: plannerConfig)
        else { return 0.5 }
        // The circle of fifths' farthest point is 6 steps away.
        let affinity = clamp01(1 - Double(distance) / 6)
        let confidence = clamp01(Swift.min(a.keyConfidence, b.keyConfidence))
        return 0.5 + (affinity - 0.5) * confidence
    }

    /// `melProfile` cosine mapped from `[-1, 1]` onto `[0, 1]`. The profiles
    /// are L2-normalized and mean-removed by the analyzer, so the dot product
    /// *is* the cosine. Neutral 0.5 when either side has no profile.
    static func styleAffinity(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Double {
        let x = a.melProfile, y = b.melProfile
        guard !x.isEmpty, x.count == y.count else { return 0.5 }
        var dot: Double = 0, nx: Double = 0, ny: Double = 0
        for i in 0..<x.count {
            dot += Double(x[i]) * Double(y[i])
            nx += Double(x[i]) * Double(x[i])
            ny += Double(y[i]) * Double(y[i])
        }
        guard nx > 1e-12, ny > 1e-12 else { return 0.5 }
        let cosine = dot / (nx.squareRoot() * ny.squareRoot())
        return clamp01((cosine + 1) / 2)
    }

    /// How level the seam is: the outgoing track's energy where it leaves
    /// against the incoming track's energy where it enters, both as a fraction
    /// of their own peak. 1 for a matched hand-over, falling to 0 at
    /// `energyFullScale`; a rise is charged `energyRiseLeniency` of a fall.
    static func energyContinuity(
        _ a: TrackAnalysis, _ b: TrackAnalysis, config: QueueOrderConfig = .standard
    ) -> Double {
        guard let out = exitEnergy(a), let into = entryEnergy(b) else { return 0.5 }
        let delta = into - out
        let charged = delta < 0 ? -delta : delta * config.energyRiseLeniency
        guard config.energyFullScale > 0 else { return charged == 0 ? 1 : 0 }
        return clamp01(1 - charged / config.energyFullScale)
    }

    /// Energy in the last stretch the outgoing track is still playing at
    /// level — before any natural outro fade, which is a fade, not a drop in
    /// the arrangement.
    static func exitEnergy(_ a: TrackAnalysis) -> Double? {
        let end = a.outroFadeStart ?? a.duration
        return energy(of: a, around: max(0, end - energyWindow / 2))
    }

    /// Energy where the incoming track actually starts playing — after its
    /// intro, which is where the planner aims its in point.
    static func entryEnergy(_ b: TrackAnalysis) -> Double? {
        energy(of: b, around: b.introEnd)
    }

    /// The window both edge measurements average over.
    private static let energyWindow: TimeInterval = 15

    /// Normalized energy (fraction of the track's own peak) around `t`,
    /// preferring the structural section that contains it — the analyzer has
    /// already normalized those the same way — and falling back to the RMS
    /// envelope.
    private static func energy(of a: TrackAnalysis, around t: TimeInterval) -> Double? {
        if let section = a.sections.last(where: { $0.start <= t + 0.01 }) ?? a.sections.first {
            return Double(section.energy)
        }
        let env = a.rmsEnvelope
        guard !env.isEmpty, let peak = env.max(), peak > 1e-9 else { return nil }
        let start = Swift.max(0, Swift.min(env.count - 1, Int(t)))
        let end = Swift.max(start + 1, Swift.min(env.count, Int((t + energyWindow).rounded(.up))))
        let slice = env[start..<end]
        let mean = slice.reduce(0.0) { $0 + Double($1) } / Double(slice.count)
        return mean / Double(peak)
    }

    private static func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0.5 }
        return Swift.min(1, Swift.max(0, v))
    }
}

// MARK: - Tuning surface

extension QueueOrderConfig {
    /// One entry per knob, the same description `TransitionPlanner.Config`
    /// carries — so a sweep can drive both from one `--set` list.
    struct Field: Sendable {
        let name: String
        let blurb: String
        let min: Double
        let max: Double
        let step: Double
        let digits: Int
        let read: @Sendable (QueueOrderConfig) -> Double
        let write: @Sendable (inout QueueOrderConfig, Double) -> Void
    }

    private static func field(
        _ name: String, _ blurb: String,
        _ min: Double, _ max: Double, _ step: Double, _ digits: Int = 2,
        _ path: WritableKeyPath<QueueOrderConfig, Double>
    ) -> Field {
        Field(name: name, blurb: blurb, min: min, max: max, step: step, digits: digits,
              read: { $0[keyPath: path] }, write: { $0[keyPath: path] = $1 })
    }

    static let fields: [Field] = [
        field("tierSpacing",
              "档位之间的分差。调大 = 更不容易让连续项跨档翻盘。",
              1, 50, 0.5, 1, \.tierSpacing),
        field("tempoFullScale",
              "BPM 比值差到多少时速度亲和力归零。调大 = 对速度差更宽容。",
              0.01, 0.5, 0.005, 3, \.tempoFullScale),
        field("tempoWeight", "速度亲和力在档位内的权重。", 0, 5, 0.05, 2, \.tempoWeight),
        field("keyWeight", "调性亲和力在档位内的权重。", 0, 5, 0.05, 2, \.keyWeight),
        field("styleWeight", "风格（melProfile 余弦）在档位内的权重。", 0, 5, 0.05, 2, \.styleWeight),
        field("energyFullScale",
              "能量落差到多少（占各自峰值的比例）时连续性归零。",
              0.05, 1, 0.01, 2, \.energyFullScale),
        field("energyRiseLeniency",
              "能量上扬按下跌的几折计费。0 = 上扬完全免费。",
              0, 1, 0.05, 2, \.energyRiseLeniency),
        field("energyWeight", "能量连续性在档位内的权重。", 0, 5, 0.05, 2, \.energyWeight),
        field("agingEpsilon",
              "每落选一轮加多少分。调大 = 更快轮到冷门曲目，也更容易跨档翻盘。",
              0, 5, 0.05, 2, \.agingEpsilon),
        field("sameArtistPenalty",
              "候选与当前曲同歌手时扣多少分。0 = 关掉这条规则。",
              0, 10, 0.1, 2, \.sameArtistPenalty),
        Field(name: "satisfyingTier",
              blurb: "满意档位：候选达到这一档就立即选定、停止下载。"
                  + "0=gapless 1=crossfade 2=stagedCrossfade 3=beatMatched 4=rampedBeatMatched。",
              min: 0, max: 4, step: 1, digits: 0,
              read: { Double($0.satisfyingTier.rawValue) },
              write: { config, raw in
                  let clamped = Swift.min(Swift.max(Int(raw.rounded()), 0),
                                          TransitionTier.rampedBeatMatched.rawValue)
                  config.satisfyingTier = TransitionTier(rawValue: clamped) ?? .beatMatched
              }),
        Field(name: "escalationFirstRound",
              blurb: "第一轮补下载几首。调大 = 更急躁,冷队列更快出结果也更费流量。",
              min: 1, max: 32, step: 1, digits: 0,
              read: { Double($0.escalationFirstRound) },
              write: { $0.escalationFirstRound = Swift.max(1, Int($1.rounded())) }),
        Field(name: "escalationFactor",
              blurb: "每轮相对上一轮的倍数(1→4→16…)。1 = 每次只加一首。",
              min: 1, max: 8, step: 1, digits: 0,
              read: { Double($0.escalationFactor) },
              write: { $0.escalationFactor = Swift.max(1, Int($1.rounded())) }),
    ]

    var asDictionary: [String: Double] {
        var out: [String: Double] = [:]
        for f in Self.fields { out[f.name] = f.read(self) }
        return out
    }

    /// `.standard` with the named fields replaced; unknown names ignored,
    /// values clamped into their own range.
    static func standard(overriding overrides: [String: Double]) -> QueueOrderConfig {
        var config = QueueOrderConfig.standard
        for f in fields {
            guard let raw = overrides[f.name] else { continue }
            f.write(&config, Swift.min(Swift.max(raw, f.min), f.max))
        }
        return config
    }
}
