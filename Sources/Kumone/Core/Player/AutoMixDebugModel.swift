import Foundation

// Live read-out of the AutoMix pipeline, for the person running listening
// tests: what is armed, what the analyses say, what the pre-render is doing,
// and what the engine actually played at the last few seams — the things that
// otherwise only exist as log lines nobody reads while listening.
//
// The model is a mirror, never a source: PlayerService pushes small structs at
// the state-change points it already runs through, and nothing here ever reads
// back into the player or the engine. That is what keeps the panel free when
// it is closed (`isActive` is false, so a push writes one struct and stops)
// and what keeps it honest when it is open — every number shown is a number
// the player itself acted on.
//
// The view is macOS-only; the model is not, so PlayerService can push
// unconditionally instead of carrying `#if os(macOS)` at a dozen call sites.
// On iOS every plan is `.gapless` and nothing ever activates it, so the whole
// thing costs a Bool test per push.

/// The "Now" group: what is audible this instant.
struct AutoMixDebugNow: Equatable {
    var title: String?
    /// A player-level phase, not the engine's own `TransitionPhase` (which is
    /// private to the audio queue): idle / buffering / playing / paused, plus
    /// what the hand-over pipeline has reached.
    var phase = "idle"
    var deck = "—"
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    /// Loudness-compensation trim the current deck was loaded at.
    var trimDB: Double = 0
    /// The playing track has a full analysis in hand (so a real plan is possible).
    var analyzed = false
}

/// How far the prefetch pipeline has got with the auto-advance target.
enum AutoMixPrefetchStage: Equatable {
    case idle
    case resolving
    case downloading
    case downloaded
    case analyzing
    case analyzed
    /// The pipeline chose not to run — not an error, and not a state a retry
    /// would help (the same track is still streaming into the cache).
    case deferred(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "idle"
        case .resolving: return "resolving"
        case .downloading: return "downloading"
        case .downloaded: return "downloaded"
        case .analyzing: return "analyzing"
        case .analyzed: return "analyzed"
        case .deferred(let why): return "deferred — \(why)"
        case .failed(let reason): return "failed — \(reason)"
        }
    }
}

/// The "Next (prefetch)" group.
struct AutoMixDebugNext: Equatable {
    var title: String?
    var stage: AutoMixPrefetchStage = .idle
    var bpm: Double?
    var bpmConfidence: Double?
    /// Pre-formatted, because a pitch class plus a minor flag plus a confidence
    /// is three fields the panel would only ever print as one string.
    var key: String?
    var lufs: Double?
    var sectionCount: Int?
    var structureConfidence: Double?
    /// A `.lrc` sits next to the cached file — i.e. a `vocalExchange` has words
    /// to aim at when this track becomes the *outgoing* side, one seam later.
    var hasLyricSidecar = false
}

/// The "Plan (armed)" group: the hand-over PlayerService has handed the engine.
///
/// Everything here is derived from a `PlannedTransition` plus the two analyses
/// it was planned from — a pure mapping, so it can be built and asserted on
/// without a player.
struct AutoMixDebugPlan: Equatable {
    var kind = "gapless"
    var outPoint: TimeInterval?
    var inPoint: TimeInterval?
    var overlap: TimeInterval = 0
    var overlapBars: Int?
    var outgoingRate: Float?
    var incomingRate: Float?
    var outroEffect = "fade"
    var stagedEQ = false
    var stemTechnique: String?
    var rideDB: Double = 0
    /// Which structural section the out point falls in, when the outgoing
    /// analysis has sections at all (it usually does not — see `TrackAnalysis`).
    var outSection: String?
    /// Where the in point looks like it came from, read back off the incoming
    /// analysis. The planner does not record its reasoning, so this is a
    /// best-effort match against the landmarks it chooses between.
    var inPointSource: String?
}

/// The stem pre-render's own little state machine, mirrored from
/// `PlayerService.updateStemPrerender`.
enum AutoMixPrerenderState: Equatable {
    case idle
    /// Separation + render running for this seam. The renderer is one call, so
    /// "separating" and "rendering" are not told apart here.
    case rendering(String)
    /// Finished and accepted by the engine: this seam will be spliced.
    case armed(String)
    /// Started and dropped before it could be used.
    case abandoned(String)
    /// Finished, but the engine would not take it.
    case refused(String)

    var label: String {
        switch self {
        case .idle: return "idle"
        case .rendering(let s): return "rendering — \(s)"
        case .armed(let s): return "armed — \(s)"
        case .abandoned(let reason): return "abandoned — \(reason)"
        case .refused(let reason): return "refused — \(reason)"
        }
    }
}

