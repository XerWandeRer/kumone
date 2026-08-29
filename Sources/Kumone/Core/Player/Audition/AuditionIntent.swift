import Foundation

// `audition intent <dir>` — the P3 acceptance gate, run **before** anybody
// listens to anything.
//
// The intent layer's whole risk is miscalibration (predev risk #6): the grid CV
// and the spectral flatness are proxies, and a threshold that puts quantized
// rock into the cut culture, or a ballad into stand-down, is a wrong answer
// nobody hears until it plays. So the first thing to do with the layer is not
// to listen to it — it is to point it at the whole cached library and read the
// table: does the owner's rock land in `drummerDrift`, his EDM in
// `dropCarrying`, his ballads in `ordinary`. A bucket count is cheap to check
// and a wrong seam is expensive to hear.
//
// Two tables, because the layer has two shapes:
//
//   * **per track** — the material profile, which is a statement about one
//     song and is what a human can actually eyeball against his own library;
//   * **per adjacent pair of the schedule** — the intent class, which is the
//     layer's real output and the thing the planner acts on.
//
// Read-only and offline throughout: sidecars only, no analysis, no network.

extension Audition {

    /// One track's material profile, flattened for printing.
    public struct IntentTrackRow: Sendable {
        public let name: String
        public let duration: TimeInterval
        public let bpm: Double
        public let bpmConfidence: Double
        /// Whole-track downbeat-interval CV. Nil when the grid is too short or
        /// too broken to measure — itself a finding.
        public let gridCV: Double?
        public let flatness: Double?
        public let occupancy: Double?
        /// Absolute mean vocal likelihood, 0…1 — an instrumental at a glance.
        public let vocalMean: Double?
        public let hasDrop: Bool
        public let structureConfidence: Double
        /// `noBeat` / `drummerDrift` / `wall` / `dropCarrying` / `hardGrid` /
        /// `ordinary`.
        public let bucket: String
    }

    /// One adjacent pair of the schedule, and what the intent layer said.
    public struct IntentPairRow: Sendable {
        public let outgoing: String
        public let incoming: String
        public let intentClass: String
        public let budget: Double
        public let reasons: [String]
        /// What the planner then did with it — `beatMatched` / `crossfade` /
        /// `gapless` — so the table shows the *consequence* of the class and
        /// not only the class.
        public let planKind: String
        public let overlap: TimeInterval
        public let outPoint: TimeInterval?
        public let inPoint: TimeInterval?
        /// The plan the same pair gets with the intent layer off, so a reader
        /// can see which seams the layer actually moved.
        public let baselineKind: String
        public let baselineOverlap: TimeInterval
        public let baselineInPoint: TimeInterval?
        /// Whether the layer moved this plan at all — kind, length, or either
        /// cue. `dropAlign` in particular usually keeps the length and moves
        /// only the entry, so a comparison on length alone would report it as
        /// a no-op.
        public var moved: Bool {
            planKind != baselineKind
                || abs(overlap - baselineOverlap) > 0.01
                || abs((inPoint ?? 0) - (baselineInPoint ?? 0)) > 0.01
        }
    }

    public struct IntentReport: Sendable {
        public let tracks: [IntentTrackRow]
        public let pairs: [IntentPairRow]
        /// bucket → count, most common first.
        public let trackBuckets: [(name: String, count: Int)]
        /// class → count, in `TransitionIntent.Class` order (restrained first),
        /// so the table always has the same columns even when one is empty —
        /// a class that never fires is the finding, and a missing row hides it.
        public let pairClasses: [(name: String, count: Int)]
        /// Pairs whose plan the layer changed at all.
        public let movedPairs: Int
    }

    /// Classify every track and every adjacent pair of `files`, in the order
    /// given (the schedule).
    ///
    /// `config` is applied on top of `.standard` exactly as everywhere else,
    /// and `intentEnabled` is forced **on** regardless: this command exists to
    /// look at the layer, and a report of a layer that did not run would be a
    /// page of `intent=off`. Every other knob is whatever the caller passed, so
    /// the command is also how a threshold sweep is read.
    public static func intentReport(
        files: [URL], config configOverrides: [String: Double] = [:]
    ) throws -> IntentReport {
        var overrides = configOverrides
        overrides["intentEnabled"] = 1
        let config = TransitionPlanner.Config.standard(overriding: overrides)
        var baselineOverrides = configOverrides
        baselineOverrides["intentEnabled"] = 0

        var analyses: [(url: URL, analysis: TrackAnalysis)] = []
        for file in files {
            guard let analysis = try? analysis(of: file) else { continue }
            analyses.append((file, analysis))
        }

        let tracks = analyses.map { entry -> IntentTrackRow in
            let profile = MaterialProfile.wholeTrack(entry.analysis, config: config)
            return IntentTrackRow(
                name: entry.url.lastPathComponent,
                duration: entry.analysis.duration,
                bpm: entry.analysis.bpm,
                bpmConfidence: entry.analysis.bpmConfidence,
                gridCV: profile.trackGridCV,
                flatness: profile.flatness,
                occupancy: profile.occupancy,
                vocalMean: profile.vocalMean,
                hasDrop: profile.hasDrop,
                structureConfidence: entry.analysis.structureConfidence,
                bucket: profile.bucket(config: config).rawValue)
        }

        var pairs: [IntentPairRow] = []
        var moved = 0
        for i in 1..<max(1, analyses.count) {
            let out = analyses[i - 1], inc = analyses[i]
            guard let decision = try? decide(outgoing: out.url, incoming: inc.url,
                                             config: overrides),
                  let baseline = try? decide(outgoing: out.url, incoming: inc.url,
                                             config: baselineOverrides)
            else { continue }
            let row = IntentPairRow(
                outgoing: out.url.lastPathComponent,
                incoming: inc.url.lastPathComponent,
                intentClass: decision.intentClass ?? "—",
                budget: decision.intentClass
                    .flatMap { TransitionIntent.Class(rawValue: $0)?.budget } ?? 0,
                reasons: decision.intentReasons,
                planKind: decision.planKind,
                overlap: decision.overlapDuration,
                outPoint: decision.outPoint,
                inPoint: decision.inPoint,
                baselineKind: baseline.planKind,
                baselineOverlap: baseline.overlapDuration,
                baselineInPoint: baseline.inPoint)
            if row.moved { moved += 1 }
            pairs.append(row)
        }

        var bucketCounts: [String: Int] = [:]
        for row in tracks { bucketCounts[row.bucket, default: 0] += 1 }
        var classCounts: [String: Int] = [:]
        for row in pairs { classCounts[row.intentClass, default: 0] += 1 }

        return IntentReport(
            tracks: tracks, pairs: pairs,
            trackBuckets: MaterialProfile.Bucket.allCases
                .map { ($0.rawValue, bucketCounts[$0.rawValue] ?? 0) }
                .sorted { $0.1 > $1.1 },
            pairClasses: TransitionIntent.Class.allCases
                .map { ($0.rawValue, classCounts[$0.rawValue] ?? 0) },
            movedPairs: moved)
    }
}
