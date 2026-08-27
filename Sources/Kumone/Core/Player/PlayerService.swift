import AVFoundation
import Foundation

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Where the current queue came from — used for scrobbling and UI affordances.
enum PlaySource: Equatable {
    case playlist(Int)
    case album(Int)
    case artist(Int)
    case daily
    case cloud
    case none

    var sourceID: Int {
        switch self {
        case .playlist(let id), .album(let id), .artist(let id): return id
        default: return 0
        }
    }
}

/// Where playback started from — listed under "Recently Played" in the Dock
/// menu, where picking one reloads it and starts playing again.
///
/// This is deliberately separate from `PlaySource`: heartbeat mode plays out
/// of the liked-songs playlist for scrobbling purposes, but as a *place* it is
/// its own thing, and the recents page has no source at all.
struct PlayContext: Codable, Hashable {
    enum Kind: String, Codable {
        /// Reloaded by id.
        case playlist, album, artist
        /// Fixed per-account entry points, each reloaded from its own API.
        case daily, cloud, recents, heartbeat, fm
    }

    let kind: Kind
    /// Zero for the fixed entry points, which have no id of their own.
    let id: Int
    let name: String

    static func playlist(id: Int, name: String) -> PlayContext {
        .init(kind: .playlist, id: id, name: name)
    }

    static func album(id: Int, name: String) -> PlayContext {
        .init(kind: .album, id: id, name: name)
    }

    static func artist(id: Int, name: String) -> PlayContext {
        .init(kind: .artist, id: id, name: name)
    }

    static var daily: PlayContext { .init(kind: .daily, id: 0, name: String(localized: "每日推荐")) }
    static var cloud: PlayContext { .init(kind: .cloud, id: 0, name: String(localized: "音乐云盘")) }
    static var recents: PlayContext { .init(kind: .recents, id: 0, name: String(localized: "最近播放")) }
    static var heartbeat: PlayContext { .init(kind: .heartbeat, id: 0, name: String(localized: "心动模式")) }
    static var fm: PlayContext { .init(kind: .fm, id: 0, name: String(localized: "私人漫游")) }

    /// Identity is the place, not its current title — a renamed playlist is
    /// still the same entry in the recents list.
    static func == (lhs: PlayContext, rhs: PlayContext) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(id)
    }
}

enum RightPanel {
    case lyrics, queue
}

/// The playback engine: queue, shuffle/repeat, personal FM, URL resolution,
/// lyrics, scrobbling. Modeled on YesPlayMusic's Player class, backed by AVPlayer.
/// High-frequency playback position, isolated so per-tick updates only
/// re-render the scrubbers/lyrics that observe it — not every view holding
/// the PlayerService.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var progress: TimeInterval = 0
}

@MainActor
final class PlayerService: ObservableObject {
    static let shared = PlayerService()

    // MARK: - Observable state

    @Published private(set) var queue: [Track] = []
    @Published private(set) var shuffledQueue: [Track] = []
    @Published private(set) var playNextList: [Track] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var currentTrack: Track?
    @Published private(set) var source: PlaySource = .none
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var servedQuality: String?
    @Published private(set) var unblockSource: String?
    @Published private(set) var isTrial = false
    let clock = PlaybackClock()
    /// Passthrough to the clock so existing `progress` reads/writes keep working.
    var progress: TimeInterval {
        get { clock.progress }
        set { clock.progress = newValue }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat") }
    }

    @Published private(set) var shuffleEnabled = false
    @Published var volume: Float = 1 {
        didSet {
            engine.outputVolume = volume
            UserDefaults.standard.set(volume, forKey: "player.volume")
        }
    }

    @Published private(set) var isFMMode = false
    @Published private(set) var fmUpcoming: [Track] = []
    /// Where playback was most recently started from, newest first —
    /// surfaced as "Recently Played" in the Dock menu.
    @Published private(set) var recentContexts: [PlayContext] = []
    @Published private(set) var lyrics: ParsedLyrics?
    @Published var activePanel: RightPanel?
    @Published var showNowPlaying = false

    /// The list the player is walking through (shuffled or ordered).
    var activeQueue: [Track] { shuffleEnabled ? shuffledQueue : queue }

    var upcomingTracks: [Track] {
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
        let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
        return playNextList + Array(rest.prefix(200))
    }

    var hasCurrentTrack: Bool { currentTrack != nil }

    // MARK: - Engine

