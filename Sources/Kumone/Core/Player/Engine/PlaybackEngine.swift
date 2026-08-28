import AVFoundation
import Foundation

enum PlaybackEngineEvent: Sendable {
    /// Deck 播完了所有已调度音频（自然结束，非 stop/seek 引起）。
    case deckFinished(Deck)
    /// 过渡中点已过（crossfade 中点 / beatMatched 的 bass swap 点）——
    /// PlayerService 以此为界切换 currentTrack/歌词/scrobble。
    case transitionMidpoint(from: Deck, to: Deck)
    /// 过渡完成，出曲 deck 已停止并复位。
    case transitionCompleted(from: Deck, to: Deck)
    case streamStalled(Deck)      // 渐进流 underrun，正在缓冲
    case streamResumed(Deck)
    case streamFailed(Deck, Error)
    /// 渐进流全部字节已落盘（.part 写完），调用方可 commit 缓存。
    case streamDownloadCompleted(Deck)
}

/// Dual-deck AVAudioEngine playback engine (spec §2).
///
/// Graph, per deck:
///   AVAudioPlayerNode → AVAudioUnitTimePitch → AVAudioUnitEQ (low shelf +
///   parametric mid + high shelf + a high-pass band) → AVAudioUnitDelay →
///   mainMixerNode
///
/// Every effect node is attached and wired at init with neutral parameters
/// (all EQ gains 0, the high-pass band bypassed, the delay 100% dry), because
/// reconnecting the graph while the other deck renders throws an NSException.
/// `TransitionStyle` is executed purely by moving those parameters.
///
/// The user-facing volume lives on `mainMixerNode.outputVolume`; transition
/// fades use each deck's `playerNode.volume`.
///
/// Concurrency invariants (`@unchecked Sendable`):
/// - Every piece of mutable state — deck state, the audio graph, transition
///   bookkeeping, the loaders — is only touched on `queue`, a private serial
///   DispatchQueue. Public methods hop onto it (`sync` for getters, `async`
///   for commands) and never call out to the caller while on it.
/// - AVAudioPlayerNode completion handlers re-enter through `queue.async`.
///   ProgressiveLoader does its network/decode work on its own queue and
///   delivers results onto `queue` — decode bursts never occupy this queue,
///   which the main thread queries synchronously.
/// - `events` is a single-consumer AsyncStream; the continuation is only
///   yielded to from `queue`.
/// - `queue` never blocks on the main thread, so `queue.sync` from
///   @MainActor callers (PlayerService) cannot deadlock.
final class PlaybackEngine: @unchecked Sendable {

    let events: AsyncStream<PlaybackEngineEvent>

    var outputVolume: Float {
        get { queue.sync { engine.mainMixerNode.outputVolume } }
        set { queue.async { self.engine.mainMixerNode.outputVolume = newValue } }
    }

    // MARK: - Private state (all confined to `queue`)

    private let queue = DispatchQueue(label: "app.kumone.playback-engine")
    private let engine = AVAudioEngine()
    private let eventContinuation: AsyncStream<PlaybackEngineEvent>.Continuation

    /// The one format every deck chain is wired with, fixed at init.
    /// Reconnecting a running engine's graph (to adopt a per-file format)
    /// throws NSException while the other deck renders — so the graph never
    /// changes; sources that don't match are converted into it instead
    /// (ProgressiveLoader for streams, FileFeeder for local files).
    private let graphFormat = DeckChain.format

    /// Everything one deck needs: nodes, source, clock offsets, stream flags.
    private final class DeckState {
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        /// Band layout — fixed at init, see `EQBand`.
        let eq = AVAudioUnitEQ(numberOfBands: DeckChain.bandCount)
        /// Tail effect for `.echoOut`; 100% dry (transparent) at rest.
        let delay = AVAudioUnitDelay()

        enum Source {
            case none
            /// Format matches the graph: sample-accurate scheduleSegment.
            case file(AVAudioFile)
            /// Local file in a different format, converted in chunks.
            case convertedFile(FileFeeder)
            case stream(ProgressiveLoader)
        }

        var source: Source = .none
        var format: AVAudioFormat?
        var isConnected = false
        /// Media time (seconds) of player sample 0 for the current schedule;
        /// position = startOffset + playerTime. Reset by every (re)schedule.
        var startOffset: TimeInterval = 0
        /// Last position we could compute; the fallback when the node clock
        /// is unavailable (paused engine, configuration change).
        var lastKnownPosition: TimeInterval = 0
        /// Bumped by every stop/seek/reload. Completion handlers capture the
        /// generation they were scheduled under; stale ones are ignored —
        /// AVAudioPlayerNode fires completions on stop() too, and this is how
        /// natural end is told apart from interruption.
        var generation = 0
        /// Logical intent: the deck should be sounding (modulo global pause).
        var isPlaying = false
        /// Non-nil while a re-schedule (seek) flush window is open: the fader
        /// level to hand back once the stale audio still inside the effect
        /// chain has been pushed out. See `beginFaderFlushLocked`.
        var pendingFaderRestore: Float?
        /// Per-track loudness compensation, as a **linear multiplier on every
        /// fader write** (`setFaderLocked`). 1 = unity, and every path is then
        /// bit-identical to the player before compensation existed.
        ///
        /// It is a property of the material on the deck, set once when the deck
        /// is loaded and never touched again while that track plays: a trim
        /// that moved mid-song would be a level jump, which is the very thing
        /// it exists to remove. It multiplies the transition automation's 0–1
        /// curves rather than replacing them, so curve semantics are untouched;
        /// and it lives below the user's volume (`mainMixerNode.outputVolume`),
        /// which it never reads or writes.
        var trim: Float = 1

        /// The last level a caller asked this deck's fader for, in 0–1 fader
        /// terms — i.e. `setFaderLocked`'s argument, before `trim` and `ride`.
        /// Remembered so a *gain* change can be re-applied without a caller:
        /// the ride glide re-writes the fader between automation ticks, and
        /// the only correct thing to re-write is whatever the last curve (or
        /// transport call) asked for.
        var faderRequest: Float = 1

        /// Transition gain ride: the **second** time-varying multiplier on
        /// every fader write, stacked on `trim` (`PlaybackEngine.rideDB` /
        /// `TransitionPlanner.rideDB`). 1 = unity, and every path is then
        /// bit-identical to the player before the ride existed.
        ///
        /// Unlike `trim` — a property of the material, fixed for as long as
        /// the track plays — this is a property of the *hand-over*: it is set
        /// on the incoming deck when its overlap begins (where the fader is at
        /// 0, so introducing it is inaudible by construction), held for the
        /// whole overlap, and then released back to unity at
        /// `TransitionAutomation.rideReleaseDBPerSecond` while the deck is the
        /// only thing playing.
        var ride: Float = 1
        /// The ride in dB, and where it is heading. Equal = settled.
        var rideDB: Double = 0
        var rideTargetDB: Double = 0
        /// The ride the release started from, and how far into the release we
        /// are — so the glide is `TransitionAutomation.rideDB`, the very
        /// function the offline renderer steps, rather than an accumulator
        /// that could drift from it.
        var rideReleaseFromDB: Double = 0
        var rideReleaseElapsed: TimeInterval = 0

        // Progressive-stream bookkeeping.
        var pendingStreamBuffers = 0
        var streamStalled = false
        var streamEnded = false

        func band(_ band: EQBand) -> AVAudioUnitEQFilterParameters {
            eq.bands[band.rawValue]
        }
    }

    /// Fixed band assignment of every deck's 4-band EQ; see `DeckChain`, which
    /// the offline `audition` renderer builds its decks from too.
    private typealias EQBand = DeckChain.Band

    private let deckStates: [Deck: DeckState]

    private var isPaused = false
    private var sessionConfigured = false

    // Stream backpressure: pause the download when this many ~0.5s buffers
    // are scheduled but unplayed, resume below the low mark.
    private let streamHighWater = 40  // ≈ 20s of decoded PCM
    private let streamLowWater = 10

    // The transition's parameter curves — and the constants that shape them —
    // live in `TransitionAutomation`, so the offline `audition` renderer drives
    // an identical node graph from exactly the same numbers. Only the values
    // this file still needs outside the overlap tick are aliased here.
    private static let bassCutDB = TransitionAutomation.bassCutDB
    private static let midCutDB = TransitionAutomation.midCutDB
    private static let highCutDB = TransitionAutomation.highCutDB
    private static let sweepStartHz = TransitionAutomation.sweepStartHz
    private static let echoDefaultDelayTime = TransitionAutomation.echoDefaultDelayTime

