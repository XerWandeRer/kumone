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

    // MARK: - Grid self-check calibration

    // `audition grid` — the measurement `ScoreCompiler`'s two self-check layers
    // are calibrated on, kept in the tree so the numbers in that file's
    // comments can be re-derived rather than believed.
    //
    // The point of the mode is *which windows* it measures. A score never lands
    // in the middle of a track: it lands where the planner put the out point
    // (the outro neighbourhood) and where it put the in point (the intro
    // neighbourhood), and those edges jitter for musical reasons a whole-track
    // statistic averages away. Calibrating the general to gate the edge is the
    // mistake that put the cap at 3 % and refused essentially every scored seam
    // in the field; this mode is how that was found and how it stays found.
    //
    // Read-only and offline like `intent`: sidecars only, never analyzes.

    /// One edge window, measured where the planner actually put a cue.
    public struct GridWindowRow: Sendable {
        public let track: String
        /// `exit` (outro side, the out point) or `entry` (intro side, the in
        /// point) — the two neighbourhoods a score is ever addressed in.
        public let side: String
        public let at: TimeInterval
        /// Worst bar-length deviation in `gridCheckBars` either side — what the
        /// backstop reads.
        public let windowCV: Double?
        /// Disagreement between the two bars touching the anchoring downbeat —
        /// what the anchor check reads.
        public let anchorFlank: Double?
        /// Worst beat-interval deviation inside those two bars.
        public let anchorBeatOutlier: Double?
        /// Nil when the anchor is sound; otherwise the compiler's own sentence.
        public let anchorFault: String?
    }

    /// One adjacent pair, and what the compiler said about a plain cut on it.
    public struct GridPairRow: Sendable {
        public let outgoing: String
        public let incoming: String
        public let planKind: String
        /// Bar-length CV around the **compiled seam** on each side — the exact
        /// windows the backstop reads, not the planner's cue points, which the
        /// aim and the phrase snap can leave bars away.
        public let exitCV: Double?
        public let entryCV: Double?
        public let compiled: Bool
        /// Which layer refused, when one did — `anchor`, `backstop`, or the
        /// non-grid reason the compile fell over on first.
        public let refusal: String?
    }

    public struct GridReport: Sendable {
        public let windows: [GridWindowRow]
        public let pairs: [GridPairRow]
        /// The two live thresholds, carried out so the CLI prints what the
        /// compiler is actually enforcing rather than a copy that can drift.
        public let backstopTolerance: Double
        public let anchorFlankTolerance: Double
    }

    /// Measure the edge windows of `files` and compile a plain `cutOnOne` on
    /// every adjacent pair.
    ///
    /// `score` is forced on the same way `intentReport` forces `intent` on: a
    /// calibration run of a check that never ran would be a page of blanks.
    ///
    /// `allPairs` walks every ordered pair rather than only the adjacent ones.
    /// The schedule a corpus directory implies is alphabetical, which is not
    /// the order anybody listened in — so when the question is "what does this
    /// check do to the seams the owner actually hears", the adjacency is the
    /// wrong sample and the full cross product is the right one. Quadratic, but
    /// planning is a pure function over two cached analyses, so it stays cheap.
    public static func gridReport(
        files: [URL], allPairs: Bool = false,
        config configOverrides: [String: Double] = [:]
    ) throws -> GridReport {
        var overrides = configOverrides
        overrides["scoreEnabled"] = 1

        var analyses: [(url: URL, analysis: TrackAnalysis)] = []
        for file in files {
            guard let analysis = try? analysis(of: file) else { continue }
            analyses.append((file, analysis))
        }

        // The cues a score is addressed around, without needing a partner
        // track: where the planner takes out points from (the outro side) and
        // where it takes in points from (the intro side). `phraseBoundaries` is
        // the candidate list itself, so these are the real windows and not a
        // sampling of the track.
        var windows: [GridWindowRow] = []
        for entry in analyses {
            let a = entry.analysis
            guard a.downbeats.count >= 12 else { continue }
            var cues: [(String, TimeInterval)] = []
            if let fade = a.outroFadeStart { cues.append(("exit", fade)) }
            cues += a.phraseBoundaries.filter { $0 > a.duration * 0.6 }.map { ("exit", $0) }
            cues.append(("entry", a.introEnd))
            cues += a.phraseBoundaries.filter { $0 < a.duration * 0.3 }.map { ("entry", $0) }
            for (side, at) in cues {
                guard let index = ScoreCompiler.nearestIndex(a.downbeats, to: at),
                      index > 0, index + 1 < a.downbeats.count else { continue }
                let before = a.downbeats[index] - a.downbeats[index - 1]
                let after = a.downbeats[index + 1] - a.downbeats[index]
                let bar = (before + after) / 2
                let flank = bar > 1e-6 ? abs(before - after) / bar : nil
                let local = a.beats.filter { $0 >= a.downbeats[index - 1] - 1e-6
                                             && $0 <= a.downbeats[index + 1] + 1e-6 }
                var intervals: [TimeInterval] = []
                for i in 0..<max(0, local.count - 1) where local[i + 1] > local[i] {
                    intervals.append(local[i + 1] - local[i])
                }
                var outlier: Double?
                if intervals.count >= 3 {
                    let median = intervals.sorted()[intervals.count / 2]
                    if median > 1e-6 {
                        outlier = intervals.map { abs($0 - median) / median }.max()
                    }
                }
                windows.append(GridWindowRow(
                    track: entry.url.lastPathComponent, side: side, at: at,
                    windowCV: ScoreCompiler.worstJitter(a.downbeats, around: at,
                                                        bars: ScoreCompiler.gridCheckBars),
                    anchorFlank: flank, anchorBeatOutlier: outlier,
                    anchorFault: ScoreCompiler.anchorFault(
                        downbeats: a.downbeats, beats: a.beats, index: index,
                        flankTolerance: ScoreCompiler.anchorFlankTolerance)))
            }
        }

        var ordered: [(Int, Int)] = []
        if allPairs {
            for i in 0..<analyses.count where analyses.count > 1 {
                for j in 0..<analyses.count where i != j { ordered.append((i, j)) }
            }
        } else {
            for i in 1..<max(1, analyses.count) { ordered.append((i - 1, i)) }
        }

        var pairs: [GridPairRow] = []
        for (i, j) in ordered {
            let out = analyses[i], inc = analyses[j]
            guard let decision = try? decide(outgoing: out.url, incoming: inc.url,
                                             score: .cutOnOne(), config: overrides)
            else { continue }
            let refusal = decision.scoreCompiled
                ? nil
                : decision.scoreLines.first { $0.contains("[anchor]") || $0.contains("[backstop]") }
                    ?? decision.scoreLines.last
            pairs.append(GridPairRow(
                outgoing: out.url.lastPathComponent, incoming: inc.url.lastPathComponent,
                planKind: decision.planKind,
                // Nil on a refusal rather than a number from somewhere else:
                // the refusal sentence quotes the jitter it actually measured
                // and names the side, and a column filled in from the cue point
                // would quietly disagree with it.
                exitCV: decision.scoreSeam.flatMap {
                    ScoreCompiler.worstJitter(out.analysis.downbeats, around: $0.outgoing,
                                              bars: ScoreCompiler.gridCheckBars)
                },
                entryCV: decision.scoreSeam.flatMap {
                    ScoreCompiler.worstJitter(inc.analysis.downbeats, around: $0.incoming,
                                              bars: ScoreCompiler.gridCheckBars)
                },
                compiled: decision.scoreCompiled, refusal: refusal))
        }

        return GridReport(windows: windows, pairs: pairs,
                          backstopTolerance: ScoreCompiler.gridJitterTolerance,
                          anchorFlankTolerance: ScoreCompiler.anchorFlankTolerance)
    }
}
