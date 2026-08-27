import AVFoundation
import Foundation

/// The offline AutoMix tuning surface, and the only part of KumoneCore the
/// `audition` CLI touches.
///
/// It exists so a transition-parameter change can be judged in seconds:
/// analyze (cached), plan, explain *why* that plan was chosen, and render the
/// hand-over to a WAV you can `afplay`. Everything below the surface is the
/// production code — `TrackAnalyzer`, `TransitionPlanner`,
/// `TransitionAutomation`, `DeckChain` — so what you hear is what the player
/// would do.
public enum Audition {

    // MARK: - Analysis (sidecar-cached)

    /// Analyze `url`, reusing (and writing) a `<file>.analysis.json` sidecar so
    /// a re-run over the same corpus is instant. Same format and version gate
    /// as the app's own `AudioCache` sidecars.
    static func analysis(of url: URL, useCache: Bool = true) throws -> TrackAnalysis {
        let sidecar = URL(fileURLWithPath: url.path + ".analysis.json")
        if useCache, let data = try? Data(contentsOf: sidecar),
           let cached = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
           cached.version == TrackAnalysis.currentVersion {
            return cached
        }
        let fresh = try TrackAnalyzer.analyze(fileAt: url)
        if useCache, let data = try? JSONEncoder().encode(fresh) {
            try? data.write(to: sidecar, options: .atomic)
        }
        return fresh
    }