    /// How much *new* audio the player node has to emit before a re-scheduled
    /// (seeked) deck may be heard again — i.e. the depth of the effect chain
    /// downstream of the player. `AVAudioPlayerNode.stop()` does not empty
    /// timePitch/EQ/delay, so without this window a seek leaks ~200 ms of the
    /// old position at full level. Measured on this graph; counted on the
    /// player's own clock rather than wall time, so it survives a pause (a
    /// stopped engine renders nothing, and the stale audio is still in there).
    private static let faderFlushDuration: TimeInterval = 0.25
    /// Tick of the flush-window watcher; only runs while a window is open.
    private static let faderFlushTick: TimeInterval = 0.01

    /// A transition may only fire when the outgoing track *plays into* its out
    /// point, so a plan counts as reachable while the playhead is still short
    /// of it. This slack only absorbs "effectively on top of it" (clock jitter,
    /// one render buffer): it must stay small, because arming a plan a fraction
    /// of a second before its out point is perfectly legitimate — the prefetch
    /// can land late. See `resolvePlanLocked`.
    private static let transitionArrivalGuard: TimeInterval = 0.05
    /// Longest crossfade a degraded plan falls back to.
    private static let fallbackCrossfadeDuration: TimeInterval = 4
    /// Slack the fallback crossfade needs beyond its own length; below this
    /// the fallback is `.gapless` instead.
    private static let fallbackCrossfadeHeadroom: TimeInterval = 3

    // MARK: - Transition state

    private enum TransitionPhase {
        case waiting        // watching the from deck approach the out point
        case armed          // gapless: incoming play(at:) is scheduled
        case overlapping    // crossfade/beatMatched ramp in progress
        /// After the overlap: ramp a beat-matched rate back to 1.0 and/or let
        /// an `.echoOut` tail ring out before the decks go neutral.
        case settling
    }

    private final class TransitionState {
        let plan: TransitionPlan
        let style: TransitionStyle
        /// Gain ride for the incoming deck; see `PlannedTransition.rideDB`.
        let rideDB: Double
        let from: Deck
        let to: Deck
        var phase: TransitionPhase = .waiting
        /// Time spent inside the overlap; advanced per tick and frozen while
        /// paused, so a pause mid-transition does not fast-forward the ramps.
        var elapsed: TimeInterval = 0
        var restoreElapsed: TimeInterval = 0
        var midpointSent = false
        /// `.echoOut`: the delay has been thrown and the outgoing deck is
        /// being cut; set once, at `echoStopOffset`.
        var echoThrown = false
        /// `.echoOut`: the overlap ended with a tail still ringing, which the
        /// settling phase decays.
        var echoTailRinging = false
        var restoringRate = false

        /// Timing landmarks of the plan (overlap length, swap point, echo stop
        /// point); computed once, shared with the offline renderer.
        let geometry: TransitionAutomation.Geometry

        init(plan: TransitionPlan, style: TransitionStyle, rideDB: Double = 0,
             from: Deck, to: Deck) {
            self.plan = plan
            self.style = style
            self.rideDB = rideDB
            self.from = from
            self.to = to
            self.geometry = TransitionAutomation.Geometry(plan: plan)
        }

        var overlapDuration: TimeInterval { geometry.overlapDuration }
        /// Seconds into the overlap where the low end changes decks — the
        /// staged hand-over's last stage, and the audible midpoint.
        var swapOffset: TimeInterval { geometry.swapOffset }
    }

    private var transition: TransitionState?
    private var transitionTimer: DispatchSourceTimer?
    /// Fast tick for ramps; the slow tick carries the (possibly minutes-long)
    /// wait for the out point without burning 50 wakeups a second.
    private let tickInterval: TimeInterval = 1.0 / 50.0
    private let slowTickInterval: TimeInterval = 0.25
    private var transitionTimerInterval: TimeInterval = 0

    private var clockTimer: DispatchSourceTimer?
    private var faderFlushTimer: DispatchSourceTimer?
    /// Deck-level gain glide: the transition ride's release. Independent of
    /// the transition timer on purpose — the release outlives the transition.
    private var rideTimer: DispatchSourceTimer?
    private var configObserver: NSObjectProtocol?

    // MARK: - Init

    init() {
        var continuation: AsyncStream<PlaybackEngineEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation

        var states: [Deck: DeckState] = [:]
        for deck in [Deck.a, .b] {
            let state = DeckState()
            DeckChain.configureBands(state.eq)
            DeckChain.configureDelay(state.delay)

            engine.attach(state.player)
            engine.attach(state.timePitch)
            engine.attach(state.eq)
            engine.attach(state.delay)
            states[deck] = state
        }
        deckStates = states

        // Touch the mixer so it is wired to the output before first start.
        engine.mainMixerNode.outputVolume = 1

        // Wire both chains once, before the engine ever starts — the graph
        // is immutable from here on (see graphFormat).
        for state in deckStates.values {
            connectChainLocked(state, format: graphFormat)
        }

        // Output device / route changes stop the engine and wipe every player
        // node's schedule — on macOS this fires when switching audio devices,
        // on iOS on route changes. Rebuild and resume from the cached
        // positions, or playback dies the moment headphones are plugged in.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleConfigurationChange() }
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        transitionTimer?.cancel()
        clockTimer?.cancel()
        faderFlushTimer?.cancel()
        rideTimer?.cancel()
        eventContinuation.finish()
    }

    // MARK: - Loading

    /// Load a complete local file (cache-hit path); returns its duration.
    /// Does not start playback.
    ///
    /// `trimDB` is this track's loudness compensation (`LoudnessCompensation`),
    /// taken here rather than through a setter so it is fixed for the whole
    /// time the track is on the deck: an analysis that lands mid-song cannot
    /// move it, and the next load is the earliest it can change.
    func loadFile(at url: URL, on deck: Deck, trimDB: Double = 0) throws -> TimeInterval {
        try queue.sync {
            let file = try AVAudioFile(forReading: url)
            let state = deckStates[deck]!
            // Re-loading a deck invalidates any plan that involves it: the
            // plan's timeline belongs to the material being replaced. Cancel
            // before the reset, so the cancel's own knob writes land first and
            // the reset has the last word on this deck.
            invalidateTransitionLocked(touching: deck)
            resetDeckLocked(state)
            state.trim = LoudnessCompensation.gain(fromDB: trimDB)
            let fileFormat = file.processingFormat
            if fileFormat.sampleRate == graphFormat.sampleRate,
               fileFormat.channelCount == graphFormat.channelCount {
                state.source = .file(file)
            } else {
                // Hi-Res / mono: convert in chunks instead of reconnecting
                // the graph (which would throw while the other deck renders).
                let feeder = FileFeeder(file: file, output: graphFormat, queue: queue)
                state.source = .convertedFile(feeder)
                wireFeederLocked(feeder, deck: deck)
            }
            state.format = graphFormat
            return Double(file.length) / fileFormat.sampleRate
        }
    }

