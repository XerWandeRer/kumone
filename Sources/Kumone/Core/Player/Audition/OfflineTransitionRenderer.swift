import AVFoundation
import Foundation

/// Renders a planned transition to a WAV file, offline and faster than real
/// time, through a node graph isomorphic to `PlaybackEngine`'s.
///
/// The point is a tight tuning loop: change a `TransitionPlanner` constant or a
/// `TransitionAutomation` curve, re-render, listen. To be worth trusting, the
/// render has to be the same computation the player performs — so:
///
/// - the graph is `DeckChain`'s, twice (player → timePitch → EQ → delay →
///   mixer), at `DeckChain.format` (44.1 kHz stereo), the same fixed format
///   the live engine wires;
/// - the parameters come from `TransitionAutomation`, the same pure function
///   the live engine's overlap tick applies, stepped at the same 50 Hz;
/// - the post-overlap settling (rate restore, echo-tail decay) mirrors
///   `PlaybackEngine.settleTickLocked` via `TransitionAutomation.settleFrame`.
///
/// What is deliberately NOT modelled: the live engine's seek flush windows,
/// stream/underrun handling and plan re-resolution. Those are transport
/// concerns; none of them shape how a transition sounds.
enum OfflineTransitionRenderer {

    struct Options: Sendable {
        /// Context before the hand-over begins.
        var preRoll: TimeInterval = 12
        /// Context after the overlap (and any settling) has finished.
        var postRoll: TimeInterval = 12
        /// Automation granularity; 50 Hz is the live engine's ramp tick.
        var tickRate: Double = 50
        /// How the renderer gets a vocal stem when the style asks for one.
        /// Nil — the default — means stem techniques degrade to a whole-mix
        /// render, with the reason reported in `Result.stemFallbackReason`.
        var vocalStemProvider: VocalStemProvider? = nil
        init() {}
    }

    struct Result: Sendable {
        let outputURL: URL
        /// Length of the rendered file.
        let duration: TimeInterval
        /// Where in the rendered file the overlap starts / how long it lasts.
        /// (For `.gapless`, the splice point with a zero-length overlap.)
        let overlapStart: TimeInterval
        let overlapDuration: TimeInterval
        /// Wall-clock seconds spent rendering, and the resulting speed-up.
        let renderSeconds: Double
        /// The stem technique that actually shaped this render, if any.
        var stemTechnique: String? = nil
        /// Wall-clock seconds the stem provider took (separation, or a cache
        /// read), and how much outgoing audio it was asked for.
        var stemSeconds: Double? = nil
        var stemSeparatedSeconds: TimeInterval? = nil
        /// Vocal energy in the separated window, relative to the mixture.
        /// Near zero means an instrumental outro — the technique ran and had
        /// nothing to work on.
        var stemVocalEnergyRatio: Double? = nil
        /// The provider served the window from its own cache.
        var stemCacheHit = false
        /// Why a requested stem technique was *not* applied. Non-nil means the
        /// render is a plain whole-mix one and says so out loud, rather than
        /// silently sounding like something the caller did not ask for.
        var stemFallbackReason: String? = nil

        var realtimeFactor: Double { renderSeconds > 0 ? duration / renderSeconds : .infinity }
    }

    enum RenderError: LocalizedError {
        case emptySegment(URL)
        case converterUnavailable(URL)
        case manualRenderingFailed

        var errorDescription: String? {
            switch self {
            case .emptySegment(let url):
                return "no audio to read at the requested offset in \(url.lastPathComponent)"
            case .converterUnavailable(let url):
                return "cannot convert \(url.lastPathComponent) to 44.1 kHz stereo"
            case .manualRenderingFailed:
                return "offline rendering stopped early"
            }
        }
    }

    // MARK: - Entry point

