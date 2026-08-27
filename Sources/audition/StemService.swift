#if os(macOS)
import AVFoundation
import Foundation
import KumoneCore
import StemKit

// The `audition` side of the stem layer: hold one warm separator, cache what it
// produces next to the corpus, and hand `OfflineTransitionRenderer` a plain
// closure. KumoneCore never learns that MLX exists.
//
// Two costs shape this file:
//   - loading + warming the 64 MiB checkpoint is a one-off several seconds, so
//     the separator is process-resident and prepared at most once;
//   - separating a 12-second overlap window is ~6 s on an M4, so the result is
//     written to a sidecar and a re-render of the same window is instant.
final class StemService: @unchecked Sendable {

    static let shared = StemService()

    /// Bump when anything that changes the stem's *content* changes — the
    /// checkpoint, the resampling, the window convention. Stale sidecars are
    /// then simply never looked up rather than silently reused.
    static let cacheVersion = 1

    /// Marks a stem sidecar in a filename. Sidecars live *next to* the audio
    /// they came from and are themselves audio files, so anything that walks a
    /// corpus directory has to skip them — otherwise a six-second vocal stem
    /// shows up in the console's track list as if it were a song.
    static let cacheMarker = ".stems-v"

    static func isStemSidecar(_ url: URL) -> Bool {
        url.lastPathComponent.contains(cacheMarker)
    }

    private let lock = NSLock()
    private var separator: StemSeparator?

    /// What the renderer takes: `(window) throws -> vocal stem`.
    var provider: VocalStemProvider {
        { [self] request in try vocals(for: request) }
    }

    /// Report a stage change (`"separating"` / `"rendering"`) — the console
    /// wires its polling progress line to this.
    static func stageReporting(_ base: @escaping VocalStemProvider,
                               onSeparating: @escaping @Sendable (Bool) -> Void)
        -> VocalStemProvider {
        { request in
            onSeparating(true)
            defer { onSeparating(false) }
            return try base(request)
        }
    }

    // MARK: - Provider

    private func vocals(for request: VocalStemRequest) throws -> VocalStem {
        let cache = cacheURL(for: request)
        if let cached = readCache(cache, channels: request.samples.count,
                                  frames: request.samples.first?.count ?? 0,
                                  sampleRate: request.sampleRate) {
            return VocalStem(channels: cached, cached: true)
        }
        let separator = try residentSeparator()
        let stems = try runBlocking {
            try await separator.separate(samples: request.samples,
                                         sampleRate: request.sampleRate)
        }
        writeCache(cache, channels: stems.vocals, sampleRate: request.sampleRate)
        return VocalStem(channels: stems.vocals, cached: false)
    }

    private func residentSeparator() throws -> StemSeparator {
        lock.lock()
        let existing = separator
        lock.unlock()
        if let existing { return existing }

        let prepared = try runBlocking { try await StemSeparator.prepare() }
        lock.lock()
        // Two renders racing here is harmless — the loser's copy is dropped.
        if let existing = separator {
            lock.unlock()
            return existing
        }
        separator = prepared
        lock.unlock()
        return prepared
    }

    // MARK: - Sidecar cache

    /// `<audio file>.stems-v1-<startMs>-<durationMs>.caf`, holding the vocal
    /// stem only: the accompaniment is `mixture − vocals`, so storing it too
    /// would double the disk for nothing. The window bounds are in the name, so
    /// a different cue point simply misses instead of returning the wrong
    /// audio, and `rm *.stems-*` clears the lot.
    private func cacheURL(for request: VocalStemRequest) -> URL {
        let start = Int((request.start * 1000).rounded())
        let duration = Int((request.duration * 1000).rounded())
        return URL(fileURLWithPath: request.source.path
                   + "\(Self.cacheMarker)\(Self.cacheVersion)-\(start)-\(duration).caf")
    }

    private func readCache(_ url: URL, channels: Int, frames: Int,
                           sampleRate: Double) -> [[Float]]? {
        guard frames > 0, FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard Int(format.channelCount) == channels,
              format.sampleRate == sampleRate,
              file.length == AVAudioFramePosition(frames),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              (try? file.read(into: buffer)) != nil,
              buffer.frameLength == AVAudioFrameCount(frames),
              let data = buffer.floatChannelData
        else { return nil }
        return (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
    }

    private func writeCache(_ url: URL, channels: [[Float]], sampleRate: Double) {
        guard let frames = channels.first?.count, frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels.count)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames)
            }
        }
        // Float CAF: lossless, and the stem is an intermediate — quantising it
        // to 16 bit here would show up in the acapella, which gets boosted.
        var settings = format.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    // MARK: - async → sync

    /// The renderer is a synchronous pull loop and the separator is `async`.
    /// Bridging here (rather than making the renderer async) keeps the offline
    /// graph exactly the shape the live engine's is. Only ever called off the
    /// main thread — the CLI blocks its own entry point, the console runs
    /// renders on a serial background queue.
    private func runBlocking<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<T, Error>?
        Task.detached(priority: .userInitiated) {
            do { outcome = .success(try await body()) } catch { outcome = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        switch outcome! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
#endif
