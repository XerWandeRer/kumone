import Foundation

// The stateful half of the AutoMix queue-reorder mode
// (docs/automix-queue-predev.md §2.2 / §2.4). The arithmetic lives in
// `QueueOrderScoring.swift`; what is here is bookkeeping — which candidates
// are in the pool, which have an analysis in hand, which one is being fetched,
// and how many rounds each has lost.
//
// **Nothing in this file exists while the mode is off.** `PlayerService` holds
// the selector as an optional and only builds one when the queue order is
// `.autoMix`, so a player in `.listed` or `.shuffled` runs the code it always
// ran, allocates nothing extra and issues no request.

/// Which order the player walks its queue in — the three-state upgrade of the
/// old `shuffleEnabled: Bool` (predev §2.1).
///
/// Mutually exclusive by construction: there is one value, so "turning AutoMix
/// order on turns shuffle off" is not a rule anybody has to remember to apply.
/// The raw `queue` is never reordered by any of them, so leaving a mode always
/// restores the list the user actually gave us.
enum QueueOrder: String, Codable, Sendable, CaseIterable {
    case listed, shuffled, autoMix

    /// The persisted-state migration: sessions written before the mode existed
    /// carry a bare `shuffle` bool and nothing else.
    init(migratingShuffle shuffle: Bool) {
        self = shuffle ? .shuffled : .listed
    }
}

@MainActor
final class QueueOrderSelector {

    /// The quality the *scoring* copy of a candidate is downloaded at
    /// (predev §2.2): the cheapest level NetEase serves, ~4 MB against 20–40
    /// for a lossless file. Every term the scorer reads is shift-invariant, so
    /// the lossy encoder's leading delay cannot reach it — but the beat grid a
    /// *plan* aligns to is not, which is why the winner is re-downloaded at
    /// playback quality and re-analyzed by the ordinary prefetch path before a
    /// single number of the real hand-over is computed.
    static let scoringLevel = AudioQuality.standard.rawValue

    /// One scored candidate, best-first in `lastPick`.
    struct Candidate: Equatable {
        let track: Track
        let score: QueueOrderScore
    }

    var config: QueueOrderConfig = .standard

    /// Fired on the main actor when a candidate analysis lands, so the player
    /// can reconsider a pick it has not committed to yet.
    var onCandidateReady: (() -> Void)?

    /// Scoring analyses in hand, by track ID. Filled from two places: the
    /// on-disk cache (free — a track heard before) and the low-bitrate fetch
    /// below (~4 MB and a couple of seconds).
    private var analyses: [Int: TrackAnalysis] = [:]
    /// Rounds each candidate has been passed over for. The aging term reads
    /// this; nothing else does.
    private var lostRounds: [Int: Int] = [:]
    /// Candidates that could not be fetched or analyzed. Never retried this
    /// session — a track NetEase will not serve at the scoring level will not
    /// start serving it three minutes later, and retrying would starve the
    /// budget-1 queue behind a track that can never join the pool.
    private var refused: Set<Int> = []
    /// Track IDs already looked up in the on-disk cache, so the directory walk
    /// happens once per track rather than once per tick.
    private var scanned: Set<Int> = []

    /// **The whole download budget: one.** The same discipline the existing
    /// prefetch runs under, for the same reason — a second concurrent transfer
    /// competes with the audio that is playing.
    private var fetching = false
    private var scanning = false

    /// The last pick's full candidate table, best first — what the debug panel
    /// prints and the only reason the scores are kept after the choice.
    private(set) var lastPick: [Candidate] = []

    init() {}

    // MARK: - Pool bookkeeping

    /// The candidate pool for a remaining queue `remaining`, in the order the
    /// pool is walked (predev §2.2): the next `config.window` listed entries,
    /// then every other remaining track that already has an analysis in hand.
    ///
    /// The second half is free by construction — it is exactly the set this
    /// selector can score without spending anything — so a playlist whose
    /// audio is already on disk gets the whole list to choose from, while a
    /// cold one is held to the window.
    func pool(remaining: [Track]) -> [Track] {
        let windowed = Array(remaining.prefix(max(1, config.window)))
        var seen = Set(windowed.map(\.id))
        var pool = windowed
        for track in remaining.dropFirst(windowed.count)
        where analyses[track.id] != nil && !seen.contains(track.id) {
            seen.insert(track.id)
            pool.append(track)
        }
        return pool
    }

    /// Whether every candidate in the pool has been resolved one way or the
    /// other — analyzed, or refused. Once true there is nothing left to wait
    /// for and the pick can be made early instead of at the deadline.
    func isSettled(_ pool: [Track]) -> Bool {
        pool.allSatisfy { analyses[$0.id] != nil || refused.contains($0.id) }
    }

    func hasAnalysis(for track: Track) -> Bool { analyses[track.id] != nil }

    var analyzedCount: Int { analyses.count }

    /// Move the pool one step forward: look up whatever has not been looked up
    /// on disk yet, then start at most one download. Cheap and idempotent —
    /// it is called from the playback tick, and returns immediately once a job
    /// is in flight or the pool is settled.
    func ensureCandidates(_ pool: [Track]) {
        guard !scanning, !fetching else { return }
        let unscanned = pool.filter { !scanned.contains($0.id) }
        if !unscanned.isEmpty {
            scanning = true
            let ids = Set(unscanned.map(\.id))
            Task { [weak self] in
                let found = await AudioCache.shared.analyses(forTrackIDs: ids)
                guard let self else { return }
                self.scanned.formUnion(ids)
                self.scanning = false
                var landed = false
                for (id, analysis) in found where self.analyses[id] == nil {
                    self.analyses[id] = analysis
                    landed = true
                }
                if landed { self.onCandidateReady?() }
            }
            return
        }
        guard let next = pool.first(where: {
            analyses[$0.id] == nil && !refused.contains($0.id)
        }) else { return }
        fetching = true
        Task { [weak self] in
            let analysis = await Self.scoringAnalysis(for: next)
            guard let self else { return }
            self.fetching = false
            if let analysis {
                self.analyses[next.id] = analysis
            } else {
                self.refused.insert(next.id)
            }
            self.onCandidateReady?()
        }
    }