    private let engine = PlaybackEngine()
    /// The deck currently carrying the audible track; hand-overs flip it.
    private var activeDeck: Deck = .a
    /// The active deck has a source loaded (file or progressive stream).
    private var deckLoaded = false
    /// The loaded source is a complete local file, so the engine can seek
    /// sample-accurately and repeat-one can restart in place.
    private var hasLocalFile = false
    /// Cache entry for the source now playing; nil for trial fragments,
    /// which are never cached.
    private var currentCacheKey: AudioCache.Key?
    private var currentRemoteURL: URL?
    private var progressTimer: Timer?
    private var resolveGeneration = 0
    /// True while the engine is paused by us (togglePlayPause/pause/
    /// interruption). When false, "resume" must re-issue play() instead —
    /// engine.resume() is a no-op on a drained or never-paused deck.
    private var enginePaused = false

    // Auto-advance pipeline: the next track is resolved, downloaded (and
    // later analyzed) while the current one plays, then armed on the other
    // deck so the engine can hand over without touching the network.
    private struct PrefetchedNext {
        let track: Track
        let key: AudioCache.Key
        let localURL: URL
        let level: String?
        let unblockSource: String?
        var analysis: TrackAnalysis?
    }

    private var prefetchTask: Task<Void, Never>?
    private var prefetchedNext: PrefetchedNext?
    private var transitionArmed = false
    private var pendingTransitionTrack: Track?
    /// Beat/energy analysis of the track now playing, once its full file is
    /// on disk. Feeds the outgoing side of TransitionPlanner.
    private var currentAnalysis: TrackAnalysis?
    private var consecutiveFailures = 0
    private var scrobbled = false