    static func render(_ planned: PlannedTransition,
                       outgoing outgoingURL: URL, incoming incomingURL: URL,
                       to outputURL: URL, options: Options = Options()) throws -> Result {
        let started = Date()
        let format = DeckChain.format
        let sampleRate = format.sampleRate
        let geometry = TransitionAutomation.Geometry(plan: planned.plan)

        // How long the post-overlap settling phase runs, if at all.
        var settleDuration: TimeInterval = 0
        if case .beatMatched(let p) = planned.plan, abs(p.incomingRate - 1) > 0.001 {
            settleDuration = TransitionAutomation.rateRestoreDuration
        }
        if planned.style.outroEffect == .echoOut, geometry.overlapDuration > 0 {
            settleDuration = max(settleDuration, TransitionAutomation.echoTailDuration)
        }

        // Source windows. The outgoing deck may be sped up by up to ±4 % during
        // a beat-matched overlap, so give it a little more material than the
        // render time asks for.
        let rateHeadroom = 1.1
        let outPoint = planned.plan.outPoint
        let overlap = geometry.overlapDuration

        let engine = AVAudioEngine()
        let decks = (0..<2).map { _ -> OfflineDeck in OfflineDeck(engine: engine, format: format) }
        let from = decks[0], to = decks[1]
        engine.mainMixerNode.outputVolume = 1
        for deck in decks { deck.connect(engine: engine, format: format) }

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }

        let writer = try AVAudioFile(forWriting: outputURL,
                                     settings: wavSettings(sampleRate: sampleRate),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let scratch = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                       frameCapacity: engine.manualRenderingMaximumFrameCount)!
        let tickFrames = AVAudioFrameCount((sampleRate / options.tickRate).rounded())

        /// Pull `frames` frames through the graph and append them to the file.
        func pump(_ frames: AVAudioFrameCount) throws {
            var remaining = frames
            while remaining > 0 {
                let chunk = min(remaining, scratch.frameCapacity)
                let status = try engine.renderOffline(chunk, to: scratch)
                switch status {
                case .success:
                    try writer.write(from: scratch)
                    remaining -= scratch.frameLength
                case .insufficientDataFromInputNode:
                    // No input node in this graph; treat as end of material.
                    return
                case .cannotDoInCurrentContext, .error:
                    throw RenderError.manualRenderingFailed
                @unknown default:
                    throw RenderError.manualRenderingFailed
                }
            }
        }

        var overlapStart = options.preRoll
        var written: AVAudioFrameCount = 0
        var stemApplied: StemTechniqueLayer.Applied?
        var stemFallback: String?

