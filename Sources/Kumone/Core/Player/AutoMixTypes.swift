import Foundation

// Shared contracts between the playback engine, the analyzer, and the
// transition planner. See docs/automix-spec.md.

/// One of the engine's two player decks. Tracks alternate decks so a
/// transition can overlap the outgoing and incoming songs.
enum Deck: String, Sendable {
    case a, b

    var other: Deck { self == .a ? .b : .a }
}

/// Per-track beat/energy analysis, computed once in the background and
/// persisted as a sidecar next to the cached audio (spec §4).
struct TrackAnalysis: Codable, Sendable {
    /// Bump when the algorithm changes; stale sidecars are re-analyzed.
    static let currentVersion = 5

    let version: Int
    let bpm: Double
    /// 0–1; below the planner's threshold the track never beat-matches.
    let bpmConfidence: Double
    let beats: [TimeInterval]
    let downbeats: [TimeInterval]
    /// Candidate mix points, best first (8/16-bar grid × energy shifts).
    let phraseBoundaries: [TimeInterval]
    /// RMS at 1s granularity over the whole track.
    let rmsEnvelope: [Float]
    /// Where a natural outro fade begins, if the track has one.
    let outroFadeStart: TimeInterval?
    /// First strong downbeat after any intro silence/buildup.
    let introEnd: TimeInterval
    let duration: TimeInterval
    /// Whole-track timbre fingerprint: the L2-normalized mean *level-removed*
    /// 40-band log-mel frame, averaged over the loud half of the track. Each
    /// frame has its own across-band mean (loudness) subtracted first, so the
    /// vector is pure spectral shape and sums to zero; cosine distance between
    /// two tracks' profiles is then a shape correlation, and is the planner's
    /// style-compatibility signal. Empty for very short input.
    let melProfile: [Float]
    /// Detected musical key as a pitch class 0–11 (C = 0), nil when the
    /// track has no stable tonal center.
    let keyPitchClass: Int?
    /// Whether the detected key is minor (only meaningful with a key).
    let keyIsMinor: Bool
    /// 0–1 confidence of the key estimate; below the planner's threshold
    /// the key never influences decisions.
    let keyConfidence: Double
    /// Vocal-presence likelihood 0–1 at 1s granularity (same grid as
    /// `rmsEnvelope`). Empty when not computed.
    let vocalActivity: [Float]
}

/// Expressive styling for a transition — the technique vocabulary the
/// strategy layer draws from per song pair. Mechanics (timing, rates)
/// stay in `TransitionPlan`; this describes *how* the hand-over sounds.
struct TransitionStyle: Sendable, Equatable {
    enum OutroEffect: Sendable, Equatable {
        /// Plain volume fade.
        case fade
        /// A high-pass sweep hollows the outgoing track out as it leaves.
        case filterSweep
        /// The outgoing track stops on the boundary and a delay tail rings out.
        case echoOut
    }

    let outroEffect: OutroEffect
    /// Staged three-band EQ hand-over (lows last) instead of the single
    /// low-shelf bass swap.
    let stagedEQ: Bool
    /// Beat-synced delay time (seconds) for `.echoOut`, when the planner
    /// knows the outgoing tempo. Nil → the engine derives its own (beat
    /// grid on beat-matched plans, otherwise a fixed 250 ms).
    var echoDelayTime: TimeInterval? = nil
    /// A technique that needs the outgoing track split into vocal and
    /// accompaniment stems. `nil` — the default, and everything the planner
    /// emits today — means the hand-over works on the whole mix, exactly as
    /// it always has. See `StemTechnique`.
    var stemTechnique: StemTechnique? = nil

    static let plain = TransitionStyle(outroEffect: .fade, stagedEQ: false)
}

/// Whether the caller can hand the renderer a vocal/accompaniment split of the
/// outgoing track's overlap window.
///
/// The planner takes this as an explicit input rather than sniffing for a
/// model, so it stays a pure function of its arguments — and so the product
/// path, which passes `.none` everywhere today, provably decides exactly what
/// it decided before stem techniques existed (`TransitionPlanner.plan`).
public enum StemAvailability: Sendable, Equatable {
    /// No separator. Every stem rule is skipped and every stem knob unread.
    case none
    /// A separator is available for this hand-over, so the planner may upgrade
    /// a transition to a `StemTechnique`.
    case ready
}

/// Techniques that only exist once the outgoing track can be split into a
/// vocal stem and its accompaniment (`mixture - vocals`).
///
/// These are *stem-layer* gestures: they rewrite what the outgoing deck is
/// fed, and everything downstream — the fader law, the EQ hand-over, the
/// outro effect — then runs unchanged on top. So `.vocalDuck` under
/// `.filterSweep` is a swept exit whose vocal sits 9 dB down, not a different
/// exit. Recipes and blind-test results: `docs/automix-stems-s1-report.md`.
///
/// `stagedStemSwap` (drums first, bass second) is deliberately absent: it
/// needs a 4-stem model, and StemKit ships a vocals/accompaniment one.
enum StemTechnique: Sendable, Equatable {
    /// The outgoing accompaniment drops out early and its vocal — high-passed,
    /// exempt from the outgoing fade — floats over the incoming full mix
    /// before retiring just before the cut.
    case acapellaOver
    /// The outgoing vocal is wiped at the top of the overlap, so the outgoing
    /// track leaves as an instrumental and the incoming vocal owns the window.
    case instrumentalOut
    /// The outgoing vocal is held `depthDB` down for the whole overlap, so two
    /// vocals stop fighting. S1's blind test liked −9 dB.
    case vocalDuck(depthDB: Float)

    /// Short name for reports and filenames.
    var label: String {
        switch self {
        case .acapellaOver: return "acapellaOver"
        case .instrumentalOut: return "instrumentalOut"
        case .vocalDuck(let depth): return String(format: "vocalDuck(%.1fdB)", depth)
        }
    }
}

/// What the strategy layer hands the engine: mechanics plus chosen styling.
struct PlannedTransition: Sendable {
    let plan: TransitionPlan
    let style: TransitionStyle

    static func plain(_ plan: TransitionPlan) -> PlannedTransition {
        PlannedTransition(plan: plan, style: .plain)
    }
}

/// How to hand over from the current track to the next (spec §5).
enum TransitionPlan: Sendable {
    case beatMatched(BeatMatchedPlan)
    case crossfade(duration: TimeInterval, outPoint: TimeInterval, inPoint: TimeInterval)
    /// Tail-to-head, no overlap.
    case gapless
}

struct BeatMatchedPlan: Sendable {
    /// Phrase boundary in the outgoing track where the overlap starts.
    let outPoint: TimeInterval
    /// First downbeat of the incoming track to align to `outPoint`.
    let inPoint: TimeInterval
    let overlapBars: Int
    /// Playback-rate nudges (≤ ±4% each) so the grids line up; the incoming
    /// deck ramps back to 1.0 after the overlap.
    let outgoingRate: Float
    let incomingRate: Float
    /// Seconds into the overlap where the low end swaps decks.
    let bassSwapOffset: TimeInterval
    /// Total overlap length in seconds at the blended tempo.
    let overlapDuration: TimeInterval
}

extension TransitionPlan {
    /// Seconds before the outgoing track's out point at which the incoming
    /// deck must already be loaded and scheduled.
    var outPoint: TimeInterval? {
        switch self {
        case .beatMatched(let plan): return plan.outPoint
        case .crossfade(_, let outPoint, _): return outPoint
        case .gapless: return nil
        }
    }
}