    private init() {
        volume = UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.8
        engine.outputVolume = volume
        repeatMode = UserDefaults.standard.string(forKey: "player.repeat")
            .flatMap(RepeatMode.init) ?? .off

        #if os(iOS)
        // The engine configures the AVAudioSession lazily on first start.

        // Resume after interruptions (phone calls, WeChat voice messages, …).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleAudioInterruption(note)
            }
        }
        // Pause when the output route disappears (headphones unplugged).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                      reason == .oldDeviceUnavailable, self.isPlaying else { return }
                self.pause()
            }
        }
        #endif

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, self.deckLoaded, !self.isScrubbing else { return }
                let seconds = self.engine.position(of: self.activeDeck)
                if seconds.isFinite, abs(seconds - self.progress) > 0.05 {
                    self.progress = seconds
                    NowPlayingManager.shared.updateElapsed(seconds, rate: 1)
                }
            }
        }
        // .common keeps the clock ticking through menu tracking and window
        // drags, where the default run-loop mode starves plain timers.
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer

        Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                guard let self else { return }
                self.handleEngineEvent(event)
            }
        }

        NowPlayingManager.shared.attach(to: self)
        restoreState()
    }

    /// Set while the user drags the seek bar so the time observer doesn't fight the thumb.
    var isScrubbing = false

    #if os(iOS)
    private var wasPlayingBeforeInterruption = false

    private func handleAudioInterruption(_ note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                // The system already silenced us; mark the engine paused too,
                // or the .ended resume() below is a guarded no-op.
                engine.pause()
                enginePaused = true
                isPlaying = false
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
            }
        case .ended:
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume) else { return }
            wasPlayingBeforeInterruption = false
            try? AVAudioSession.sharedInstance().setActive(true)
            engine.resume()
            enginePaused = false
            isPlaying = true
            NowPlayingManager.shared.updateElapsed(progress, rate: 1)
        @unknown default:
            break
        }
    }
    #endif

    // MARK: - Entry points

    /// - Parameter context: the place these tracks came from. Supplying it
    ///   lists that place in the Dock menu's recently played section; callers
    ///   playing an ad-hoc selection (search results, a single track) omit it.
    func play(tracks: [Track], source: PlaySource, startAt track: Track? = nil,
              context: PlayContext? = nil) {
        guard !tracks.isEmpty else { return }
        if let context { recordRecent(context) }
        isFMMode = false
        queue = tracks
        self.source = source
        playNextList.removeAll()
        let startTrack = track ?? tracks[0]
        if shuffleEnabled {
            reshuffle(keeping: startTrack)
            currentIndex = 0
        } else {
            currentIndex = tracks.firstIndex(where: { $0.id == startTrack.id }) ?? 0
        }
        startPlaying(activeQueue[currentIndex])
    }

    func playTrack(_ track: Track) {
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        } else {
            play(tracks: [track], source: .none)
        }
    }

    /// Insert a track right after the current one.
    func addToPlayNext(_ track: Track, playNow: Bool = false) {
        playNextList.append(track)
        if playNow || currentTrack == nil {
            advanceToNext(userInitiated: true)
        } else {
            ToastCenter.shared.show(String(localized: "已添加到下一首播放"))
            schedulePrefetch()
        }
    }

    func togglePlayPause() {
        guard let track = currentTrack else { return }
        if isPlaying {
            engine.pause()
            enginePaused = true
            isPlaying = false
        } else if !deckLoaded {
            // Restored session: re-resolve the source.
            startPlaying(track, indexUnchanged: true)
            return
        } else if enginePaused {
            engine.resume()
            enginePaused = false
            isPlaying = true
        } else {
            // The deck drained (queue end) or was loaded without playing —
            // resume() would be a no-op; re-issue play from where we are.
            engine.play(deck: activeDeck, from: min(progress, max(0, duration - 0.1)))
            isPlaying = true
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
    }

    func pause() {
        engine.pause()
        enginePaused = true
        isPlaying = false
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    func next() {
        advanceToNext(userInitiated: true)
    }

    func previous() {
        if isFMMode { return }
        if progress > 4 || activeQueue.isEmpty {
            seek(to: 0)
            return
        }
        var idx = currentIndex - 1
        if idx < 0 {
            guard repeatMode == .all else {
                seek(to: 0)
                return
            }
            idx = activeQueue.count - 1
        }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    func seek(to seconds: TimeInterval) {
        // An armed/overlapping hand-over is anchored to the old timeline —
        // cancel it, seek, then re-arm from the prefetched file.
        //
        // The re-armed plan still carries the out point the planner computed
        // for the whole track, which the seek may have just jumped past. The
        // engine (resolvePlanLocked) degrades such a plan to a tail-anchored
        // crossfade or to gapless instead of firing it on the spot — a seek
        // into the transition window must never start the next song.
        let wasArmed = transitionArmed
        if wasArmed { disarmTransition() }
        progress = seconds
        engine.seek(deck: activeDeck, to: seconds)
        NowPlayingManager.shared.updateElapsed(seconds, rate: isPlaying ? 1 : 0)
        if wasArmed { armTransitionIfReady() }
    }

    func toggleShuffle() {
        guard !isFMMode else { return }
        shuffleEnabled.toggle()
        guard let current = currentTrack else { return }
        if shuffleEnabled {
            reshuffle(keeping: current)
            currentIndex = 0
        } else {
            currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
        }
        schedulePrefetch()
    }

    func cycleRepeatMode() {
        guard !isFMMode else { return }
        repeatMode = repeatMode.next
        // Repeat-one forbids auto hand-overs; the other modes change what
        // comes after the final queue entry.
        schedulePrefetch()
    }

    /// Jump to a track in the upcoming list (queue panel click).
    func jumpTo(_ track: Track) {
        if let nextIdx = playNextList.firstIndex(where: { $0.id == track.id }) {
            playNextList.removeSubrange(0...nextIdx)
            startPlaying(track, indexUnchanged: true)
            return
        }
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        }
    }

    func removeFromUpcoming(_ track: Track) {
        if let idx = playNextList.firstIndex(where: { $0.id == track.id }) {
            playNextList.remove(at: idx)
            return
        }
        if let idx = queue.firstIndex(where: { $0.id == track.id }), idx != currentIndex || shuffleEnabled {
            queue.remove(at: idx)
        }
        if let idx = shuffledQueue.firstIndex(where: { $0.id == track.id }) {
            shuffledQueue.remove(at: idx)
        }
        schedulePrefetch()
    }

    // MARK: - Personal FM

    func startFM() {
        guard !isFMMode || !isPlaying else { return }
        recordRecent(.fm)
        isFMMode = true
        shuffleEnabled = false
        repeatMode = .off
        queue = []
        shuffledQueue = []
        playNextList = []
        currentIndex = -1
        source = .none
        Task { await fmAdvance() }
    }

    func fmNext() {
        guard isFMMode else { return }
        Task { await fmAdvance() }
    }

    func fmTrash() {
        guard isFMMode, let track = currentTrack else { return }
        Task {
            await fmAdvance()
            try? await NeteaseAPI.fmTrash(id: track.id)
        }
    }

    private func fmAdvance() async {
        if fmUpcoming.isEmpty {
            for attempt in 0..<3 {
                if let tracks = try? await NeteaseAPI.personalFM(), !tracks.isEmpty {
                    fmUpcoming = tracks
                    break
                }
                if attempt == 2 {
                    ToastCenter.shared.show(String(localized: "获取私人漫游数据失败"))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard !fmUpcoming.isEmpty else { return }
        let track = fmUpcoming.removeFirst()
        startPlaying(track, indexUnchanged: true)
        if fmUpcoming.count < 1 {
            if let more = try? await NeteaseAPI.personalFM() {
                fmUpcoming.append(contentsOf: more)
            }
        }
    }

    // MARK: - Advancing

    private func advanceToNext(userInitiated: Bool) {
        if isFMMode {
            Task { await fmAdvance() }
            return
        }
        if !playNextList.isEmpty {
            let track = playNextList.removeFirst()
            startPlaying(track, indexUnchanged: true)
            return
        }
        guard !activeQueue.isEmpty else { return }
        var idx = currentIndex + 1
        if idx >= activeQueue.count {
            guard repeatMode == .all else {
                if userInitiated {
                    ToastCenter.shared.show(String(localized: "已经是最后一首了"))
                } else {
                    isPlaying = false
                    NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                }
                return
            }
            idx = 0
        }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    private func handleItemEnded() {
        scrobbleIfNeeded(completed: true)
        if repeatMode == .one, !isFMMode {
            scrobbled = false
            if hasLocalFile {
                progress = 0
                engine.play(deck: activeDeck, from: 0)
                isPlaying = true
                NowPlayingManager.shared.updateElapsed(0, rate: 1)
            } else if let track = currentTrack {
                // A drained stream can't restart in place; re-resolve (the
                // second pass usually hits the cache the first one committed).
                startPlaying(track, indexUnchanged: true)
            }
            return
        }
        advanceToNext(userInitiated: false)
    }

    // MARK: - Source resolution

    /// Void an armed hand-over, keeping the prefetched file/analysis around
    /// so the transition can be re-armed (post-seek) without re-downloading.
    private func disarmTransition() {
        engine.cancelScheduledTransition()
        transitionArmed = false
        pendingTransitionTrack = nil
    }

    private func startPlaying(_ track: Track, indexUnchanged: Bool = false) {
        // Any armed hand-over is void: this is a hard track change.
        disarmTransition()
        engine.stop(deck: activeDeck.other)
        prefetchTask?.cancel()
        prefetchedNext = nil
        currentAnalysis = nil
        isBuffering = false
        enginePaused = false

        scrobbleIfNeeded(completed: false)
        currentTrack = track
        progress = 0
        duration = track.duration
        servedQuality = nil
        unblockSource = nil
        isTrial = false
        lyrics = nil
        scrobbled = false
        isPlaying = true
        resolveGeneration += 1
        let generation = resolveGeneration

        NowPlayingManager.shared.updateMetadata(for: track, duration: track.duration)
        persistState()

        Task {
            await resolveAndLoad(track, generation: generation)
        }
        Task {
            await loadLyrics(for: track, generation: generation)
        }
    }

    private struct ResolvedSource {
        let url: URL
        let key: AudioCache.Key
        let level: String?
        let unblockSource: String?
        let isTrial: Bool
        let durationMS: Int?
    }

    /// The full URL-resolution chain (quality fallback → https upgrade →
    /// unblock rescue) plus cache-key derivation — shared by playback and
    /// prefetch so both always derive identical keys. Pure: no toasts, no
    /// state changes.
    private func resolveSource(for track: Track) async -> ResolvedSource? {
        let quality = SettingsManager.shared.audioQuality.rawValue
        var data = try? await NeteaseAPI.songURL(ids: [track.id], level: quality).first
        if data?.url == nil, quality != AudioQuality.standard.rawValue {
            data = try? await NeteaseAPI.songURL(ids: [track.id], level: AudioQuality.standard.rawValue).first
        }
        var url: URL?
        var unblock: String?
        if let urlString = data?.url {
            url = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
        }
        // NetEase refused — try third-party sources (UnblockNeteaseMusic-style).
        if url == nil || data?.freeTrialInfo != nil, SettingsManager.shared.enableUnblock {
            if let unblocked = await UnblockService.resolve(track) {
                url = unblocked.url
                unblock = unblocked.source
                data = nil
            }
        }
        guard let url else { return nil }
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension.lowercased()
        return ResolvedSource(
            url: url,
            key: AudioCache.Key(trackID: track.id, level: data?.level ?? quality,
                                source: unblock.map { "unblock:\($0)" } ?? "netease",
                                fileExtension: ext),
            level: data?.level,
            unblockSource: unblock,
            isTrial: data?.freeTrialInfo != nil,
            durationMS: data?.time)
    }

    private func resolveAndLoad(_ track: Track, generation: Int) async {
        let resolved = await resolveSource(for: track)
        guard generation == resolveGeneration else { return }

        guard let resolved else {
            consecutiveFailures += 1
            let reason = track.playability(privilege: nil,
                                           isLoggedIn: AccountStore.shared.isLoggedIn,
                                           vipType: AccountStore.shared.vipType).reason
            ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放\(reason.map { "：\($0)" } ?? "")"))
            if consecutiveFailures < 5 {
                advanceToNext(userInitiated: false)
            } else {
                isPlaying = false
            }
            return
        }

        consecutiveFailures = 0
        servedQuality = resolved.level
        unblockSource = resolved.unblockSource
        if let source = resolved.unblockSource {
            ToastCenter.shared.show(String(localized: "已使用第三方音源：\(source)"))
        }
        if resolved.isTrial {
            isTrial = true
            ToastCenter.shared.show(String(localized: "VIP 歌曲，当前为试听片段"))
        }

        let key = resolved.key
        currentCacheKey = resolved.isTrial ? nil : key
        currentRemoteURL = resolved.url

        engine.stop(deck: activeDeck)
        deckLoaded = true
        hasLocalFile = false

        if !resolved.isTrial {
            var local = await AudioCache.shared.cachedFileURL(for: key)
            if local == nil, let inflight = await AudioCache.shared.activeDownload(for: key) {
                // A prefetch of this very track is mid-flight — wait for it
                // instead of opening a second transfer of the same file.
                isBuffering = true
                local = try? await inflight.value
                isBuffering = false
            }
            guard generation == resolveGeneration else { return }
            if let local, let fileDuration = try? engine.loadFile(at: local, on: activeDeck) {
                hasLocalFile = true
                engine.play(deck: activeDeck, from: 0)
                isPlaying = true
                duration = fileDuration
                NowPlayingManager.shared.updateMetadata(for: track, duration: fileDuration)
                ensureCurrentAnalysis(key: key, fileURL: local)
                schedulePrefetch()
                return
            }
            // Unreadable cache entry — fall through to streaming.
        }
        guard generation == resolveGeneration else { return }

        let partURL: URL
        if resolved.isTrial {
            // Trial fragments never enter the cache; the mirror write goes to
            // a temp file the OS cleans up.
            partURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kumone-trial-\(track.id).part")
        } else {
            partURL = AudioCache.shared.partFileURL(for: key)
        }
        // Buffering until the first decoded chunk lands (streamResumed).
        isBuffering = true
        engine.startStreaming(from: resolved.url, formatHint: key.fileExtension,
                              writingTo: partURL, on: activeDeck)
        engine.play(deck: activeDeck, from: 0)
        isPlaying = true

        if let time = resolved.durationMS, time > 0 {
            duration = TimeInterval(time) / 1000
            NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
        }
        schedulePrefetch()
    }

    // MARK: - Engine events

    private func handleEngineEvent(_ event: PlaybackEngineEvent) {
        switch event {
        case .deckFinished(let deck):
            guard deck == activeDeck else { return }
            handleItemEnded()
        case .streamStalled(let deck):
            if deck == activeDeck { isBuffering = true }
        case .streamResumed(let deck):
            if deck == activeDeck { isBuffering = false }
        case .streamDownloadCompleted(let deck):
            guard deck == activeDeck, let key = currentCacheKey else { return }
            let generation = resolveGeneration
            Task { [weak self] in
                guard let final = try? await AudioCache.shared.commitPartFile(for: key),
                      let self, generation == self.resolveGeneration else { return }
                self.ensureCurrentAnalysis(key: key, fileURL: final)
                // The prefetch pipeline may have deferred while this track
                // was still streaming (same-track repeat) — re-run it.
                self.schedulePrefetch()
            }
        case .streamFailed(let deck, _):
            guard deck == activeDeck else { return }
            handleStreamFailure()
        case .transitionMidpoint(_, let to):
            adoptTransitionedTrack(on: to)
        case .transitionCompleted:
            transitionArmed = false
            schedulePrefetch()
        }
    }

    /// Progressive playback died (parse error, mid-file network loss, format
    /// the stream parser can't resync): download the whole file instead and
    /// resume near where it stopped.
    private func handleStreamFailure() {
        if isPlaying { isBuffering = true }
        let generation = resolveGeneration
        let resumeAt = progress
        guard let key = currentCacheKey, let remote = currentRemoteURL,
              let track = currentTrack else {
            streamFallbackFailed()
            return
        }
        Task {
            do {
                let local = try await AudioCache.shared.download(from: remote, key: key)
                guard generation == resolveGeneration else { return }
                let fileDuration = try engine.loadFile(at: local, on: activeDeck)
                hasLocalFile = true
                isBuffering = false
                duration = fileDuration
                if isPlaying {
                    engine.play(deck: activeDeck, from: min(resumeAt, max(0, fileDuration - 1)))
                } else {
                    // The user paused mid-stream: stay silent. The play
                    // button re-issues play() from `progress`.
                    enginePaused = false
                }
                NowPlayingManager.shared.updateMetadata(for: track, duration: fileDuration)
                ensureCurrentAnalysis(key: key, fileURL: local)
                schedulePrefetch()
            } catch {
                guard generation == resolveGeneration else { return }
                streamFallbackFailed()
            }
        }
    }

    private func streamFallbackFailed() {
        isBuffering = false
        consecutiveFailures += 1
        ToastCenter.shared.show(String(localized: "播放失败，已跳过"))
        if consecutiveFailures < 5 {
            advanceToNext(userInitiated: false)
        } else {
            isPlaying = false
        }
    }

    // MARK: - Auto-advance pipeline (prefetch + transitions)

    /// The track the player would advance to on its own, or nil when the
    /// hand-over must stay manual (repeat-one, trial fragment, end of queue).
    private func autoAdvanceTarget() -> Track? {
        guard !isTrial, repeatMode != .one else { return nil }
        if isFMMode { return fmUpcoming.first }
        if let next = playNextList.first { return next }
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return nil }
        let idx = currentIndex + 1
        if idx < activeQueue.count { return activeQueue[idx] }
        return repeatMode == .all ? activeQueue.first : nil
    }

    /// (Re)start the pipeline for the current auto-advance target. Call after
    /// playback starts and whenever the upcoming list changes.
    private func schedulePrefetch() {
        prefetchTask?.cancel()
        let target = autoAdvanceTarget()
        if let armed = pendingTransitionTrack {
            // Already armed for the right track — the pipeline is done.
            if armed.id == target?.id { return }
            // The armed hand-over points at a track that is no longer next.
            disarmTransition()
            engine.stop(deck: activeDeck.other)
        }
        prefetchedNext = nil
        guard let target else { return }
        if target.id == currentTrack?.id, deckLoaded, !hasLocalFile {
            // The next track IS the one still streaming into the cache
            // (single-track repeat-all). A parallel download would race the
            // .part mirror; streamDownloadCompleted re-runs this instead.
            return
        }
        let generation = resolveGeneration
        prefetchTask = Task { [weak self] in
            guard let self, let resolved = await self.resolveForPrefetch(target) else { return }
            guard !Task.isCancelled, generation == self.resolveGeneration else { return }
            guard let local = try? await AudioCache.shared.download(from: resolved.url, key: resolved.key)
            else { return }
            guard !Task.isCancelled, generation == self.resolveGeneration else { return }
            let analysis = await self.analysis(for: resolved.key, fileURL: local)
            guard !Task.isCancelled, generation == self.resolveGeneration,
                  self.autoAdvanceTarget()?.id == target.id else { return }
            self.prefetchedNext = PrefetchedNext(
                track: target, key: resolved.key, localURL: local,
                level: resolved.level, unblockSource: resolved.unblockSource, analysis: analysis)
            self.armTransitionIfReady()
        }
    }

    /// Prefetch variant of the shared resolver: trial fragments resolve to
    /// nil (they can't be cached, so they can't be armed either).
    private func resolveForPrefetch(_ track: Track) async -> ResolvedSource? {
        guard let resolved = await resolveSource(for: track), !resolved.isTrial else { return nil }
        return resolved
    }

    /// Load the prefetched track on the idle deck and pre-arm the hand-over.
    private func armTransitionIfReady() {
        guard !transitionArmed, let next = prefetchedNext else { return }
        let incoming = activeDeck.other
        guard (try? engine.loadFile(at: next.localURL, on: incoming)) != nil else {
            prefetchedNext = nil
            return
        }
        engine.scheduleTransition(makeTransitionPlan(for: next), from: activeDeck, to: incoming)
        transitionArmed = true
        pendingTransitionTrack = next.track
    }

    private func makeTransitionPlan(for next: PrefetchedNext) -> PlannedTransition {
        #if os(iOS)
        return .plain(.gapless)
        #else
        guard SettingsManager.shared.automixEnabled else { return .plain(.gapless) }
        if currentAnalysis == nil || next.analysis == nil {
            // Analyses not ready (first listen, current track still
            // streaming): a plain crossfade still beats a hard cut.
            guard duration > 45 else { return .plain(.gapless) }
            let fade: TimeInterval = 6
            return .plain(.crossfade(duration: fade,
                                     outPoint: max(duration - fade, duration * 0.6),
                                     inPoint: 0))
        }
        return TransitionPlanner.plan(outgoing: currentAnalysis, incoming: next.analysis)
        #endif
    }

    /// Whether analysis results would ever be consumed: on iOS and with
    /// AutoMix off every plan is gapless, so decoding + analyzing the whole
    /// track would be pure waste.
    private var analysisWanted: Bool {
        #if os(iOS)
        return false
        #else
        return SettingsManager.shared.automixEnabled
        #endif
    }

    /// Sidecar-cached analysis, computing (and persisting) it on a miss.
    private func analysis(for key: AudioCache.Key, fileURL: URL) async -> TrackAnalysis? {
        guard analysisWanted else { return nil }
        if let cached = await AudioCache.shared.loadAnalysis(for: key) { return cached }
        let analyzed = await Task.detached(priority: .utility) {
            try? TrackAnalyzer.analyze(fileAt: fileURL)
        }.value
        if let analyzed {
            await AudioCache.shared.storeAnalysis(analyzed, for: key)
        }
        return analyzed
    }

    /// Analyze the track now playing once its complete file exists locally
    /// (cache hit, stream commit, or fallback download).
    private func ensureCurrentAnalysis(key: AudioCache.Key, fileURL: URL) {
        guard analysisWanted else { return }
        let generation = resolveGeneration
        Task { [weak self] in
            guard let self else { return }
            let result = await self.analysis(for: key, fileURL: fileURL)
            guard generation == self.resolveGeneration, let result else { return }
            self.currentAnalysis = result
            self.replanArmedTransition()
        }
    }

    /// The outgoing analysis landed after the hand-over was armed with a
    /// degraded plan — upgrade it in place. The engine only swaps the plan
    /// while the transition is still waiting, so audible audio is never cut.
    private func replanArmedTransition() {
        guard transitionArmed, let next = prefetchedNext else { return }
        engine.replaceTransitionPlan(makeTransitionPlan(for: next))
    }

    /// The engine crossed the transition midpoint: the incoming deck is now
    /// the audible one, so the app's notion of "current track" flips here.
    private func adoptTransitionedTrack(on deck: Deck) {
        guard let next = pendingTransitionTrack else { return }
        scrobbleIfNeeded(completed: true)
        scrobbled = false
        consecutiveFailures = 0

        // Advance the queue pointers the same way advanceToNext would have.
        if isFMMode {
            if fmUpcoming.first?.id == next.id { fmUpcoming.removeFirst() }
        } else if playNextList.first?.id == next.id {
            playNextList.removeFirst()
        } else {
            // Advance sequentially like advanceToNext would; only fall back
            // to searching if the queue changed under us. A plain firstIndex
            // would jump back to an earlier copy of a duplicated track.
            var idx = currentIndex + 1
            if idx >= activeQueue.count { idx = 0 }
            if idx < activeQueue.count, activeQueue[idx].id == next.id {
                currentIndex = idx
            } else if let found = activeQueue.firstIndex(where: { $0.id == next.id }) {
                currentIndex = found
            }
        }

        currentTrack = next
        activeDeck = deck
        deckLoaded = true
        hasLocalFile = true
        isBuffering = false
        currentCacheKey = prefetchedNext?.key
        currentRemoteURL = nil
        currentAnalysis = prefetchedNext?.analysis
        servedQuality = prefetchedNext?.level
        unblockSource = prefetchedNext?.unblockSource
        isTrial = false
        isPlaying = true
        progress = engine.position(of: deck)
        duration = engine.duration(of: deck) ?? next.duration
        lyrics = nil
        pendingTransitionTrack = nil
        prefetchedNext = nil

        resolveGeneration += 1
        let generation = resolveGeneration
        NowPlayingManager.shared.updateMetadata(for: next, duration: duration)
        NowPlayingManager.shared.updateElapsed(progress, rate: 1)
        persistState()
        Task { await loadLyrics(for: next, generation: generation) }

        if isFMMode, fmUpcoming.count < 1 {
            Task {
                if let more = try? await NeteaseAPI.personalFM() {
                    fmUpcoming.append(contentsOf: more)
                    schedulePrefetch()
                }
            }
        }
    }

    private func loadLyrics(for track: Track, generation: Int) async {
        let response = try? await NeteaseAPI.lyric(id: track.id)
        guard generation == resolveGeneration else { return }
        lyrics = response.map(LyricsParser.parse)
    }

    // MARK: - Scrobble

    private func scrobbleIfNeeded(completed: Bool) {
        guard let track = currentTrack, !scrobbled, progress > 1 else { return }
        scrobbled = true
        let seconds = completed ? Int(duration) : Int(progress)
        let sourceID = source.sourceID
        Task.detached {
            await NeteaseAPI.scrobble(trackID: track.id, sourceID: sourceID, seconds: seconds)
        }
    }

    // MARK: - Shuffle helpers

    private func reshuffle(keeping first: Track) {
        var rest = queue.filter { $0.id != first.id }
        rest.shuffle()
        shuffledQueue = [first] + rest
    }

    // MARK: - Persistence

    private static let recentContextsLimit = 6

    private func recordRecent(_ context: PlayContext) {
        recentContexts.removeAll { $0 == context }
        recentContexts.insert(context, at: 0)
        if recentContexts.count > Self.recentContextsLimit {
            recentContexts.removeLast(recentContexts.count - Self.recentContextsLimit)
        }
    }

    /// Reloads a place from the recents list and starts playing it again.
    func play(context: PlayContext) {
        // Personal FM is a stream, not a fixed list — restart it in place.
        guard context.kind != .fm else { return startFM() }
        Task {
            do {
                guard let resolved = try await resolve(context) else { return }
                play(tracks: resolved.tracks, source: resolved.source, context: context)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func resolve(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
        switch context.kind {
        case .fm:
            return nil
        case .album:
            return (try await NeteaseAPI.album(id: context.id).songs, .album(context.id))
        case .artist:
            return (try await NeteaseAPI.artist(id: context.id).hotSongs, .artist(context.id))
        case .daily:
            return (try await NeteaseAPI.dailyRecommendSongs(), .daily)
        case .cloud:
            let songs = try await NeteaseAPI.cloudSongs().data?.compactMap(\.simpleSong) ?? []
            return (songs, .cloud)
        case .recents:
            guard let uid = AccountStore.shared.profile?.userId else { return nil }
            return (try await NeteaseAPI.playRecords(uid: uid, week: false).map(\.song), .none)
        case .heartbeat:
            // Regenerated from a fresh seed, the same way the Home card does it.
            guard let liked = AccountStore.shared.likedSongsPlaylist,
                  let seed = AccountStore.shared.likedTrackIDs.randomElement() else { return nil }
            let tracks = try await NeteaseAPI.intelligenceList(songID: seed, playlistID: liked.id)
            return (tracks, .playlist(liked.id))
        case .playlist:
            let response = try await NeteaseAPI.playlistDetail(id: context.id)
            var tracks = response.playlist.tracks
            // /v6/playlist/detail only carries the first page of tracks.
            let remaining = response.playlist.trackIds.map(\.id).dropFirst(tracks.count)
            for chunk in stride(from: 0, to: remaining.count, by: 500)
                .map({ Array(remaining.dropFirst($0).prefix(500)) }) {
                guard let more = try? await NeteaseAPI.songDetails(ids: chunk) else { break }
                tracks += more.songs
            }
            return (tracks, .playlist(context.id))
        }
    }

    private struct PersistedState: Codable {
        var queue: [Track]
        var currentID: Int?
        var repeatMode: String
        var shuffle: Bool
        /// Optional so state files written before recents existed still decode.
        var recentContexts: [PlayContext]?
    }

    private func persistState() {
        let state = PersistedState(
            queue: Array(queue.prefix(1000)),
            currentID: currentTrack?.id,
            repeatMode: repeatMode.rawValue,
            shuffle: shuffleEnabled,
            recentContexts: recentContexts
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = Self.stateFileURL
        Task.detached {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func restoreState() {
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        // Recents outlive the queue: restore them before bailing out on an
        // empty queue, or the next played track persists an empty list over
        // them and the Dock menu loses its history for good.
        recentContexts = Array((state.recentContexts ?? []).prefix(Self.recentContextsLimit))
        guard !state.queue.isEmpty else { return }
        queue = state.queue
        shuffleEnabled = state.shuffle
        if shuffleEnabled {
            shuffledQueue = queue.shuffled()
        }
        if let id = state.currentID,
           let idx = activeQueue.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
            currentTrack = activeQueue[idx]
            duration = activeQueue[idx].duration
            NowPlayingManager.shared.updateMetadata(for: activeQueue[idx], duration: duration)
            Task {
                await loadLyrics(for: activeQueue[idx], generation: resolveGeneration)
            }
        }
    }

    private static var stateFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("player-state.json")
    }
}