        if case .gapless = planned.plan {
            if planned.style.stemTechnique != nil {
                stemFallback = StemTechniqueLayer.StemError.noOverlap.errorDescription
            }
            // Tail-to-head: play out the end of the outgoing track, then start
            // the incoming one on the very next sample.
            let outDuration = try duration(of: outgoingURL)
            let tail = min(options.preRoll, outDuration)
            let outBuffer = try loadSegment(outgoingURL, from: outDuration - tail,
                                            seconds: tail, format: format)
            from.schedule(outBuffer)
            from.player.volume = 1
            from.player.play()
            let tailFrames = outBuffer.frameLength
            try pump(tailFrames)
            written += tailFrames
            overlapStart = Double(tailFrames) / sampleRate

            from.player.stop()
            let inBuffer = try loadSegment(incomingURL, from: 0,
                                           seconds: options.postRoll, format: format)
            to.schedule(inBuffer)
            to.player.volume = 1
            to.player.play()
            try pump(inBuffer.frameLength)
            written += inBuffer.frameLength
        } else {
            let outStart = max(0, (outPoint ?? 0) - options.preRoll)
            let preRoll = (outPoint ?? 0) - outStart
            let inPoint: TimeInterval
            switch planned.plan {
            case .crossfade(_, _, let point): inPoint = point
            case .beatMatched(let p): inPoint = p.inPoint
            case .gapless: inPoint = 0
            }

            let outBuffer = try loadSegment(
                outgoingURL, from: outStart,
                seconds: (preRoll + overlap) * rateHeadroom + 1, format: format)
            let inBuffer = try loadSegment(
                incomingURL, from: inPoint,
                seconds: (overlap + settleDuration + options.postRoll) * rateHeadroom + 1,
                format: format)

            // --- Stem layer: rewrite the outgoing deck's overlap window
            // before a single sample is pulled through the graph, so the
            // automation below plays over stems without knowing it.
            if let technique = planned.style.stemTechnique {
                var outgoingRate = 1.0
                if case .beatMatched(let p) = planned.plan { outgoingRate = Double(p.outgoingRate) }
                do {
                    guard let provider = options.vocalStemProvider else {
                        throw StemTechniqueLayer.StemError.noProvider
                    }
                    stemApplied = try StemTechniqueLayer.apply(
                        technique, to: outBuffer,
                        source: outgoingURL, windowStart: outStart,
                        overlapStartFrame: Int((preRoll * sampleRate).rounded()),
                        plan: planned.plan, style: planned.style, geometry: geometry,
                        outgoingRate: outgoingRate, provider: provider)
                } catch {
                    stemFallback = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }

            // --- Pre-roll: the outgoing track alone, chain transparent.
            from.schedule(outBuffer)
            from.player.volume = 1
            from.player.play()
            let preRollFrames = AVAudioFrameCount((preRoll * sampleRate).rounded())
            try pump(preRollFrames)
            written += preRollFrames
            overlapStart = preRoll

            // --- Overlap: `beginOverlapLocked`'s priming, then the ramps.
            to.schedule(inBuffer)
            if case .beatMatched(let p) = planned.plan {
                to.timePitch.rate = p.incomingRate
                if !planned.style.stagedEQ {
                    to.eq.bands[DeckChain.Band.low.rawValue].gain = TransitionAutomation.bassCutDB
                }
            }
            if planned.style.stagedEQ {
                to.eq.bands[DeckChain.Band.low.rawValue].gain = TransitionAutomation.bassCutDB
                to.eq.bands[DeckChain.Band.mid.rawValue].gain = TransitionAutomation.midCutDB
                to.eq.bands[DeckChain.Band.high.rawValue].gain = TransitionAutomation.highCutDB
            }
            to.player.volume = 0
            to.player.play()

            var elapsed: TimeInterval = 0
            var echoThrown = false
            let tickSeconds = Double(tickFrames) / sampleRate
            while elapsed < overlap {
                let frame = TransitionAutomation.frame(
                    plan: planned.plan, style: planned.style,
                    elapsed: elapsed, geometry: geometry)
                from.apply(frame.outgoing)
                to.apply(frame.incoming)
                if frame.echoThrown { echoThrown = true }
                try pump(tickFrames)
                written += tickFrames
                elapsed += tickSeconds
            }

            // --- `finishOverlapLocked`: the outgoing deck is spent; a thrown
            // echo tail outlives it (player stopped, delay left wet).
            let tailRinging = echoThrown
            from.player.stop()
            from.timePitch.rate = 1
            for band in [DeckChain.Band.low, .mid, .high] { from.eq.bands[band.rawValue].gain = 0 }
            from.eq.bands[DeckChain.Band.highPass.rawValue].bypass = true
            if !tailRinging {
                from.player.volume = 0
                from.eq.globalGain = 0
                from.delay.wetDryMix = 0
                from.delay.feedback = 0
            }
            to.player.volume = 1
            for band in [DeckChain.Band.low, .mid, .high] { to.eq.bands[band.rawValue].gain = 0 }
            to.eq.bands[DeckChain.Band.highPass.rawValue].bypass = true

            var restoringRate = false
            if case .beatMatched(let p) = planned.plan, abs(p.incomingRate - 1) > 0.001 {
                restoringRate = true
            } else {
                to.timePitch.rate = 1
            }

            // --- Settling.
            if restoringRate || tailRinging {
                var settled: TimeInterval = 0
                while settled < settleDuration {
                    let s = TransitionAutomation.settleFrame(
                        plan: planned.plan, restoringRate: restoringRate,
                        echoTailRinging: tailRinging, elapsed: settled)
                    if restoringRate { to.timePitch.rate = s.incomingRate }
                    if tailRinging {
                        from.delay.wetDryMix = s.outgoingDelayWetDryMix
                        from.delay.feedback = s.outgoingDelayFeedback
                    }
                    try pump(tickFrames)
                    written += tickFrames
                    settled += tickSeconds
                }
                from.player.volume = 0
                DeckChain.neutralize(timePitch: from.timePitch, eq: from.eq, delay: from.delay)
                to.timePitch.rate = 1
            }

            // --- Post-roll: the incoming track alone.
            let postFrames = AVAudioFrameCount((options.postRoll * sampleRate).rounded())
            try pump(postFrames)
            written += postFrames
        }

        let duration = Double(written) / sampleRate
        return Result(outputURL: outputURL, duration: duration,
                      overlapStart: overlapStart, overlapDuration: overlap,
                      renderSeconds: Date().timeIntervalSince(started),
                      stemTechnique: stemApplied?.technique.label,
                      stemSeconds: stemApplied?.seconds,
                      stemSeparatedSeconds: stemApplied?.separatedSeconds,
                      stemVocalEnergyRatio: stemApplied?.vocalEnergyRatio,
                      stemCacheHit: stemApplied?.cacheHit ?? false,
                      stemFallbackReason: stemFallback)
    }

