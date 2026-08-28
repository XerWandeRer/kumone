import Accelerate
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

        /// Per-deck loudness compensation, in dB, exactly as the live player
        /// would apply it (`LoudnessCompensation`). Multiplied into every fader
        /// write, so what the render sounds like is what the product does.
        /// 0/0 — the default — is the uncompensated render, bit-identical to
        /// what this renderer produced before compensation existed.
        var outgoingTrimDB: Double = 0
        var incomingTrimDB: Double = 0

        /// The hand-over's gain ride for the incoming deck, in dB
        /// (`PlannedTransition.rideDB`), applied exactly as the live engine
        /// applies it: full value for the whole overlap, then released at
        /// `TransitionAutomation.rideReleaseDBPerSecond`. 0 — the default — is
        /// the un-ridden render, bit-identical to what this produced before.
        ///
        /// The post-roll is stretched when needed so the release finishes
        /// inside the rendered file: the whole point of auditioning a ride is
        /// hearing that you cannot hear it being let go of.
        var rideDB: Double = 0

        /// Loudness the finished file is normalized to before it is written, or
        /// nil to write it at its natural level.
        ///
        /// This is a **blind-listening fairness device and nothing else**: it
        /// has no counterpart in the player, is applied to the mix after both
        /// decks have been summed, and cancels out of any A/B comparison of two
        /// renders of the same pair. Loudness bias is the strongest confound in
        /// listening tests — the louder of two takes just sounds better — and
        /// several of our techniques (`vocalDuck` above all) change level by
        /// construction, so every result gathered without it is suspect
        /// (docs/automix-research-notes.md §2.4). Sony's listening test used
        /// −23 dBFS; −16 LUFS is the same idea on the same scale the rest of
        /// this feature speaks, and leaves comfortable headroom.
        var normalizeToLUFS: Double? = -16
        /// The normalization never lets the file's peak past this.
        var normalizePeakCeilingDBFS: Double = -1
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
        /// The trims the two decks played at (dB), mirroring the product.
        var outgoingTrimDB: Double = 0
        var incomingTrimDB: Double = 0
        /// The gain ride the incoming deck was held at across the overlap, and
        /// how long its release took to unwind inside this file.
        var rideDB: Double = 0
        var rideReleaseSeconds: TimeInterval = 0
        /// Blind-test normalization: what the summed mix measured before it was
        /// written, and the constant gain applied to land it on the target.
        /// Nil/0 when normalization was off or the mix could not be measured.
        var measuredLUFS: Double? = nil
        var normalizationGainDB: Double = 0
        var normalizationTargetLUFS: Double? = nil
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

        // Gain ride: only over an overlap, exactly like the planner and the
        // live engine. Stretch the post-roll so the release — up to ~13 s at
        // 0.3 dB/s — finishes inside the file, plus a second of the track at
        // its own level to land on.
        var rideDB: Double = 0
        if case .gapless = planned.plan {} else { rideDB = options.rideDB }
        let rideRelease = TransitionAutomation.rideReleaseDuration(rideDB)
        let postRoll = rideRelease > 0
            ? max(options.postRoll, rideRelease + 1)
            : options.postRoll

        let engine = AVAudioEngine()
        let decks = (0..<2).map { _ -> OfflineDeck in OfflineDeck(engine: engine, format: format) }
        let from = decks[0], to = decks[1]
        // Same trim the live decks would carry, in the same place: a multiplier
        // on the fader, never on the mixer.
        from.trim = LoudnessCompensation.gain(fromDB: options.outgoingTrimDB)
        to.trim = LoudnessCompensation.gain(fromDB: options.incomingTrimDB)
        engine.mainMixerNode.outputVolume = 1
        for deck in decks { deck.connect(engine: engine, format: format) }

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }

        let scratch = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                       frameCapacity: engine.manualRenderingMaximumFrameCount)!
        let tickFrames = AVAudioFrameCount((sampleRate / options.tickRate).rounded())

        // The mix is accumulated rather than streamed straight to disk: the
        // blind-test normalization needs the whole file's loudness before a
        // single sample is written, and a ~40 s stereo render is a few MB.
        let channelCount = Int(engine.manualRenderingFormat.channelCount)
        var mix = [[Float]](repeating: [], count: channelCount)

        /// Pull `frames` frames through the graph and append them to the mix.
        func pump(_ frames: AVAudioFrameCount) throws {
            var remaining = frames
            while remaining > 0 {
                let chunk = min(remaining, scratch.frameCapacity)
                let status = try engine.renderOffline(chunk, to: scratch)
                switch status {
                case .success:
                    if let data = scratch.floatChannelData {
                        for channel in 0..<channelCount {
                            mix[channel].append(contentsOf: UnsafeBufferPointer(
                                start: data[channel], count: Int(scratch.frameLength)))
                        }
                    }
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
            from.setFader(1)
            from.player.play()
            let tailFrames = outBuffer.frameLength
            try pump(tailFrames)
            written += tailFrames
            overlapStart = Double(tailFrames) / sampleRate

            from.player.stop()
            let inBuffer = try loadSegment(incomingURL, from: 0,
                                           seconds: options.postRoll, format: format)
            to.schedule(inBuffer)
            to.setFader(1)
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
                seconds: (overlap + settleDuration + postRoll) * rateHeadroom + 1,
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
            from.setFader(1)
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
            // `beginOverlapLocked`: the ride goes on at full value while the
            // incoming fader is still 0, so it never steps anything audible.
            to.setRide(db: rideDB)
            to.setFader(0)
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
                from.setFader(0)
                from.eq.globalGain = 0
                from.delay.wetDryMix = 0
                from.delay.feedback = 0
            }
            to.setFader(1)
            for band in [DeckChain.Band.low, .mid, .high] { to.eq.bands[band.rawValue].gain = 0 }
            to.eq.bands[DeckChain.Band.highPass.rawValue].bypass = true

            var restoringRate = false
            if case .beatMatched(let p) = planned.plan, abs(p.incomingRate - 1) > 0.001 {
                restoringRate = true
            } else {
                to.timePitch.rate = 1
            }

            // --- Settling, and the start of the ride release.
            //
            // `releaseRideLocked` fires the moment the overlap ends, so the
            // release clock starts here and keeps running *through* settling
            // and into the post-roll — in the live engine it is a deck-level
            // glide that outlives the transition entirely, and this is that
            // same envelope, stepped at the same 50 Hz.
            var sinceOverlap: TimeInterval = 0
            func rideStep() {
                guard rideDB != 0 else { return }
                to.setRide(db: TransitionAutomation.rideDB(
                    rideDB, secondsAfterOverlap: sinceOverlap))
            }

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
                    rideStep()
                    try pump(tickFrames)
                    written += tickFrames
                    settled += tickSeconds
                    sinceOverlap += tickSeconds
                }
                from.setFader(0)
                DeckChain.neutralize(timePitch: from.timePitch, eq: from.eq, delay: from.delay)
                to.timePitch.rate = 1
            }

            // --- Post-roll: the incoming track alone, still letting go of the
            // ride for as long as the release has left to run.
            var post: TimeInterval = 0
            while rideDB != 0, post < postRoll, sinceOverlap < rideRelease {
                rideStep()
                try pump(tickFrames)
                written += tickFrames
                post += tickSeconds
                sinceOverlap += tickSeconds
            }
            if rideDB != 0 { to.setRide(db: 0) }
            let postFrames = AVAudioFrameCount(
                (max(0, postRoll - post) * sampleRate).rounded())
            if postFrames > 0 {
                try pump(postFrames)
                written += postFrames
            }
        }

        // --- Blind-test normalization, then the one and only file write.
        let normalization = normalize(&mix, options: options)
        try write(mix, to: outputURL, format: engine.manualRenderingFormat,
                  sampleRate: sampleRate)

        let duration = Double(written) / sampleRate
        return Result(outputURL: outputURL, duration: duration,
                      overlapStart: overlapStart, overlapDuration: overlap,
                      renderSeconds: Date().timeIntervalSince(started),
                      outgoingTrimDB: options.outgoingTrimDB,
                      incomingTrimDB: options.incomingTrimDB,
                      rideDB: rideDB,
                      rideReleaseSeconds: rideRelease,
                      measuredLUFS: normalization.measuredLUFS,
                      normalizationGainDB: normalization.gainDB,
                      normalizationTargetLUFS: options.normalizeToLUFS,
                      stemTechnique: stemApplied?.technique.label,
                      stemSeconds: stemApplied?.seconds,
                      stemSeparatedSeconds: stemApplied?.separatedSeconds,
                      stemVocalEnergyRatio: stemApplied?.vocalEnergyRatio,
                      stemCacheHit: stemApplied?.cacheHit ?? false,
                      stemFallbackReason: stemFallback)
    }

    // MARK: - Output normalization and write-out

    /// Scale the finished mix to `options.normalizeToLUFS`, peak-guarded.
    ///
    /// Product-irrelevant by construction: this happens after both decks are
    /// summed, so it cannot change the *shape* of a transition, only how loud
    /// the resulting file plays. It exists so two renders put side by side in a
    /// blind test are compared on their hand-over rather than on their level
    /// (§2.4 of the research notes; Sony normalized their stimuli to −23 dBFS
    /// for exactly this reason). The live player does none of this.
    private static func normalize(
        _ mix: inout [[Float]], options: Options
    ) -> (measuredLUFS: Double?, gainDB: Double) {
        guard let target = options.normalizeToLUFS, !mix.isEmpty, !mix[0].isEmpty else {
            return (nil, 0)
        }
        // Measure on the mono downmix, matching how `referenceLoudness` is
        // measured (LoudnessMeter counts a mono signal as a centred pair).
        var mono = mix[0]
        if mix.count > 1 {
            for channel in 1..<mix.count {
                for i in 0..<mono.count { mono[i] += mix[channel][i] }
            }
            let scale = Float(mix.count)
            for i in 0..<mono.count { mono[i] /= scale }
        }
        guard let measured = LoudnessMeter.integratedLUFS(mono, sampleRate: DeckChain.format.sampleRate)
        else { return (nil, 0) }

        var gainDB = target - measured
        // Sony's clip guard (`utils_data_normalization.py:79-80`), here as a
        // cap on the gain rather than a rescale after the fact — same result,
        // one pass.
        if let peak = LoudnessMeter.peakDBFS(mix.flatMap { $0 }) {
            gainDB = min(gainDB, options.normalizePeakCeilingDBFS - peak)
        }
        let gain = LoudnessCompensation.gain(fromDB: gainDB)
        guard abs(gain - 1) > 1e-6 else { return (measured, 0) }
        for channel in 0..<mix.count {
            var scale = gain
            vDSP_vsmul(mix[channel], 1, &scale, &mix[channel], 1, vDSP_Length(mix[channel].count))
        }
        return (measured, gainDB)
    }

    /// Write the accumulated mix out as the 16-bit WAV callers expect.
    private static func write(_ mix: [[Float]], to outputURL: URL,
                              format: AVAudioFormat, sampleRate: Double) throws {
        let writer = try AVAudioFile(forWriting: outputURL,
                                     settings: wavSettings(sampleRate: sampleRate),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let frames = mix.first?.count, frames > 0 else { return }
        let chunkSize = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(chunkSize))
        else { throw RenderError.manualRenderingFailed }
        var offset = 0
        while offset < frames {
            let count = min(chunkSize, frames - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            if let data = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    let source = mix[min(channel, mix.count - 1)]
                    source.withUnsafeBufferPointer {
                        data[channel].update(from: $0.baseAddress! + offset, count: count)
                    }
                }
            }
            try writer.write(from: buffer)
            offset += count
        }
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

        /// Loudness-compensation multiplier; see `PlaybackEngine.DeckState.trim`.
        var trim: Float = 1
        /// Transition gain ride multiplier, and the last level a caller asked
        /// the fader for — the same pair `PlaybackEngine.DeckState` keeps, so
        /// changing the ride between automation ticks re-writes the fader
        /// through the current curve value rather than clobbering it.
        var ride: Float = 1
        var faderRequest: Float = 1

        /// The single fader writer, mirroring `PlaybackEngine.setFaderLocked`:
        /// callers speak in 0–1 and both gains are folded in here.
        func setFader(_ value: Float) {
            faderRequest = value
            player.volume = value * trim * ride
        }

        /// Move the ride and re-apply the fader through it.
        func setRide(db: Double) {
            ride = LoudnessCompensation.gain(fromDB: db)
            setFader(faderRequest)
        }

        func apply(_ p: TransitionAutomation.DeckParameters) {
            setFader(p.fader)
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