/// One finished seam, frozen the moment it became audible.
struct AutoMixDebugSeam: Identifiable, Equatable {
    let id = UUID()
    var at = Date()
    var from: String?
    var to: String?
    /// The plan PlayerService armed — possibly not the one that ran.
    var planned: AutoMixDebugPlan?
    /// splicedSegment / liveOverlap / gapless.
    var path: String
    /// The plan the engine actually executed.
    var executedKind: String
    var executedOutPoint: TimeInterval?
    var executedOverlap: TimeInterval
    /// Non-nil when the two differ — the engine could not reach the armed out
    /// point and anchored something shorter at the end of the track instead.
    var fallback: String?
    /// What the pre-render had come to by the time the seam played.
    var prerender: String
}

struct AutoMixDebugSnapshot: Equatable {
    var now = AutoMixDebugNow()
    var next = AutoMixDebugNext()
    var plan: AutoMixDebugPlan?
    var prerender = AutoMixPrerenderState.idle
    /// Newest first; the last three seams.
    var seams: [AutoMixDebugSeam] = []
}

@MainActor
final class AutoMixDebugModel: ObservableObject {
    static let shared = AutoMixDebugModel()

    /// How many finished seams the panel keeps.
    static let seamHistoryLimit = 3

    /// The panel window is open. False is the normal case, and then every
    /// recorder below writes `live` and returns without touching the published
    /// snapshot — no observable change, so SwiftUI schedules nothing for a
    /// window nobody has opened, and no timer exists to stop.
    private(set) var isActive = false

    /// What the panel draws.
    @Published private(set) var snapshot = AutoMixDebugSnapshot()

    /// The copy the recorders write. Kept up to date even while closed, so
    /// opening the window shows the truth immediately rather than blank fields
    /// waiting for the next state change.
    private var live = AutoMixDebugSnapshot()

    /// The pre-render state as the panel prints it, readable whether or not the
    /// window is open — the seam recorder freezes it into its history row, and
    /// history has to be right even for seams heard before the panel opened.
    var currentPrerenderLabel: String { live.prerender.label }

    /// Test hook: the history as recorded, without opening a window to publish it.
    var currentSeamsForTesting: [AutoMixDebugSeam] { live.seams }

    private init() {}

    func activate() {
        isActive = true
        snapshot = live
    }

    func deactivate() {
        isActive = false
    }

    private func publish() {
        guard isActive else { return }
        snapshot = live
    }

    // MARK: - Recorders

    func setNow(_ now: AutoMixDebugNow) {
        guard live.now != now else { return }
        live.now = now
        publish()
    }

    func setNextTitle(_ title: String?, stage: AutoMixPrefetchStage) {
        // A new target wipes whatever the previous one's analysis said; the
        // fields are only meaningful together with the title above them.
        if live.next.title != title { live.next = AutoMixDebugNext(title: title) }
        live.next.stage = stage
        publish()
    }

    func setNextStage(_ stage: AutoMixPrefetchStage) {
        live.next.stage = stage
        publish()
    }

    func setNextAnalysis(_ analysis: TrackAnalysis?, localURL: URL?) {
        live.next.stage = analysis == nil
            ? .deferred("no analysis — AutoMix off, or the analyzer declined")
            : .analyzed
        live.next.bpm = analysis?.bpm
        live.next.bpmConfidence = analysis?.bpmConfidence
        live.next.key = analysis.flatMap(AutoMixDebugFormat.key)
        live.next.lufs = analysis?.referenceLoudness
        live.next.sectionCount = analysis?.sections.count
        live.next.structureConfidence = analysis?.structureConfidence
        live.next.hasLyricSidecar = localURL.map(AutoMixDebugFormat.hasLyricSidecar) ?? false
        publish()
    }

    func clearNext() {
        live.next = AutoMixDebugNext()
        publish()
    }

    func setPlan(_ plan: AutoMixDebugPlan?) {
        guard live.plan != plan else { return }
        live.plan = plan
        publish()
    }

    func setPrerender(_ state: AutoMixPrerenderState) {
        guard live.prerender != state else { return }
        live.prerender = state
        publish()
    }

    func recordSeam(_ seam: AutoMixDebugSeam) {
        live.seams.insert(seam, at: 0)
        if live.seams.count > Self.seamHistoryLimit {
            live.seams.removeLast(live.seams.count - Self.seamHistoryLimit)
        }
        publish()
    }
}

/// Pure formatting/derivation used by both the recorders and the view. Split
/// out so the mapping can be exercised without a player or a window.
enum AutoMixDebugFormat {

    static let pitchNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static func key(_ analysis: TrackAnalysis) -> String? {
        guard let pitch = analysis.keyPitchClass, (0..<12).contains(pitch) else { return nil }
        return String(format: "%@ %@ (%.2f)", pitchNames[pitch],
                      analysis.keyIsMinor ? "min" : "maj", analysis.keyConfidence)
    }