    // MARK: - Picking

    /// The highest-scoring **analyzed** candidate, or nil when none of the
    /// pool has an analysis yet.
    ///
    /// Nil is the deadline fallback the caller needs: the mode never waits for
    /// a download at the cost of a gap, it just plays what the list said next
    /// (predev §2.2).
    ///
    /// Pure with respect to the selector's state — call it as often as you
    /// like. `noteRound` is what actually moves the aging counters.
    func pick(
        outgoing: Track?, outgoingAnalysis: TrackAnalysis?,
        pool: [Track],
        plannerConfig: TransitionPlanner.Config = .standard,
        outgoingLyricLineEnds: [TimeInterval] = []
    ) -> Track? {
        var scored: [Candidate] = []
        for track in pool {
            guard let incoming = analyses[track.id] else { continue }
            // The planner *is* the scorer: whatever hand-over it can build for
            // this pair is what the pair is worth (predev §2.3).
            let planned = TransitionPlanner.plan(
                outgoing: outgoingAnalysis, incoming: incoming, stems: .none,
                config: plannerConfig,
                context: .init(outgoingLyricLineEnds: outgoingLyricLineEnds))
            scored.append(Candidate(track: track, score: QueueOrderScorer.score(
                outgoing: outgoingAnalysis, incoming: incoming, planned: planned,
                lostRounds: lostRounds[track.id] ?? 0,
                sharesArtist: Self.sharesArtist(outgoing, track),
                config: config, plannerConfig: plannerConfig)))
        }
        // Ties break on pool order — which is list order for the windowed half
        // — so a pool the scorer cannot tell apart reproduces the user's list
        // rather than an arbitrary permutation. `sorted` is not stable, hence
        // the explicit index tiebreak.
        lastPick = scored.enumerated()
            .sorted {
                $0.element.score.total == $1.element.score.total
                    ? $0.offset < $1.offset
                    : $0.element.score.total > $1.element.score.total
            }
            .map(\.element)
        return lastPick.first?.track
    }

    /// Commit a pick: everyone else in the pool ages by one round.
    ///
    /// Only the pool ages, never the whole remaining queue — a track that was
    /// never offered a seat has not lost anything, and pre-aging the tail of a
    /// long list would let it outrank the head before it was ever considered.
    func noteRound(chosen: Track, pool: [Track]) {
        for track in pool where track.id != chosen.id {
            lostRounds[track.id, default: 0] += 1
        }
        lostRounds[chosen.id] = nil
    }

    /// The queue changed underneath us (new playlist, mode switch). Analyses
    /// are kept — they are on disk anyway and cost nothing to remember — but
    /// every aging counter and the refusal list go, because they described a
    /// queue that no longer exists.
    func reset() {
        lostRounds.removeAll()
        refused.removeAll()
        lastPick = []
    }

    // MARK: - Fetching

    /// Whether the two tracks share a credited artist — the same-artist
    /// penalty's whole input. Artist id 0 is the decoder's "unknown" and never
    /// matches anything.
    static func sharesArtist(_ a: Track?, _ b: Track) -> Bool {
        guard let a else { return false }
        let left = Set(a.artists.map(\.id).filter { $0 != 0 })
        guard !left.isEmpty else { return false }
        return b.artists.contains { $0.id != 0 && left.contains($0.id) }
    }

    /// Resolve, download and analyze one candidate at the scoring level.
    ///
    /// Goes through `AudioCache` like everything else, so the file and its
    /// sidecar land under the ordinary key (`<id>-standard-netease.<ext>`),
    /// take part in LRU eviction, and are found again for free by
    /// `analyses(forTrackIDs:)` on a later queue.
    ///
    /// Trial fragments are refused: a 30-second excerpt has neither the
    /// structure nor the duration the planner needs, and scoring one would be
    /// scoring a different piece of music.
    private static func scoringAnalysis(for track: Track) async -> TrackAnalysis? {
        guard let data = try? await NeteaseAPI.songURL(
                ids: [track.id], level: scoringLevel).first,
              data.freeTrialInfo == nil,
              let urlString = data.url,
              let remote = URL(string: urlString.replacingOccurrences(
                  of: "http://", with: "https://"))
        else { return nil }
        let ext = remote.pathExtension.isEmpty ? "mp3" : remote.pathExtension.lowercased()
        let key = AudioCache.Key(trackID: track.id, level: data.level ?? scoringLevel,
                                 source: "netease", fileExtension: ext)
        if let cached = await AudioCache.shared.loadAnalysis(for: key) { return cached }
        guard let local = try? await AudioCache.shared.download(from: remote, key: key)
        else { return nil }
        let analyzed = await Task.detached(priority: .utility) {
            try? TrackAnalyzer.analyze(fileAt: local)
        }.value
        if let analyzed {
            await AudioCache.shared.storeAnalysis(analyzed, for: key)
        }
        return analyzed
    }
}