    // MARK: - Offline deck

    /// One deck of the offline graph: the same nodes, in the same order, with
    /// the same neutral pose as a live `PlaybackEngine` deck.
    private final class OfflineDeck {
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: DeckChain.bandCount)
        let delay = AVAudioUnitDelay()

        init(engine: AVAudioEngine, format: AVAudioFormat) {
            DeckChain.configureBands(eq)
            DeckChain.configureDelay(delay)
            engine.attach(player)
            engine.attach(timePitch)
            engine.attach(eq)
            engine.attach(delay)
        }

        func connect(engine: AVAudioEngine, format: AVAudioFormat) {
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: eq, format: format)
            engine.connect(eq, to: delay, format: format)
            engine.connect(delay, to: engine.mainMixerNode, format: format)
        }

        func schedule(_ buffer: AVAudioPCMBuffer) {
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }

        func apply(_ p: TransitionAutomation.DeckParameters) {
            player.volume = p.fader
            DeckChain.apply(p, timePitch: timePitch, eq: eq, delay: delay)
        }
    }

    // MARK: - Source loading

    static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Read `seconds` of `url` starting at `from` and hand it back in the deck
    /// graph's format — the offline equivalent of the live engine's FileFeeder
    /// (hi-res and mono files are converted, the graph is never reconfigured).
    private static func loadSegment(_ url: URL, from: TimeInterval, seconds: TimeInterval,
                                    format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let startFrame = max(0, min(file.length,
                                    AVAudioFramePosition((from * source.sampleRate).rounded())))
        let available = file.length - startFrame
        let wanted = AVAudioFrameCount(max(0, min(Double(available),
                                                  (seconds * source.sampleRate).rounded())))
        guard wanted > 0 else { throw RenderError.emptySegment(url) }
        file.framePosition = startFrame
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: wanted) else {
            throw RenderError.emptySegment(url)
        }
        try file.read(into: input, frameCount: wanted)

        if source.sampleRate == format.sampleRate, source.channelCount == format.channelCount {
            return input
        }
        guard let converter = AVAudioConverter(from: source, to: format) else {
            throw RenderError.converterUnavailable(url)
        }
        let ratio = format.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw RenderError.converterUnavailable(url)
        }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard output.frameLength > 0 else { throw RenderError.emptySegment(url) }
        return output
    }

    private static func wavSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}