    static func hasLyricSidecar(_ audio: URL) -> Bool {
        FileManager.default.fileExists(atPath: Audition.Lyrics.sidecarURL(for: audio).path)
    }

    static func planKind(_ plan: TransitionPlan) -> String {
        switch plan {
        case .beatMatched: return "beatMatched"
        case .crossfade: return "crossfade"
        case .gapless: return "gapless"
        }
    }

    static func overlap(_ plan: TransitionPlan) -> TimeInterval {
        switch plan {
        case .beatMatched(let p): return p.overlapDuration
        case .crossfade(let duration, _, _): return duration
        case .gapless: return 0
        }
    }

    static func inPoint(_ plan: TransitionPlan) -> TimeInterval? {
        switch plan {
        case .beatMatched(let p): return p.inPoint
        case .crossfade(_, _, let point): return point
        case .gapless: return nil
        }
    }

    static func outroEffect(_ effect: TransitionStyle.OutroEffect) -> String {
        switch effect {
        case .fade: return "fade"
        case .filterSweep: return "filterSweep"
        case .echoOut: return "echoOut"
        }
    }

    /// mm:ss, or "—" for a value that is not a time yet.
    static func clock(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, abs(total % 60))
    }

    /// The structural section a cue point falls in, named the way the panel
    /// prints it. Nil when the analysis has no sections (the common case) or
    /// the point is outside them.
    static func section(at time: TimeInterval, in analysis: TrackAnalysis?) -> String? {
        guard let analysis, !analysis.sections.isEmpty else { return nil }
        guard let hit = analysis.sections.first(where: { time >= $0.start && time < $0.end })
        else { return nil }
        return String(format: "%@ %@–%@ ×%d", hit.kind.rawValue,
                      clock(hit.start), clock(hit.end), hit.repetition)
    }

    /// Best-effort provenance for an in point: match it against the landmarks
    /// the planner picks between. Matching, not recording — the planner is a
    /// pure function that keeps no trace of which one it used.
    static func inPointSource(_ inPoint: TimeInterval, incoming: TrackAnalysis?) -> String? {
        guard let incoming else { return nil }
        let slack: TimeInterval = 0.05
        if inPoint < slack { return "track start" }
        if abs(inPoint - incoming.introEnd) < slack { return "introEnd" }
        if let hit = incoming.sections.first(where: { abs($0.start - inPoint) < slack }) {
            return "section start (\(hit.kind.rawValue))"
        }
        if incoming.phraseBoundaries.contains(where: { abs($0 - inPoint) < slack }) {
            return "phrase boundary"
        }
        if incoming.downbeats.contains(where: { abs($0 - inPoint) < slack }) {
            return "downbeat"
        }
        return "free"
    }

    /// How the engine's executed plan differs from the armed one, or nil when
    /// it ran exactly what it was handed. This is the fallback the engine takes
    /// when a seek (or a late arm) has put the out point behind the playhead —
    /// see `PlaybackEngine.resolvePlanLocked`.
    static func fallback(planned: AutoMixDebugPlan?, executed: TransitionPlan) -> String? {
        guard let planned else { return nil }
        let kind = planKind(executed)
        let overlap = overlap(executed)
        if planned.kind != kind {
            return "\(planned.kind) → \(kind) (out point unreachable)"
        }
        guard abs(planned.overlap - overlap) > 0.01
                || abs((planned.outPoint ?? 0) - (executed.outPoint ?? 0)) > 0.01
        else { return nil }
        return String(format: "re-anchored: overlap %.2fs → %.2fs, out %@ → %@",
                      planned.overlap, overlap,
                      clock(planned.outPoint), clock(executed.outPoint))
    }
}

extension AutoMixDebugPlan {
    /// Flatten a planned hand-over plus the analyses it was planned from into
    /// what the panel prints.
    init(planned: PlannedTransition, outgoing: TrackAnalysis?, incoming: TrackAnalysis?) {
        self.init()
        kind = AutoMixDebugFormat.planKind(planned.plan)
        outPoint = planned.plan.outPoint
        inPoint = AutoMixDebugFormat.inPoint(planned.plan)
        overlap = AutoMixDebugFormat.overlap(planned.plan)
        if case .beatMatched(let p) = planned.plan {
            overlapBars = p.overlapBars
            outgoingRate = p.outgoingRate
            incomingRate = p.incomingRate
        }
        outroEffect = AutoMixDebugFormat.outroEffect(planned.style.outroEffect)
        stagedEQ = planned.style.stagedEQ
        stemTechnique = planned.style.stemTechnique?.label
        rideDB = planned.rideDB
        outSection = outPoint.flatMap { AutoMixDebugFormat.section(at: $0, in: outgoing) }
        inPointSource = inPoint.flatMap {
            AutoMixDebugFormat.inPointSource($0, incoming: incoming)
        }
    }
}