    /// Hook a feeder's chunk delivery into the deck's buffer bookkeeping —
    /// the same path streamed audio uses.
    private func wireFeederLocked(_ feeder: FileFeeder, deck: Deck) {
        feeder.onBuffer = { [weak self, weak feeder] buffer in
            guard let self, let feeder,
                  let state = self.deckStates[deck],
                  case .convertedFile(let current) = state.source, current === feeder else { return }
            state.pendingStreamBuffers += 1
            let generation = state.generation
            state.player.scheduleBuffer(buffer, at: nil, options: [],
                                        completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    feeder.bufferPlayed()
                    self.streamBufferPlayedLocked(deck: deck, generation: generation)
                }
            }
            self.startNodeIfNeededLocked(state)
        }
        feeder.onEnded = { [weak self, weak feeder] in
            guard let self, let feeder,
                  let state = self.deckStates[deck],
                  case .convertedFile(let current) = state.source, current === feeder else { return }
            state.streamEnded = true
            if state.pendingStreamBuffers <= 0, state.isPlaying {
                self.handleDeckDrainedLocked(deck, generation: state.generation)
            }
        }
    }

    /// Progressive streaming: play while downloading, mirroring raw bytes
    /// into `partURL`. `formatHint` is the file extension ("mp3"/"flac"/"m4a")
    /// used as the AudioFileStream type hint.
    ///
    /// `trimDB` is 0 in practice: a track being streamed for the first time has
    /// no analysis yet, so it has no measured loudness to compensate. The
    /// parameter exists so the stream path cannot silently diverge from the
    /// file path if that ever changes.
    func startStreaming(from remote: URL, formatHint: String?, writingTo partURL: URL,
                        on deck: Deck, trimDB: Double = 0) {
        queue.async {
            let state = self.deckStates[deck]!
            self.invalidateTransitionLocked(touching: deck)
            self.resetDeckLocked(state)
            state.trim = LoudnessCompensation.gain(fromDB: trimDB)
            let loader = ProgressiveLoader(remoteURL: remote, formatHint: formatHint,
                                           partURL: partURL, output: self.graphFormat,
                                           queue: self.queue)
            state.source = .stream(loader)
            // Start in the stalled state so the first scheduled buffer emits
            // streamResumed — that's the caller's "initial buffering done".
            state.streamStalled = true

            // All loader callbacks arrive on `queue`; each one re-checks that
            // this loader is still the deck's source before touching it.
            loader.onFormat = { [weak self, weak loader] format in
                guard let self, let loader,
                      let state = self.deckStates[deck],
                      case .stream(let current) = state.source, current === loader else { return }
                // The loader converts into the fixed graph format; the graph
                // itself never reconfigures.
                state.format = format
                self.startNodeIfNeededLocked(state)
            }
            loader.onBuffer = { [weak self, weak loader] buffer in
                guard let self, let loader else { return }
                self.scheduleStreamBufferLocked(deck: deck, loader: loader, buffer: buffer)
            }
            loader.onCompleted = { [weak self, weak loader] cacheCommitted in
                guard let self, let loader,
                      let state = self.deckStates[deck],
                      case .stream(let current) = state.source, current === loader else { return }
                state.streamEnded = true
                if cacheCommitted {
                    self.eventContinuation.yield(.streamDownloadCompleted(deck))
                }
                // The stream may already be drained (stalled at the tail).
                if state.pendingStreamBuffers <= 0, state.isPlaying {
                    state.streamStalled = false
                    self.handleDeckDrainedLocked(deck, generation: state.generation)
                }
            }
            loader.onError = { [weak self, weak loader] error in
                guard let self, let loader,
                      let state = self.deckStates[deck],
                      case .stream(let current) = state.source, current === loader else { return }
                self.eventContinuation.yield(.streamFailed(deck, error))
            }
            loader.start()
        }
    }

    // MARK: - Transport

    func play(deck: Deck, from seconds: TimeInterval) {
        queue.async {
            let state = self.deckStates[deck]!
            self.isPaused = false
            // This deck is being handed a track to carry. Decks are reused as
            // they are found, so unless a live transition owns its knobs
            // (its ramps rewrite them every tick), start from a transparent
            // chain — a band left ducked by a hand-over that ended some other
            // way would colour everything played here from now on.
            if !self.deckIsInLiveTransitionLocked(deck) {
                self.neutralizeEffectsLocked(state)
            }
            // A deck parked by resetDeckLocked is silent at the mixer; this is
            // the explicit "make this deck sound" entry point, so it is here
            // that the fader comes back up (see resetDeckLocked). Routed
            // through setFaderLocked so a seek's flush window still holds the
            // mute until the chain has drained.
            // Re-aiming the playhead ends any hand-over the ride was unwinding
            // from; settle it here, before the fader is written, so this deck
            // comes back at one definite level. See `settleRideLocked`.
            self.settleRideLocked(state)
            self.setFaderLocked(state, 1)
            self.ensureEngineRunningLocked()
            switch state.source {
            case .none:
                break
            case .file(let file):
                state.isPlaying = true
                self.scheduleSegmentLocked(state, file: file, from: seconds, deck: deck)
                self.startNodeIfNeededLocked(state)
            case .convertedFile(let feeder):
                state.isPlaying = true
                self.seekFeederLocked(state, feeder: feeder, to: seconds)
                self.startNodeIfNeededLocked(state)
            case .stream(let loader):
                state.isPlaying = true
                if seconds > 0.25, abs(seconds - self.livePositionLocked(state)) > 0.5, loader.canSeek {
                    self.seekStreamLocked(state, deck: deck, to: seconds)
                }
                self.startNodeIfNeededLocked(state)
            }
            self.revalidateTransitionAfterSeekLocked(deck)
        }
    }

    /// Global pause: `engine.pause()`, keeping every schedule intact.
    func pause() {
        queue.async {
            guard !self.isPaused else { return }
            // Snapshot positions first — the node clocks freeze with the engine.
            for state in self.deckStates.values where state.isPlaying {
                state.lastKnownPosition = self.livePositionLocked(state)
            }
            // A gapless hand-over armed via play(at:) fires on the host
            // clock, which keeps running while paused — the incoming track
            // would blast in the moment playback resumes. Disarm; the wait
            // tick re-arms after resume.
            self.disarmGaplessLocked()
            // An echo tail cannot decay while the engine is stopped, and a
            // frozen wet delay would blare back on resume — end it now.
            if let tr = self.transition, tr.phase == .settling, tr.echoTailRinging {
                tr.echoTailRinging = false
                self.silenceDeckLocked(self.deckStates[tr.from]!)
            }
            // A gain ride cannot glide while nothing renders, and resuming
            // into a half-released one would just make the drift longer than
            // it was designed to be. Settle it while the engine is silent —
            // a ride still inside its overlap is at its target already, so a
            // pause mid-crossfade moves nothing.
            for state in self.deckStates.values { self.settleRideLocked(state) }
            self.isPaused = true
            self.engine.pause()
        }
    }

    func resume() {
        queue.async {
            guard self.isPaused else { return }
            self.isPaused = false
            self.ensureEngineRunningLocked()
            for state in self.deckStates.values where state.isPlaying {
                self.startNodeIfNeededLocked(state)
            }
        }
    }

    /// File decks seek sample-accurately. Stream decks restart the transfer
    /// from a CBR byte estimate; if the stream cannot seek yet (bitrate still
    /// unknown), the request is ignored — see ProgressiveLoader.seek.
    func seek(deck: Deck, to seconds: TimeInterval) {
        queue.async {
            let state = self.deckStates[deck]!
            // The seek's flush window mutes this deck while the chain drains,
            // so settling the ride now is inaudible — and the level it comes
            // back at is the one the new position deserves.
            self.settleRideLocked(state)
            switch state.source {
            case .none:
                break
            case .file(let file):
                self.scheduleSegmentLocked(state, file: file, from: seconds, deck: deck)
                self.startNodeIfNeededLocked(state)
            case .convertedFile(let feeder):
                self.seekFeederLocked(state, feeder: feeder, to: seconds)
                self.startNodeIfNeededLocked(state)
            case .stream(let loader):
                guard loader.canSeek else { return }
                self.seekStreamLocked(state, deck: deck, to: seconds)
                self.startNodeIfNeededLocked(state)
            }
            // The playhead moved: a pending hand-over must be re-derived from
            // the new position rather than fired because the seek landed on
            // top of its out point.
            self.revalidateTransitionAfterSeekLocked(deck)
        }
    }

    func position(of deck: Deck) -> TimeInterval {
        queue.sync { livePositionLocked(deckStates[deck]!) }
    }

    func duration(of deck: Deck) -> TimeInterval? {
        queue.sync { durationLocked(deckStates[deck]!) }
    }

    /// Stop and fully reset the deck (volume, rate, EQ back to neutral).
    func stop(deck: Deck) {
        queue.async {
            if let tr = self.transition, tr.from == deck || tr.to == deck {
                self.cancelTransitionLocked()
            }
            self.resetDeckLocked(self.deckStates[deck]!)
        }
    }

    func stopAll() {
        queue.async {
            self.cancelTransitionLocked()
            for state in self.deckStates.values {
                self.resetDeckLocked(state)
            }
            // Keep the engine running (cheap, and restart is not free).
        }
    }

    // MARK: - Transitions

    /// Pre-arm a transition: the `to` deck must already be loaded via
    /// `loadFile`. The engine watches the `from` deck and, at the plan's out
    /// point, starts the `to` deck and runs the volume/rate/EQ ramps,
    /// emitting `transitionMidpoint` / `transitionCompleted` along the way.
    /// A `.gapless` plan starts the incoming deck at the exact moment the
    /// outgoing one ends.
    func scheduleTransition(_ planned: PlannedTransition, from: Deck, to: Deck) {
        queue.async {
            self.cancelTransitionLocked()
            guard from != to else { return }
            // A plan whose out point the playhead has already passed (the
            // caller re-armed right after a seek) is degraded here, never
            // fired on the spot — see resolvePlanLocked.
            let resolved = self.resolvePlanLocked(planned, from: self.deckStates[from]!)
            self.transition = TransitionState(plan: resolved.plan, style: resolved.style,
                                              rideDB: resolved.rideDB, from: from, to: to)
            self.startTransitionTimerLocked(interval: self.slowTickInterval)
        }
    }

    /// Snapshot of one deck's fader + effect parameters. Test hook: the only
    /// way to assert that a transition left the reused deck neutral.
    struct DeckEffectSnapshot: Sendable, Equatable {
        /// `player.volume` as written — i.e. the fader level already scaled by
        /// `trim`, which is what actually reaches the mixer.
        var volume: Float
        /// The deck's loudness-compensation multiplier; 1 = no compensation.
        var trim: Float = 1
        /// The transition gain ride currently on this deck, in dB, and the
        /// value it is gliding towards (equal = settled). 0/0 = no ride.
        var rideDB: Double = 0
        var rideTargetDB: Double = 0
        var rate: Float
        var eqGlobalGain: Float = 0
        var lowGain: Float
        var midGain: Float
        var highGain: Float
        var highPassBypassed: Bool
        var highPassFrequency: Float
        var delayWetDryMix: Float
        var delayFeedback: Float

        /// Every effect transparent — the fader is judged separately, because
        /// a spent deck is parked silent while a live one sits at 1.
        var effectsAreNeutral: Bool {
            abs(rate - 1) < 0.001 && abs(eqGlobalGain) < 0.001
                && abs(lowGain) < 0.001 && abs(midGain) < 0.001 && abs(highGain) < 0.001
                && highPassBypassed
                && abs(delayWetDryMix) < 0.001 && abs(delayFeedback) < 0.001
        }

        /// The pose of a deck that is carrying (or about to carry) a track:
        /// transparent chain, fader open.
        /// "Fader fully open" means the deck's own gains, not literally 1 — a
        /// compensated deck at full fade sits at its trim by construction, and
        /// one still unwinding a hand-over's gain ride sits at trim × ride.
        var isNeutral: Bool {
            effectsAreNeutral
                && abs(volume - trim * LoudnessCompensation.gain(fromDB: rideDB)) < 0.001
        }

        /// The pose `resetDeckLocked` parks a spent deck in: transparent chain
        /// *and* silent, so nothing still draining out of the chain can be
        /// heard. `play(deck:from:)` reopens the fader.
        var isParked: Bool { effectsAreNeutral && abs(volume) < 0.001 }
    }

    func effectSnapshot(of deck: Deck) -> DeckEffectSnapshot {
        queue.sync {
            let state = deckStates[deck]!
            return DeckEffectSnapshot(
                volume: state.player.volume,
                trim: state.trim,
                rideDB: state.rideDB,
                rideTargetDB: state.rideTargetDB,
                rate: state.timePitch.rate,
                eqGlobalGain: state.eq.globalGain,
                lowGain: state.band(.low).gain,
                midGain: state.band(.mid).gain,
                highGain: state.band(.high).gain,
                highPassBypassed: state.band(.highPass).bypass,
                highPassFrequency: state.band(.highPass).frequency,
                delayWetDryMix: state.delay.wetDryMix,
                delayFeedback: state.delay.feedback
            )
        }
    }

    /// Test hook: whether any transition is still scheduled or running.
    var hasPendingTransition: Bool { queue.sync { transition != nil } }

    /// Test hook: report the peak magnitude one deck contributes to the mixer,
    /// once per render buffer.
    ///
    /// The tap sits on the last node of the deck's chain (the delay), which is
    /// everything *except* the fader: `player.volume` is an `AVAudioMixing`
    /// property applied at the mixer's input bus, downstream of this point, so
    /// it is folded in by hand here. Installing a tap does not reconfigure the
    /// graph, so this is safe while the engine runs. Pass nil to remove.
    func setOutputMonitor(on deck: Deck, _ block: (@Sendable (Float) -> Void)?) {
        queue.sync {
            let state = deckStates[deck]!
            state.delay.removeTap(onBus: 0)
            guard let block else { return }
            let player = state.player
            state.delay.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                var peak: Float = 0
                if let data = buffer.floatChannelData {
                    for channel in 0..<Int(buffer.format.channelCount) {
                        let samples = data[channel]
                        for frame in 0..<Int(buffer.frameLength) {
                            peak = max(peak, abs(samples[frame]))
                        }
                    }
                }
                block(peak * player.volume)
            }
        }
    }

    /// Call on seek / manual track change.
    func cancelScheduledTransition() {
        queue.async { self.cancelTransitionLocked() }
    }

    /// Swap the plan of a scheduled transition that has not started yet
    /// (phase .waiting). No-op once the hand-over is armed or overlapping,
    /// so a late re-plan can never cut audio that is already sounding.
    func replaceTransitionPlan(_ planned: PlannedTransition) {
        queue.async {
            guard let tr = self.transition, tr.phase == .waiting else { return }
            let resolved = self.resolvePlanLocked(planned, from: self.deckStates[tr.from]!)
            self.transition = TransitionState(plan: resolved.plan, style: resolved.style,
                                              from: tr.from, to: tr.to)
        }
    }

    // MARK: - Engine lifecycle (locked)

    private func ensureEngineRunningLocked() {
        guard !engine.isRunning else { return }
        #if os(iOS)
        if !sessionConfigured {
            sessionConfigured = true
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        #endif
        engine.prepare()
        do {
            try engine.start()
            startClockTimerLocked()
        } catch {
            // Surface as a stream failure on whichever deck wanted to play.
            for (deck, state) in deckStates where state.isPlaying {
                eventContinuation.yield(.streamFailed(deck, error))
            }
        }
    }

    private func connectChainLocked(_ state: DeckState, format: AVAudioFormat) {
        engine.connect(state.player, to: state.timePitch, format: format)
        engine.connect(state.timePitch, to: state.eq, format: format)
        engine.connect(state.eq, to: state.delay, format: format)
        engine.connect(state.delay, to: engine.mainMixerNode, format: format)
        state.isConnected = true
    }

    private func startNodeIfNeededLocked(_ state: DeckState) {
        guard state.isPlaying, !isPaused, state.isConnected, engine.isRunning else { return }
        if !state.player.isPlaying { state.player.play() }
    }

    /// Every effect parameter back to transparent. The single place that
    /// knows the neutral pose of a deck's chain — every transition exit path
    /// (completed / cancelled / interrupted) must reach it, because decks are
    /// reused and a stuck high-pass or delay would poison the next track.
    ///
    /// Deliberately does NOT touch the fader: raising a deck's gain while its
    /// chain may still be sounding is what `resetDeckLocked` exists to avoid.
    private func neutralizeEffectsLocked(_ state: DeckState) {
        DeckChain.neutralize(timePitch: state.timePitch, eq: state.eq, delay: state.delay)
    }

    // MARK: - Fader (locked)

    /// The single writer for a deck's fader on every "make this deck sound at
    /// level X" path. While a seek flush window is open the deck must stay
    /// silent, so the requested level is only remembered — `faderFlushTick`
    /// applies it once the stale audio has drained out of the chain.
    ///
    /// The hard-silence paths (`resetDeckLocked`, `silenceDeckLocked`, the
    /// cancel paths) deliberately bypass this and write 0 directly: a deck
    /// that is being taken out of service must go quiet *now*.
    ///
    /// Every requested level is scaled by the deck's two gain multipliers —
    /// the loudness-compensation `trim` and the transition `ride` — here, and
    /// only here. Callers keep speaking in 0–1 fader terms
    /// (`TransitionAutomation` included) and never see either gain.
    private func setFaderLocked(_ state: DeckState, _ value: Float) {
        state.faderRequest = value
        let level = value * state.trim * state.ride
        if state.pendingFaderRestore != nil {
            state.pendingFaderRestore = level
        } else {
            state.player.volume = level
        }
    }

    /// Close any open flush window and drop the fader to 0 immediately.
    /// The *request* goes to 0 too: a deck taken out of service must not be
    /// resurrected by the ride glide re-applying a stale level.
    private func hardSilenceFaderLocked(_ state: DeckState) {
        state.pendingFaderRestore = nil
        state.faderRequest = 0
        state.player.volume = 0
    }

    // MARK: - Transition gain ride (locked)

    /// Tick of the ride glide. Deliberately slow: at 0.3 dB/s a 20 Hz glide
    /// moves 0.015 dB a step, which is three orders of magnitude under
    /// audibility, and the release can run for 13 s — this is not something to
    /// burn the 50 Hz ramp tick on.
    private static let rideTick: TimeInterval = 0.05

    /// Put the deck's ride at `db` **now**, with no glide, and re-write the
    /// fader through it.
    private func setRideLocked(_ state: DeckState, db: Double) {
        state.rideDB = db
        state.rideTargetDB = db
        state.rideReleaseFromDB = db
        state.rideReleaseElapsed = 0
        state.ride = LoudnessCompensation.gain(fromDB: db)
        setFaderLocked(state, state.faderRequest)
    }

    /// Clear the ride bookkeeping without touching the fader — for a deck
    /// being taken out of service, where the fader is separately silenced (or,
    /// for an echo tail, deliberately left exactly where the overlap left it).
    /// Mirrors how `trim` is reset in `resetDeckLocked`.
    private func clearRideStateLocked(_ state: DeckState) {
        state.rideDB = 0
        state.rideTargetDB = 0
        state.rideReleaseFromDB = 0
        state.rideReleaseElapsed = 0
        state.ride = 1
    }

    /// Start letting go of the deck's ride: unity is the target, reached at
    /// `TransitionAutomation.rideReleaseDBPerSecond`.
    ///
    /// This deliberately lives on the deck rather than in the transition's
    /// settling phase. The release runs for up to 13 s — an order of magnitude
    /// longer than a rate restore or an echo tail — and holding the transition
    /// state machine open for it would delay every cleanup that keys off
    /// `transition == nil`. By the time it finishes the hand-over is long over
    /// and this deck simply *is* the current track.
    private func releaseRideLocked(_ state: DeckState) {
        guard abs(state.rideDB) > 0.0001 else {
            setRideLocked(state, db: 0)
            return
        }
        state.rideTargetDB = 0
        state.rideReleaseFromDB = state.rideDB
        state.rideReleaseElapsed = 0
        startRideTimerLocked()
    }

    /// Settle a running ride glide to wherever it was heading, immediately.
    ///
    /// Called on pause, seek and any re-`play` — the three moments the user
    /// interrupts the deck. Each is inaudible by construction, which is why a
    /// jump of up to 4 dB is acceptable here: a paused engine renders nothing,
    /// and a seek or re-play mutes the deck through `beginFaderFlushLocked`
    /// while the chain drains and hands back the *new* level afterwards. What
    /// would not be acceptable is the alternative — a glide left running under
    /// a track the listener has just re-aimed, drifting its level for another
    /// ten seconds for a hand-over that no longer exists.
    ///
    /// A ride still inside its overlap has target == current, so this is a
    /// no-op there: pausing mid-crossfade must not move the level.
    private func settleRideLocked(_ state: DeckState) {
        guard abs(state.rideDB - state.rideTargetDB) > 0.0001 else { return }
        setRideLocked(state, db: state.rideTargetDB)
    }

    private func startRideTimerLocked() {
        guard rideTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rideTick, repeating: Self.rideTick,
                       leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.rideTickLocked() }
        timer.resume()
        rideTimer = timer
    }

    private func rideTickLocked() {
        var anyGliding = false
        for state in deckStates.values {
            guard abs(state.rideDB - state.rideTargetDB) > 0.0001 else { continue }
            // A sourceless deck is out of service (or ringing an echo tail
            // whose level is already written into player.volume) — never write
            // its fader. `resetDeckLocked` has already cleared the ride, so
            // this is belt and braces.
            if case .none = state.source { continue }
            anyGliding = true
            guard !isPaused else { continue }
            state.rideReleaseElapsed += Self.rideTick
            let db = TransitionAutomation.rideDB(
                state.rideReleaseFromDB, secondsAfterOverlap: state.rideReleaseElapsed)
            state.rideDB = db
            state.ride = LoudnessCompensation.gain(fromDB: db)
            setFaderLocked(state, state.faderRequest)
        }
        if !anyGliding {
            rideTimer?.cancel()
            rideTimer = nil
        }
    }

    /// Open a flush window around a re-schedule of a *sounding* deck.
    ///
    /// `player.stop()` only stops the source: timePitch → EQ → delay still
    /// hold roughly `faderFlushDuration` of already-rendered audio from the
    /// old position, and they push it out at whatever the fader happens to be
    /// — which is how a manual seek used to leak ~200 ms of the pre-seek
    /// position. `player.volume` sits at the mixer *input*, downstream of the
    /// whole chain, so it is the one knob that can silence audio already in
    /// flight (the same reasoning as `resetDeckLocked`). Drop it to 0 before
    /// the stop and hand it back when the player's own clock says the chain
    /// has been refilled with post-seek audio.
    ///
    /// Only called when the node is actually rendering: a parked/stopped deck
    /// has nothing in its chain (the engine keeps pulling it, so it drains
    /// within a few buffers), and muting it here would put a hole at the start
    /// of every gapless hand-over.
    private func beginFaderFlushLocked(_ state: DeckState) {
        guard state.player.isPlaying else { return }
        if state.pendingFaderRestore == nil {
            state.pendingFaderRestore = state.player.volume
        }
        state.player.volume = 0
        startFaderFlushTimerLocked()
    }

    private func startFaderFlushTimerLocked() {
        guard faderFlushTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.faderFlushTick,
                       repeating: Self.faderFlushTick, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.faderFlushTickLocked() }
        timer.resume()
        faderFlushTimer = timer
    }

    private func faderFlushTickLocked() {
        var anyOpen = false
        for state in deckStates.values {
            guard let target = state.pendingFaderRestore else { continue }
            anyOpen = true
            // Frozen engine: nothing is being rendered, so the chain is not
            // draining either — hold the mute until playback resumes.
            guard !isPaused else { continue }
            // Frames the player has emitted under the current schedule; the
            // chain has flushed once that exceeds its own depth.
            let played = livePositionLocked(state) - state.startOffset
            guard played >= Self.faderFlushDuration else { continue }
            state.pendingFaderRestore = nil
            state.player.volume = target
        }
        if !anyOpen {
            faderFlushTimer?.cancel()
            faderFlushTimer = nil
        }
    }

    /// Stop the deck and return every knob to neutral; clears the source.
    /// `keepingEchoTail` leaves the delay wet (and the EQ's global gain cut,
    /// so nothing new feeds it) for a thrown `.echoOut` tail to ring out after
    /// the outgoing player has stopped — the settling phase decays it and then
    /// neutralizes properly.
    ///
    /// The deck is left SILENT: `player.volume` goes to 0 before the stop and
    /// is not raised again here. `AVAudioPlayerNode.stop()` is not
    /// instantaneous — the chain keeps emitting the outgoing track for ~200 ms
    /// afterwards (measured; the residue is largest on the buffer-fed sources,
    /// streams and converted files). Because a deck's `volume` is an
    /// `AVAudioMixing` property applied at the *mixer input*, downstream of
    /// player → timePitch → EQ → delay, it is also the only knob that can
    /// silence audio already in flight. Restoring it to 1 here — as this used
    /// to — replayed those 200 ms at full level right after the crossfade had
    /// faded them out, and flattening the EQ on top un-ducked them as well:
    /// the "fade reached silence, then the old track jumped back for a
    /// moment" glitch. Whoever makes the deck sound again raises the fader:
    /// `play(deck:from:)`, `armGaplessLocked`, `beginOverlapLocked`'s ramp,
    /// the gapless drain fallback, and the cancel paths all set it explicitly.
    private func resetDeckLocked(_ state: DeckState, keepingEchoTail: Bool = false) {
        state.generation += 1
        if keepingEchoTail {
            // The tail owns the fader; a pending flush restore must not fire
            // underneath it either.
            state.pendingFaderRestore = nil
        } else {
            hardSilenceFaderLocked(state)
        }
        switch state.source {
        case .stream(let loader): loader.cancel()
        case .convertedFile(let feeder): feeder.cancel()
        case .file, .none: break
        }
        state.player.stop()
        if keepingEchoTail {
            // The fader stays where `.echoOut` left it — pulling it down would
            // mute the tail, which reaches the mixer through this same deck.
            // The dry residue is already silenced by the EQ's global gain.
            state.timePitch.rate = 1
            state.band(.low).gain = 0
            state.band(.mid).gain = 0
            state.band(.high).gain = 0
            state.band(.highPass).bypass = true
            state.band(.highPass).frequency = Self.sweepStartHz
        } else {
            neutralizeEffectsLocked(state)
        }
        state.source = .none
        // The trim belongs to the material that just left; a deck out of
        // service is at unity until its next load says otherwise. (An echo
        // tail is unaffected: its level is already written into player.volume,
        // and nothing calls setFaderLocked on a sourceless deck.)
        state.trim = 1
        // Same story for the hand-over's gain ride: it belonged to a transition
        // into material that is no longer here. Cleared without a fader write —
        // the deck has just been silenced above (or, for an echo tail,
        // deliberately left at the level the overlap ended on).
        clearRideStateLocked(state)
        state.isPlaying = false
        state.startOffset = 0
        state.lastKnownPosition = 0
        state.pendingStreamBuffers = 0
        state.streamStalled = false
        state.streamEnded = false
    }

    // MARK: - Clock (locked)

    /// Sample-accurate position: schedule-start offset + frames the node has
    /// actually rendered. Falls back to the cached value when the node clock
    /// is unavailable (engine paused/stopped).
    private func livePositionLocked(_ state: DeckState) -> TimeInterval {
        guard let nodeTime = state.player.lastRenderTime,
              let playerTime = state.player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return state.lastKnownPosition
        }
        let position = state.startOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
        guard position >= state.startOffset else {
            // sampleTime can be briefly negative right after play(at:).
            return state.startOffset
        }
        state.lastKnownPosition = position
        return position
    }

    private func durationLocked(_ state: DeckState) -> TimeInterval? {
        switch state.source {
        case .file(let file):
            return Double(file.length) / file.processingFormat.sampleRate
        case .convertedFile(let feeder):
            return feeder.duration
        case .stream(let loader):
            return loader.estimatedDuration
        case .none:
            return nil
        }
    }

    /// Low-frequency keepalive so `lastKnownPosition` is fresh enough to
    /// recover from a configuration change (which wipes the node clocks).
    private func startClockTimerLocked() {
        guard clockTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isPaused else { return }
            for state in self.deckStates.values where state.isPlaying {
                _ = self.livePositionLocked(state)
            }
        }
        timer.resume()
        clockTimer = timer
    }

    // MARK: - File scheduling (locked)

    private func scheduleSegmentLocked(_ state: DeckState, file: AVAudioFile,
                                       from seconds: TimeInterval, deck: Deck) {
        state.generation += 1
        let generation = state.generation
        beginFaderFlushLocked(state)
        state.player.stop()
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((max(0, seconds) * sampleRate).rounded())
        state.startOffset = Double(startFrame) / sampleRate
        state.lastKnownPosition = state.startOffset
        let remaining = file.length - startFrame
        guard remaining > 0 else {
            // Seek at/past the end: report a natural finish.
            queue.async { [weak self] in
                self?.handleDeckDrainedLocked(deck, generation: generation)
            }
            return
        }
        state.player.scheduleSegment(
            file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining),
            at: nil, completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            // Fires on stop()/interruption too; the generation check filters those.
            guard let self else { return }
            self.queue.async { self.handleDeckDrainedLocked(deck, generation: generation) }
        }
    }

    /// A deck ran out of scheduled audio under its current generation —
    /// the only path that may emit `deckFinished` (natural end).
    private func handleDeckDrainedLocked(_ deck: Deck, generation: Int) {
        let state = deckStates[deck]!
        guard generation == state.generation, state.isPlaying else { return }
        if let tr = transition, tr.from == deck {
            handleFromDeckDrainedLocked(tr)
            return
        }
        state.isPlaying = false
        if let duration = durationLocked(state) {
            state.lastKnownPosition = duration
        }
        eventContinuation.yield(.deckFinished(deck))
    }

    // MARK: - Stream scheduling (locked)

    private func scheduleStreamBufferLocked(deck: Deck, loader: ProgressiveLoader,
                                            buffer: AVAudioPCMBuffer) {
        let state = deckStates[deck]!
        guard case .stream(let current) = state.source, current === loader else { return }
        state.pendingStreamBuffers += 1
        let generation = state.generation
        state.player.scheduleBuffer(buffer, at: nil, options: [],
                                    completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.streamBufferPlayedLocked(deck: deck, generation: generation) }
        }
        if state.streamStalled {
            state.streamStalled = false
            eventContinuation.yield(.streamResumed(deck))
            startNodeIfNeededLocked(state)
        }
        if state.pendingStreamBuffers >= streamHighWater {
            loader.setDownloadSuspended(true)
        }
    }

    private func streamBufferPlayedLocked(deck: Deck, generation: Int) {
        let state = deckStates[deck]!
        guard generation == state.generation else { return }
        state.pendingStreamBuffers -= 1
        _ = livePositionLocked(state)
        if case .stream(let loader) = state.source,
           state.pendingStreamBuffers <= streamLowWater {
            loader.setDownloadSuspended(false)
        }
        guard state.pendingStreamBuffers <= 0, state.isPlaying else { return }
        if state.streamEnded {
            handleDeckDrainedLocked(deck, generation: generation)
        } else if !state.streamStalled {
            // Underrun: playback outran the network.
            state.streamStalled = true
            eventContinuation.yield(.streamStalled(deck))
        }
    }

    /// Restart a converted-file deck's chunk delivery from `seconds`.
    private func seekFeederLocked(_ state: DeckState, feeder: FileFeeder, to seconds: TimeInterval) {
        state.generation += 1
        beginFaderFlushLocked(state)
        state.player.stop()
        state.pendingStreamBuffers = 0
        state.streamEnded = false
        state.streamStalled = false
        state.startOffset = seconds
        state.lastKnownPosition = seconds
        feeder.start(from: seconds)
    }

    private func seekStreamLocked(_ state: DeckState, deck: Deck, to seconds: TimeInterval) {
        guard case .stream(let loader) = state.source else { return }
        state.generation += 1
        beginFaderFlushLocked(state)
        state.player.stop()
        state.pendingStreamBuffers = 0
        state.streamEnded = false
        state.startOffset = seconds
        state.lastKnownPosition = seconds
        if !state.streamStalled {
            // Buffering until the range request lands.
            state.streamStalled = true
            eventContinuation.yield(.streamStalled(deck))
        }
        loader.seek(to: seconds)
    }

    // MARK: - Transition machinery (locked)

    // MARK: - Plan reachability / fall back (locked)

    /// Overlap length a plan asks for; 0 for `.gapless`.
    private func overlapDurationLocked(_ plan: TransitionPlan) -> TimeInterval {
        switch plan {
        case .beatMatched(let p): return p.overlapDuration
        case .crossfade(let duration, _, _): return duration
        case .gapless: return 0
        }
    }

    /// Can the deck still *play into* this plan's out point from where it is
    /// now? `.gapless` is anchored to the end of the track, so it always can.
    private func planIsReachableLocked(_ plan: TransitionPlan, from state: DeckState) -> Bool {
        guard let outPoint = plan.outPoint else { return true }
        return livePositionLocked(state) < outPoint - Self.transitionArrivalGuard
    }

    /// The semantics of a hand-over, in one place:
    ///
    /// **A transition fires only when the outgoing track plays into its out
    /// point. A seek that lands inside — or past — the planned window does not
    /// count as arriving there.** Otherwise dropping the playhead near the end
    /// of a song (the out point is typically the last 10–20 s) would slam
    /// straight into the next track, which is what a user reported.
    ///
    /// A plan that can no longer be reached is not fired and not dropped
    /// either; it falls back to something anchored at the end of the track,
    /// so the remainder still plays and the queue still moves:
    ///
    /// - enough runway left → a plain crossfade of at most
    ///   `fallbackCrossfadeDuration`, ending at the end of the track. The
    ///   original mix point is gone, so the beat-matched / styled mechanics
    ///   (which were computed for *that* point) go with it.
    /// - not enough → `.gapless`: play out and hand over at the tail.
    ///
    /// Idempotent: applied on every (re)arm and re-plan, and after a seek on
    /// the outgoing deck.
    private func resolvePlanLocked(_ planned: PlannedTransition,
                                   from state: DeckState) -> PlannedTransition {
        guard !planIsReachableLocked(planned.plan, from: state) else { return planned }
        guard let duration = durationLocked(state) else { return .plain(.gapless) }
        let remaining = duration - livePositionLocked(state)
        let fade = min(overlapDurationLocked(planned.plan), Self.fallbackCrossfadeDuration)
        guard fade > 0, remaining >= fade + Self.fallbackCrossfadeHeadroom else {
            // No overlap left to ride over; the ride goes with the plan.
            return .plain(.gapless)
        }
        // The gain ride survives the degradation: it is a property of the two
        // tracks meeting, not of the geometry they meet with, and this is
        // still the same seam — only shorter.
        return PlannedTransition(
            plan: .crossfade(duration: fade, outPoint: duration - fade, inPoint: 0),
            style: .plain, rideDB: planned.rideDB)
    }

    /// A seek moved the outgoing deck's playhead, so the pending plan's out
    /// point may now be behind it (or its armed host-clock start point wrong).
    /// Re-resolve against the new position; the hand-over stays pending, only
    /// its mechanics are re-derived. Overlapping/settling transitions are left
    /// alone — audible audio is never re-planned (callers cancel instead).
    private func revalidateTransitionAfterSeekLocked(_ deck: Deck) {
        guard let tr = transition, tr.from == deck else { return }
        if tr.phase == .armed {
            // The gapless hand-over is pinned to a host time computed from the
            // pre-seek position; undo it and let the wait tick re-arm.
            disarmGaplessLocked()
        }
        guard tr.phase == .waiting else { return }
        let resolved = resolvePlanLocked(
            PlannedTransition(plan: tr.plan, style: tr.style, rideDB: tr.rideDB),
            from: deckStates[deck]!)
        transition = TransitionState(plan: resolved.plan, style: resolved.style,
                                     rideDB: resolved.rideDB, from: tr.from, to: tr.to)
        startTransitionTimerLocked(interval: slowTickInterval)
    }

    private func startTransitionTimerLocked(interval: TimeInterval) {
        if transitionTimer != nil, transitionTimerInterval == interval { return }
        transitionTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval,
                       leeway: .milliseconds(interval < 0.1 ? 2 : 50))
        timer.setEventHandler { [weak self] in self?.transitionTickLocked() }
        timer.resume()
        transitionTimer = timer
        transitionTimerInterval = interval
    }

    private func stopTransitionTimerLocked() {
        transitionTimer?.cancel()
        transitionTimer = nil
        transitionTimerInterval = 0
    }

    private func transitionTickLocked() {
        guard let tr = transition else {
            stopTransitionTimerLocked()
            return
        }
        guard !isPaused else { return }
        switch tr.phase {
        case .waiting:
            transitionWaitTickLocked(tr)
        case .armed:
            break // gapless: waiting for the outgoing deck's completion
        case .overlapping:
            tr.elapsed += transitionTimerInterval
            updateOverlapLocked(tr)
        case .settling:
            tr.restoreElapsed += transitionTimerInterval
            settleTickLocked(tr)
        }
    }

    private func transitionWaitTickLocked(_ tr: TransitionState) {
        let from = deckStates[tr.from]!
        switch tr.plan {
        case .gapless:
            // Arm the incoming deck shortly before the outgoing one ends.
            // scheduleSegment completion callbacks are not sample-accurate,
            // so the handover uses play(at:) on the shared host clock.
            // Streamed decks only have a CBR byte-estimate duration (off by
            // seconds on VBR) — never arm from it; the drain fallback in
            // handleFromDeckDrainedLocked covers them with a tiny gap.
            guard case .file = from.source else { return }
            guard let duration = durationLocked(from) else { return }
            let position = livePositionLocked(from)
            let rate = Double(max(from.timePitch.rate, 0.01))
            let remaining = (duration - position) / rate
            adjustWaitTimerLocked(remaining: remaining)
            if remaining <= 1.0 {
                armGaplessLocked(tr, startingIn: max(remaining, 0))
            }
        case .crossfade, .beatMatched:
            guard let outPoint = tr.plan.outPoint else { return }
            let position = livePositionLocked(from)
            let rate = Double(max(from.timePitch.rate, 0.01))
            adjustWaitTimerLocked(remaining: (outPoint - position) / rate)
            if position + transitionTimerInterval / 2 >= outPoint {
                beginOverlapLocked(tr)
            }
        }
    }

    /// The wait can span minutes; idle at the slow tick and only switch to
    /// the 50 Hz ramp tick for the final approach.
    private func adjustWaitTimerLocked(remaining: TimeInterval) {
        startTransitionTimerLocked(interval: remaining > 2 ? slowTickInterval : tickInterval)
    }

    /// Undo an armed gapless hand-over (incoming deck scheduled on the host
    /// clock) without touching its loaded file; the wait tick re-arms later.
    private func disarmGaplessLocked() {
        guard let tr = transition, tr.phase == .armed else { return }
        let to = deckStates[tr.to]!
        to.generation += 1
        to.player.stop()
        to.isPlaying = false
        to.startOffset = 0
        to.lastKnownPosition = 0
        tr.phase = .waiting
    }

    private func armGaplessLocked(_ tr: TransitionState, startingIn seconds: TimeInterval) {
        let to = deckStates[tr.to]!
        guard case .file(let file) = to.source else {
            // Contract violation: the to deck was not loaded. Drop the plan;
            // the from deck will finish naturally and emit deckFinished.
            transition = nil
            stopTransitionTimerLocked()
            return
        }
        scheduleSegmentLocked(to, file: file, from: 0, deck: tr.to)
        setFaderLocked(to, 1)
        to.isPlaying = true
        let startHost = mach_absolute_time() &+ AVAudioTime.hostTime(forSeconds: seconds)
        to.player.play(at: AVAudioTime(hostTime: startHost))
        tr.phase = .armed
    }

    private func beginOverlapLocked(_ tr: TransitionState) {
        let to = deckStates[tr.to]!
        ensureEngineRunningLocked()
        let inPoint: TimeInterval
        switch tr.plan {
        case .crossfade(_, _, let point):
            inPoint = point
        case .beatMatched(let plan):
            inPoint = plan.inPoint
        case .gapless:
            return
        }

        // Start the incoming source FIRST, and only prime the deck (matched
        // rate, staged EQ cut) once the overlap is certain to run.
        //
        // Priming first is how a dropped plan used to strand the incoming deck
        // at -24/-18/-24 dB: nothing releases those bands except the ramps
        // that then never ran, `play(deck:from:)` reuses a deck exactly as it
        // finds it, and the whole next song came out muffled.
        switch to.source {
        case .file(let file):
            scheduleSegmentLocked(to, file: file, from: inPoint, deck: tr.to)
        case .convertedFile(let feeder):
            seekFeederLocked(to, feeder: feeder, to: inPoint)
        case .stream, .none:
            // Contract violation: the incoming deck was never loaded, or was
            // reloaded as a stream under a plan that was still waiting. Drop
            // the plan and leave the deck as neutral as we found it.
            neutralizeEffectsLocked(to)
            transition = nil
            stopTransitionTimerLocked()
            return
        }

        if case .beatMatched(let plan) = tr.plan {
            to.timePitch.rate = plan.incomingRate
            if !tr.style.stagedEQ { to.band(.low).gain = Self.bassCutDB }
        }
        if tr.style.stagedEQ {
            // The incoming track is held back on all three bands and is let
            // in stage by stage (highs first, lows at the swap).
            to.band(.low).gain = Self.bassCutDB
            to.band(.mid).gain = Self.midCutDB
            to.band(.high).gain = Self.highCutDB
        }
        // The gain ride goes on here, at full value and with no ramp: the
        // incoming fader is about to be written to 0, so there is nothing
        // audible for the step to land on. From this instant every fader write
        // for this deck — the whole overlap curve — is scaled by it.
        setRideLocked(to, db: tr.rideDB)
        setFaderLocked(to, 0)
        to.isPlaying = true
        startNodeIfNeededLocked(to)
        tr.phase = .overlapping
        tr.elapsed = 0
        startTransitionTimerLocked(interval: tickInterval)
    }

    /// Void a pending/running transition that depends on `deck`, leaving both
    /// of its decks in a defined state (this is `cancelTransitionLocked`, just
    /// scoped to the decks that matter).
    private func invalidateTransitionLocked(touching deck: Deck) {
        guard let tr = transition, tr.from == deck || tr.to == deck else { return }
        cancelTransitionLocked()
    }

    /// Is a transition currently driving this deck's knobs? Only true once the
    /// hand-over is actually running — a `.waiting` plan has touched nothing
    /// yet, so a deck under one may still be normalized freely.
    private func deckIsInLiveTransitionLocked(_ deck: Deck) -> Bool {
        guard let tr = transition, tr.phase != .waiting else { return false }
        return tr.from == deck || tr.to == deck
    }

    /// Park a deck: silent at the mixer and every knob transparent. Used on
    /// the paths that end a deck's contribution outside `resetDeckLocked`
    /// (echo tail finished, transition cancelled while settling).
    private func silenceDeckLocked(_ state: DeckState) {
        hardSilenceFaderLocked(state)
        neutralizeEffectsLocked(state)
    }

    /// Post-overlap phase: ramp a beat-matched rate back to 1.0 on the
    /// incoming deck and/or decay an `.echoOut` tail on the outgoing one.
    /// Ends — clearing the transition — only when both are done and both
    /// decks are back to neutral.
    private func settleTickLocked(_ tr: TransitionState) {
        let from = deckStates[tr.from]!
        let to = deckStates[tr.to]!
        var done = true

        if tr.restoringRate {
            let settle = TransitionAutomation.settleFrame(
                plan: tr.plan, restoringRate: true, echoTailRinging: false,
                elapsed: tr.restoreElapsed)
            to.timePitch.rate = settle.incomingRate
            if settle.rateRestoreDone {
                tr.restoringRate = false
            } else {
                done = false
            }
        }

        if tr.echoTailRinging {
            let settle = TransitionAutomation.settleFrame(
                plan: tr.plan, restoringRate: false, echoTailRinging: true,
                elapsed: tr.restoreElapsed)
            // Wet level down alongside the delay's own feedback decay, so the
            // tail dies out instead of being chopped.
            from.delay.wetDryMix = settle.outgoingDelayWetDryMix
            from.delay.feedback = settle.outgoingDelayFeedback
            if settle.echoTailDone {
                tr.echoTailRinging = false
                silenceDeckLocked(from)
            } else {
                done = false
            }
        }

        if done {
            transition = nil
            stopTransitionTimerLocked()
        }
    }

    /// One overlap tick: the curves come from `TransitionAutomation` (shared
    /// with the offline renderer), this only applies them to the live graph
    /// and latches the events the rest of the engine keys off.
    private func updateOverlapLocked(_ tr: TransitionState) {
        let from = deckStates[tr.from]!
        let to = deckStates[tr.to]!
        let frame = TransitionAutomation.frame(
            plan: tr.plan, style: tr.style, elapsed: tr.elapsed, geometry: tr.geometry)

        applyAutomationLocked(frame.outgoing, to: from)
        applyAutomationLocked(frame.incoming, to: to)

        // `.echoOut`'s throw is a one-shot event for the settling phase; the
        // curve itself is a pure function of "progress has crossed the stop
        // point", so the latch only records that it happened.
        if frame.echoThrown, !tr.echoThrown {
            tr.echoThrown = true
            tr.echoTailRinging = true
        }

        if frame.midpointReached, !tr.midpointSent {
            tr.midpointSent = true
            eventContinuation.yield(.transitionMidpoint(from: tr.from, to: tr.to))
        }
        if frame.isComplete {
            finishOverlapLocked(tr)
        }
    }

    /// Write one automation frame's deck parameters onto a live chain. The
    /// fader goes through `setFaderLocked` so an open seek-flush window still
    /// holds the mute; everything else is a direct parameter write.
    private func applyAutomationLocked(_ p: TransitionAutomation.DeckParameters,
                                       to state: DeckState) {
        setFaderLocked(state, p.fader)
        DeckChain.apply(p, timePitch: state.timePitch, eq: state.eq, delay: state.delay)
    }

    private func finishOverlapLocked(_ tr: TransitionState) {
        let to = deckStates[tr.to]!
        if !tr.midpointSent {
            tr.midpointSent = true
            eventContinuation.yield(.transitionMidpoint(from: tr.from, to: tr.to))
        }
        // A thrown echo tail outlives the overlap: stop the outgoing player
        // (so nothing new feeds the delay) but leave the delay wet, and let
        // the settling phase decay it to neutral.
        let tailRinging = tr.echoThrown && tr.echoTailRinging
        resetDeckLocked(deckStates[tr.from]!, keepingEchoTail: tailRinging)
        setFaderLocked(to, 1)
        // "Fader fully open" now means the deck's trim *and* its ride; start
        // letting go of the latter. The release runs on the deck's own glide
        // timer, so it does not hold the transition open — this block may well
        // clear `transition` two lines below while the ride is still unwinding.
        releaseRideLocked(to)
        to.band(.low).gain = 0
        to.band(.mid).gain = 0
        to.band(.high).gain = 0
        to.band(.highPass).bypass = true
        eventContinuation.yield(.transitionCompleted(from: tr.from, to: tr.to))

        if case .beatMatched(let plan) = tr.plan, abs(plan.incomingRate - 1) > 0.001 {
            tr.restoringRate = true
        } else {
            to.timePitch.rate = 1
        }
        if tr.restoringRate || tailRinging {
            tr.phase = .settling
            tr.restoreElapsed = 0
            startTransitionTimerLocked(interval: tickInterval)
        } else {
            transition = nil
            stopTransitionTimerLocked()
        }
    }

    /// The outgoing deck of an active transition drained naturally.
    private func handleFromDeckDrainedLocked(_ tr: TransitionState) {
        let from = deckStates[tr.from]!
        switch tr.plan {
        case .gapless:
            let to = deckStates[tr.to]!
            if tr.phase == .waiting || !to.player.isPlaying {
                // Never armed (streamed/converted outgoing deck, or a
                // configuration change dropped the armed schedule) — start
                // the incoming deck now.
                switch to.source {
                case .file(let file):
                    scheduleSegmentLocked(to, file: file, from: 0, deck: tr.to)
                case .convertedFile(let feeder):
                    seekFeederLocked(to, feeder: feeder, to: 0)
                case .stream, .none:
                    break
                }
                setFaderLocked(to, 1)
                to.isPlaying = true
                ensureEngineRunningLocked()
                startNodeIfNeededLocked(to)
            }
            eventContinuation.yield(.transitionMidpoint(from: tr.from, to: tr.to))
            resetDeckLocked(from)
            eventContinuation.yield(.transitionCompleted(from: tr.from, to: tr.to))
            transition = nil
            stopTransitionTimerLocked()
        case .crossfade, .beatMatched:
            if tr.phase == .overlapping {
                // The file ended a hair before the ramp did — close it out.
                finishOverlapLocked(tr)
            } else {
                // The out point was never reached (plan beyond the file end):
                // behave like a plain natural finish.
                transition = nil
                stopTransitionTimerLocked()
                from.isPlaying = false
                eventContinuation.yield(.deckFinished(tr.from))
            }
        }
    }

    private func cancelTransitionLocked() {
        guard let tr = transition else { return }
        transition = nil
        stopTransitionTimerLocked()
        let from = deckStates[tr.from]!
        let to = deckStates[tr.to]!
        switch tr.phase {
        case .waiting:
            break
        case .armed, .overlapping:
            if tr.midpointSent {
                // Past the audible midpoint the incoming deck IS the current
                // track — finish the hand-over immediately instead of
                // silencing it and resurrecting the outgoing tail.
                resetDeckLocked(from)
                setFaderLocked(to, 1)
                // Same as a normal finish: this deck is the track now, so its
                // ride is let go of gently rather than snapped away.
                releaseRideLocked(to)
                neutralizeEffectsLocked(to)
                eventContinuation.yield(.transitionCompleted(from: tr.from, to: tr.to))
                return
            }
            // The incoming deck may already be sounding: silence it but keep
            // its source loaded so the caller can reuse it; un-ramp the
            // outgoing deck. The fader goes down before the stop and stays
            // down for the same reason resetDeckLocked parks a deck silent —
            // stop() leaves ~200 ms draining out of the chain.
            to.generation += 1
            hardSilenceFaderLocked(to)
            to.player.stop()
            neutralizeEffectsLocked(to)
            // The hand-over never happened, so neither did its ride. The deck
            // is silent, so dropping it is inaudible; leaving it would colour
            // whatever this deck is reused for next.
            setRideLocked(to, db: 0)
            to.isPlaying = false
            setFaderLocked(from, 1)
            neutralizeEffectsLocked(from)
        case .settling:
            // The tail (if any) is cut short — a cancel means something else
            // needs these decks now. `to` is the deck now carrying the track,
            // so it keeps its fader; `from` is spent. A ride release on `to`
            // is left running: it belongs to the deck, not to this transition,
            // and whatever happens to that deck next settles or clears it.
            neutralizeEffectsLocked(to)
            silenceDeckLocked(from)
        }
    }

    // MARK: - Configuration changes (locked)

    /// The engine stopped because the output hardware changed (new default
    /// device on macOS, route change on iOS). Player-node schedules are gone;
    /// rebuild the graph and resume every active deck from its cached
    /// position.
    private func handleConfigurationChange() {
        // An armed gapless hand-over died with the graph; disarm it so the
        // restart below doesn't blast the incoming deck from position zero.
        disarmGaplessLocked()
        for state in deckStates.values {
            state.generation += 1 // orphan any in-flight completions
        }
        engine.stop()
        for state in deckStates.values {
            connectChainLocked(state, format: graphFormat)
        }
        let anyActive = deckStates.values.contains {
            if case .none = $0.source { return false }
            return true
        }
        guard anyActive else { return }
        engine.prepare()
        try? engine.start()

        for (deck, state) in deckStates {
            switch state.source {
            case .none:
                break
            case .file(let file):
                // Reschedule even when paused so resume() still works.
                scheduleSegmentLocked(state, file: file, from: state.lastKnownPosition, deck: deck)
                startNodeIfNeededLocked(state)
            case .convertedFile(let feeder):
                seekFeederLocked(state, feeder: feeder, to: state.lastKnownPosition)
                startNodeIfNeededLocked(state)
            case .stream(let loader):
                // Scheduled PCM was dropped with the graph; restart the
                // transfer from the cached position. This abandons the .part
                // cache write for this download (documented limitation).
                if loader.canSeek {
                    seekStreamLocked(state, deck: deck, to: state.lastKnownPosition)
                } else {
                    state.generation += 1
                    state.pendingStreamBuffers = 0
                }
                startNodeIfNeededLocked(state)
            }
        }
    }
}