    /// Whether a usable sidecar already exists (so the CLI can say "analyzing"
    /// only when it really is).
    public static func hasCachedAnalysis(for url: URL) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: url.path + ".analysis.json")),
              let cached = try? JSONDecoder().decode(TrackAnalysis.self, from: data)
        else { return false }
        return cached.version == TrackAnalysis.currentVersion
    }

    // MARK: - Style / fade overrides

    /// `--style` values, for auditioning one technique in isolation.
    public enum StyleOverride: String, CaseIterable, Sendable {
        case plain, sweep, echo, staged
    }

    /// `--stem` values. The planner never asks for a stem technique yet, so
    /// this is how the tuning loop hears one: it layers onto whatever style
    /// the planner (or `--style`) chose, rather than replacing it.
    public enum StemOverride: Sendable, Equatable {
        case acapella
        case instrumental
        case duck(depthDB: Float)

        /// S1's blind-test depth.
        public static let defaultDuckDepthDB: Float = -9
        /// The names the CLI and the console offer, without the `duck:N` tail.
        public static let names = ["acapella", "instrumental", "duck"]

        /// `acapella` / `instrumental` / `duck` / `duck:9` / `duck:-9`.
        /// The depth is read as an attenuation either way — `duck:9` and
        /// `duck:-9` both mean 9 dB down, because nobody means +9.
        public static func parse(_ raw: String) -> StemOverride? {
            let parts = raw.split(separator: ":", maxSplits: 1)
            guard let head = parts.first else { return nil }
            switch head {
            case "acapella", "acapellaOver": return .acapella
            case "instrumental", "instrumentalOut": return .instrumental
            case "duck", "vocalDuck":
                guard parts.count == 2 else { return .duck(depthDB: defaultDuckDepthDB) }
                guard let value = Float(parts[1]) else { return nil }
                return .duck(depthDB: -abs(value))
            default: return nil
            }
        }

        var technique: StemTechnique {
            switch self {
            case .acapella: return .acapellaOver
            case .instrumental: return .instrumentalOut
            case .duck(let depth): return .vocalDuck(depthDB: depth)
            }
        }
    }

    // MARK: - Decision

    /// A planned transition plus the numbers that produced it.
    public struct Decision: Sendable {
        public let outgoingName: String
        public let incomingName: String
        public let outgoingDuration: TimeInterval
        public let incomingDuration: TimeInterval

        /// "compatible" / "neutral" / "clash", after any key demotion.
        public let tier: String
        /// The key gate turned a compatible pair into a neutral one.
        public let demotedByKey: Bool

        public let loudnessGapDB: Double
        public let timbreDistance: Double
        public let tempoRatio: Double?
        public let keyDistance: Int?
        public let outgoingBPM: Double
        public let incomingBPM: Double
        public let outgoingBPMConfidence: Double
        public let incomingBPMConfidence: Double
        /// Vocal activity over the chosen overlap window, relative to each
        /// track's own mean. Above `vocalClashRatio` on both sides is the one
        /// blend a DJ never allows.
        public let outgoingVocalScore: Double?
        public let incomingVocalScore: Double?

        /// "beatMatched" / "crossfade" / "gapless".
        public let planKind: String
        /// e.g. "fade+stagedEQ", "echoOut (delay 0.37s)", "filterSweep".
        public let styleDescription: String
        public let outPoint: TimeInterval?
        public let inPoint: TimeInterval?
        public let overlapDuration: TimeInterval
        public let overlapBars: Int?
        public let outgoingRate: Float?
        public let incomingRate: Float?
        /// Whether `--style` / `--fade` rewrote the planner's own choice.
        public let overridden: Bool

        /// "timbre 0.31 vs clash line 0.30" — signals sitting close enough to a
        /// threshold that nudging the constant would flip this pair.
        public let nearMisses: [String]

        /// The tier the signals alone produced, before the key gate.
        public let rawTier: String
        /// `name: value` for every knob this decision was made under.
        public let config: [String: Double]

        let planned: PlannedTransition
        let outgoingURL: URL
        let incomingURL: URL
        let outgoingAnalysis: TrackAnalysis
        let incomingAnalysis: TrackAnalysis
        let resolvedConfig: TransitionPlanner.Config
        let signals: TransitionPlanner.Signals
    }

    /// Analyze both tracks, plan the hand-over, and explain the decision.
    ///
    /// `config` names planner knobs to override (see
    /// `TransitionPlanner.Config.fields`); an empty dictionary — the default,
    /// and what every product path uses — resolves to `Config.standard`.
    public static func decide(
        outgoing outgoingURL: URL, incoming incomingURL: URL,
        style styleOverride: StyleOverride? = nil,
        fade fadeOverride: TimeInterval? = nil,
        stem stemOverride: StemOverride? = nil,
        config configOverrides: [String: Double] = [:],
        useCache: Bool = true
    ) throws -> Decision {
        let out = try analysis(of: outgoingURL, useCache: useCache)
        let inc = try analysis(of: incomingURL, useCache: useCache)
        let config = TransitionPlanner.Config.standard(overriding: configOverrides)

        let signals = TransitionPlanner.signals(outgoing: out, incoming: inc, config: config)
        let rawTier = TransitionPlanner.tier(of: signals, config: config)
        let keyDistance = TransitionPlanner.keyDistance(out, inc, config: config)
        let demoted = rawTier == .compatible
            && (keyDistance ?? 0) >= config.clashKeyDistance
        let effectiveTier = demoted ? TransitionPlanner.CompatibilityTier.neutral : rawTier

        var planned = TransitionPlanner.plan(outgoing: out, incoming: inc, config: config)
        var overridden = false
        if let fadeOverride {
            planned = applyFade(fadeOverride, to: planned, outgoingDuration: out.duration)
            overridden = true
        }
        if let styleOverride {
            planned = PlannedTransition(plan: planned.plan,
                                        style: style(styleOverride, basedOn: planned.style))
            overridden = true
        }
        if let stemOverride {
            var style = planned.style
            style.stemTechnique = stemOverride.technique
            planned = PlannedTransition(plan: planned.plan, style: style)
            overridden = true
        }

        let geometry = TransitionAutomation.Geometry(plan: planned.plan)
        let outPoint = planned.plan.outPoint
        let inPoint: TimeInterval?
        var bars: Int?
        var outRate: Float?
        var inRate: Float?
        switch planned.plan {
        case .beatMatched(let p):
            inPoint = p.inPoint
            bars = p.overlapBars
            outRate = p.outgoingRate
            inRate = p.incomingRate
        case .crossfade(_, _, let point):
            inPoint = point
        case .gapless:
            inPoint = nil
        }

        let window = geometry.overlapDuration
        let outVocal = outPoint.flatMap {
            TransitionPlanner.vocalScore(out, from: $0, length: window)
        }
        let inVocal = inPoint.flatMap {
            TransitionPlanner.vocalScore(inc, from: $0, length: window)
        }

        return Decision(
            outgoingName: outgoingURL.lastPathComponent,
            incomingName: incomingURL.lastPathComponent,
            outgoingDuration: out.duration,
            incomingDuration: inc.duration,
            tier: name(of: effectiveTier),
            demotedByKey: demoted,
            loudnessGapDB: signals.loudnessGapDB,
            timbreDistance: signals.timbreDistance,
            tempoRatio: signals.tempoRatio,
            keyDistance: keyDistance,
            outgoingBPM: out.bpm, incomingBPM: inc.bpm,
            outgoingBPMConfidence: out.bpmConfidence,
            incomingBPMConfidence: inc.bpmConfidence,
            outgoingVocalScore: outVocal, incomingVocalScore: inVocal,
            planKind: kind(of: planned.plan),
            styleDescription: describe(planned.style, geometry: geometry),
            outPoint: outPoint, inPoint: inPoint,
            overlapDuration: window, overlapBars: bars,
            outgoingRate: outRate, incomingRate: inRate,
            overridden: overridden,
            nearMisses: nearMisses(signals: signals, keyDistance: keyDistance,
                                   outVocal: outVocal, inVocal: inVocal, config: config),
            rawTier: name(of: rawTier),
            config: config.asDictionary,
            planned: planned, outgoingURL: outgoingURL, incomingURL: incomingURL,
            outgoingAnalysis: out, incomingAnalysis: inc,
            resolvedConfig: config, signals: signals)
    }

    // MARK: - Rendering

    public struct RenderSummary: Sendable {
        public let outputURL: URL
        public let duration: TimeInterval
        public let overlapStart: TimeInterval
        public let overlapDuration: TimeInterval
        public let renderSeconds: Double
        public let realtimeFactor: Double
        /// The stem technique that shaped this render, the wall-clock cost of
        /// getting the stem, and — when a requested technique could not run —
        /// why the render fell back to the whole mix.
        public let stemTechnique: String?
        public let stemSeconds: Double?
        public let stemSeparatedSeconds: TimeInterval?
        /// Vocal energy in the separated window over the mixture's. Near zero
        /// means the outgoing window is instrumental, so the technique had
        /// nothing to act on however correctly it ran.
        public let stemVocalEnergyRatio: Double?
        public let stemCacheHit: Bool
        public let stemFallbackReason: String?
    }

    /// Render the decision's transition to a 44.1 kHz / 16-bit WAV.
    ///
    /// `stemProvider` is only consulted when the decision's style carries a
    /// stem technique; without one, a stem render degrades to a whole-mix
    /// render and says so in `RenderSummary.stemFallbackReason`.
    public static func render(_ decision: Decision, to outputURL: URL,
                              preRoll: TimeInterval = 12,
                              postRoll: TimeInterval = 12,
                              stemProvider: VocalStemProvider? = nil) throws -> RenderSummary {
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = preRoll
        options.postRoll = postRoll
        options.vocalStemProvider = stemProvider
        let result = try OfflineTransitionRenderer.render(
            decision.planned,
            outgoing: decision.outgoingURL, incoming: decision.incomingURL,
            to: outputURL, options: options)
        return RenderSummary(outputURL: result.outputURL, duration: result.duration,
                             overlapStart: result.overlapStart,
                             overlapDuration: result.overlapDuration,
                             renderSeconds: result.renderSeconds,
                             realtimeFactor: result.realtimeFactor,
                             stemTechnique: result.stemTechnique,
                             stemSeconds: result.stemSeconds,
                             stemSeparatedSeconds: result.stemSeparatedSeconds,
                             stemVocalEnergyRatio: result.stemVocalEnergyRatio,
                             stemCacheHit: result.stemCacheHit,
                             stemFallbackReason: result.stemFallbackReason)
    }

    // Thresholds are no longer republished here: `Decision.config` carries
    // the whole resolved config, so an explanation always quotes the lines
    // that decision was actually made under — including a `--set` run's.

    // MARK: - Internals

    private static func name(of tier: TransitionPlanner.CompatibilityTier) -> String {
        switch tier {
        case .compatible: return "compatible"
        case .neutral: return "neutral"
        case .clash: return "clash"
        }
    }

    private static func kind(of plan: TransitionPlan) -> String {
        switch plan {
        case .beatMatched: return "beatMatched"
        case .crossfade: return "crossfade"
        case .gapless: return "gapless"
        }
    }

    private static func describe(_ style: TransitionStyle,
                                 geometry: TransitionAutomation.Geometry) -> String {
        var parts: [String] = []
        switch style.outroEffect {
        case .fade: parts.append("fade")
        case .filterSweep: parts.append("filterSweep")
        case .echoOut:
            let delay = TransitionAutomation.echoDelayTime(style: style, geometry: geometry)
            parts.append(String(format: "echoOut(delay %.0fms)", delay * 1000))
        }
        if style.stagedEQ { parts.append("stagedEQ") }
        if let stem = style.stemTechnique { parts.append(stem.label) }
        return parts.joined(separator: "+")
    }

    private static func style(_ override: StyleOverride,
                              basedOn original: TransitionStyle) -> TransitionStyle {
        switch override {
        case .plain:
            return .plain
        case .sweep:
            return TransitionStyle(outroEffect: .filterSweep, stagedEQ: false)
        case .echo:
            // Keep the planner's beat-synced delay hint when it had one.
            return TransitionStyle(outroEffect: .echoOut, stagedEQ: false,
                                   echoDelayTime: original.echoDelayTime)
        case .staged:
            return TransitionStyle(outroEffect: .fade, stagedEQ: true)
        }
    }

    /// `--fade N`: keep the mix points, change only how long the overlap runs.
    /// A `.gapless` plan has no mix point, so it becomes a crossfade landing on
    /// the end of the outgoing track — which is what you want when you are
    /// auditioning a fade length rather than the planner's choice.
    private static func applyFade(_ fade: TimeInterval, to planned: PlannedTransition,
                                  outgoingDuration: TimeInterval) -> PlannedTransition {
        let fade = max(0.1, fade)
        switch planned.plan {
        case .crossfade(_, let outPoint, let inPoint):
            return PlannedTransition(
                plan: .crossfade(duration: fade,
                                 outPoint: min(outPoint, max(0, outgoingDuration - fade)),
                                 inPoint: inPoint),
                style: planned.style)
        case .beatMatched(let p):
            return PlannedTransition(
                plan: .beatMatched(BeatMatchedPlan(
                    outPoint: min(p.outPoint, max(0, outgoingDuration - fade)),
                    inPoint: p.inPoint, overlapBars: p.overlapBars,
                    outgoingRate: p.outgoingRate, incomingRate: p.incomingRate,
                    bassSwapOffset: fade / 2, overlapDuration: fade)),
                style: planned.style)
        case .gapless:
            return PlannedTransition(
                plan: .crossfade(duration: fade,
                                 outPoint: max(0, outgoingDuration - fade), inPoint: 0),
                style: planned.style)
        }
    }

    /// A signal is a "near miss" when it sits within 15 % of a threshold —
    /// i.e. nudging that planner constant would move this pair to another tier.
    private static func nearMisses(signals: TransitionPlanner.Signals,
                                   keyDistance: Int?,
                                   outVocal: Double?, inVocal: Double?,
                                   config: TransitionPlanner.Config) -> [String] {
        var out: [String] = []
        func check(_ label: String, _ value: Double, _ threshold: Double,
                   _ thresholdName: String, format: String = "%.3f") {
            guard threshold > 0, abs(value - threshold) / threshold <= 0.15 else { return }
            let side = value > threshold ? "just over" : "just under"
            out.append(String(format: "\(label) \(format) \(side) \(thresholdName) \(format)",
                              value, threshold))
        }
        check("loudness", signals.loudnessGapDB, config.neutralLoudnessDB,
              "the neutral line", format: "%.2f dB")
        check("loudness", signals.loudnessGapDB, config.clashLoudnessDB,
              "the clash line", format: "%.2f dB")
        check("timbre", signals.timbreDistance, config.neutralTimbreDistance,
              "the neutral line")
        check("timbre", signals.timbreDistance, config.clashTimbreDistance,
              "the clash line")
        if let ratio = signals.tempoRatio {
            check("tempo", ratio, config.clashTempoRatio, "the clash line")
            check("tempo", ratio, config.maxBPMDeltaRatio,
                  "the beat-match line")
        }
        if let keyDistance, keyDistance == config.clashKeyDistance - 1 {
            out.append("key distance \(keyDistance), one fifth short of the "
                       + "\(config.clashKeyDistance) that demotes to neutral")
        }
        for (label, score) in [("outgoing", outVocal), ("incoming", inVocal)] {
            guard let score else { continue }
            check("\(label) vocals", score, config.vocalClashRatio,
                  "the vocal-clash line", format: "%.2f")
        }
        return out
    }
}
