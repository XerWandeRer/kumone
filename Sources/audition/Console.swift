#if os(macOS)
import Foundation
import KumoneCore

// `audition serve` — the tuning console's back end.
//
// Everything is one process on purpose. The planner is a pure function over
// two cached analyses, so re-deciding under a moved threshold costs a few
// milliseconds; keeping the HTTP server in the same binary means a slider
// drag round-trips faster than it takes to launch a second process. Renders
// are the only slow path, and they still run ~100× real time.

final class Console {
    let corpus: URL
    let stateDir: URL
    var renderDir: URL { stateDir.appendingPathComponent("renders") }
    var configDir: URL { stateDir.appendingPathComponent("configs") }

    private let lock = NSLock()
    /// Standard-config decisions for the corpus's adjacent pairs, so the
    /// batch view can highlight what a config change actually moved. Computed
    /// once, on first use.
    private var standardBatch: [[String: Any]]?

    init(corpus: URL, stateDir: URL) {
        self.corpus = corpus
        self.stateDir = stateDir
        for dir in [renderDir, configDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Corpus

    static let audioExtensions: Set<String> = ["flac", "mp3", "m4a", "wav", "aiff", "caf", "aac"]

    var tracks: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: corpus,
                                                       includingPropertiesForKeys: nil)) ?? [])
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every adjacent pair in filename order — the same 15 the `batch`
    /// command renders, so the console and the markdown report agree.
    var adjacentPairs: [(URL, URL)] {
        let files = tracks
        guard files.count >= 2 else { return [] }
        return Array(zip(files, files.dropFirst()))
    }

    // MARK: - Routing

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("HEAD", "/"):
            return .html(consolePage)
        case ("GET", "/api/bootstrap"):
            return bootstrap()
        case ("POST", "/api/plan"):
            return plan(request.json)
        case ("POST", "/api/batch"):
            return batch(request.json)
        case ("POST", "/api/render"):
            return render(request.json)
        case ("GET", "/api/configs"):
            return .json(["configs": savedConfigNames()])
        case ("POST", "/api/configs"):
            return saveConfig(request.json)
        default:
            if request.path.hasPrefix("/api/configs/") {
                let name = String(request.path.dropFirst("/api/configs/".count))
                if request.method == "GET" { return loadConfig(name) }
                if request.method == "DELETE" { return deleteConfig(name) }
            }
            if request.path.hasPrefix("/render/") {
                let name = String(request.path.dropFirst("/render/".count))
                guard !name.contains("/"), !name.contains("..") else {
                    return .error("bad render name", status: 400)
                }
                return FileServing.serve(renderDir.appendingPathComponent(name),
                                         request: request, contentType: "audio/wav")
            }
            return .error("no route for \(request.method) \(request.path)", status: 404)
        }
    }

    // MARK: - Bootstrap

    private func bootstrap() -> HTTPResponse {
        let encoder = JSONEncoder()
        let fields = (try? encoder.encode(Audition.configFields))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
        return .json([
            "corpus": corpus.path,
            "stateDir": stateDir.path,
            "tracks": tracks.map { ["name": $0.lastPathComponent, "path": $0.path] },
            "pairs": adjacentPairs.map { ["outgoing": $0.0.path, "incoming": $0.1.path] },
            "fields": fields,
            "standard": Audition.standardConfig,
            "styles": Audition.StyleOverride.allCases.map(\.rawValue),
            "configs": savedConfigNames(),
        ])
    }

    // MARK: - Plan

    /// `{outgoing, incoming, config: {name: value}, style?, fade?}`
    private func plan(_ body: [String: Any]) -> HTTPResponse {
        guard let a = body["outgoing"] as? String, let b = body["incoming"] as? String else {
            return .error("need outgoing and incoming paths")
        }
        do {
            let decision = try decide(outgoing: a, incoming: b, body: body)
            return .json(try Audition.reportJSON(decision))
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    private func decide(outgoing a: String, incoming b: String,
                        body: [String: Any]) throws -> Audition.Decision {
        let config = (body["config"] as? [String: Any] ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.doubleValue }
        var style: Audition.StyleOverride?
        if let raw = body["style"] as? String, !raw.isEmpty, raw != "auto" {
            style = Audition.StyleOverride(rawValue: raw)
        }
        let fade = (body["fade"] as? NSNumber)?.doubleValue
        return try Audition.decide(
            outgoing: expand(a), incoming: expand(b),
            style: style, fade: fade.flatMap { $0 > 0 ? $0 : nil },
            config: config)
    }

    private func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    // MARK: - Batch

    /// Run every adjacent corpus pair under the posted config and pair each
    /// row with what `.standard` would have decided, so the table can mark
    /// the rows a threshold move actually reclassified.
    private func batch(_ body: [String: Any]) -> HTTPResponse {
        let pairs = adjacentPairs
        guard !pairs.isEmpty else { return .error("corpus has fewer than two tracks") }

        let baseline = standardRows(pairs)
        var rows: [[String: Any]] = []
        for (index, pair) in pairs.enumerated() {
            guard var row = summarize(pair, body: body) else { continue }
            let base = index < baseline.count ? baseline[index] : [:]
            row["standard"] = base
            row["changed"] = ["tier", "plan", "style", "overlap"].contains {
                !equalField(row[$0], base[$0])
            }
            rows.append(row)
        }
        return .json(["pairs": rows])
    }

    private func equalField(_ a: Any?, _ b: Any?) -> Bool {
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = (a as? NSNumber)?.doubleValue, let y = (b as? NSNumber)?.doubleValue {
            return abs(x - y) < 0.005
        }
        return false
    }

    private func standardRows(_ pairs: [(URL, URL)]) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        if let standardBatch { return standardBatch }
        let rows = pairs.compactMap { summarize($0, body: [:]) }
        standardBatch = rows
        return rows
    }

    private func summarize(_ pair: (URL, URL), body: [String: Any]) -> [String: Any]? {
        guard let d = try? decide(outgoing: pair.0.path, incoming: pair.1.path, body: body)
        else { return nil }
        var row: [String: Any] = [
            "outgoing": d.outgoingName, "incoming": d.incomingName,
            "outgoingPath": pair.0.path, "incomingPath": pair.1.path,
            "tier": d.tier, "rawTier": d.rawTier, "plan": d.planKind,
            "style": d.styleDescription, "overlap": d.overlapDuration,
            "loudness": d.loudnessGapDB, "timbre": d.timbreDistance,
            "demotedByKey": d.demotedByKey,
            "nearMisses": d.nearMisses,
        ]
        if let t = d.tempoRatio { row["tempo"] = t }
        if let k = d.keyDistance { row["key"] = k }
        if let o = d.outPoint { row["outPoint"] = o }
        if let bars = d.overlapBars { row["bars"] = bars }
        return row
    }

    // MARK: - Render

    private func render(_ body: [String: Any]) -> HTTPResponse {
        guard let a = body["outgoing"] as? String, let b = body["incoming"] as? String else {
            return .error("need outgoing and incoming paths")
        }
        do {
            let decision = try decide(outgoing: a, incoming: b, body: body)
            // Name the file after everything that shapes it, so re-rendering
            // the same knobs reuses the WAV and the browser's audio element
            // does not refetch.
            var hasher = Hasher()
            hasher.combine(a); hasher.combine(b)
            hasher.combine(decision.styleDescription)
            hasher.combine(decision.overlapDuration)
            hasher.combine(decision.planKind)
            for (k, v) in decision.config.sorted(by: { $0.key < $1.key }) {
                hasher.combine(k); hasher.combine(v)
            }
            let name = String(format: "console-%016llx.wav", UInt64(bitPattern: Int64(hasher.finalize())))
            let out = renderDir.appendingPathComponent(name)
            let pre = (body["pre"] as? NSNumber)?.doubleValue ?? 12
            let post = (body["post"] as? NSNumber)?.doubleValue ?? 12

            if FileManager.default.fileExists(atPath: out.path),
               let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size])
                   as? Int, size > 1024 {
                return .json(["url": "/render/\(name)", "cached": true,
                              "overlapStart": pre,
                              "overlapDuration": decision.overlapDuration])
            }
            let r = try Audition.render(decision, to: out, preRoll: pre, postRoll: post)
            return .json(["url": "/render/\(name)", "cached": false,
                          "duration": r.duration,
                          "overlapStart": r.overlapStart,
                          "overlapDuration": r.overlapDuration,
                          "renderSeconds": r.renderSeconds,
                          "realtimeFactor": r.realtimeFactor])
        } catch {
            return .error("render failed: \(error.localizedDescription)", status: 500)
        }
    }

    // MARK: - Saved presets

    private func savedConfigNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: configDir,
                                                       includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    private func configURL(_ name: String) -> URL? {
        let safe = name.filter { $0.isLetter || $0.isNumber || "-_ ".contains($0) }
        guard !safe.isEmpty else { return nil }
        return configDir.appendingPathComponent(safe + ".json")
    }

    private func saveConfig(_ body: [String: Any]) -> HTTPResponse {
        guard let name = body["name"] as? String, let url = configURL(name),
              let config = body["config"] as? [String: Any]
        else { return .error("need a name and a config") }
        guard let data = try? JSONSerialization.data(withJSONObject: config,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return .error("config is not JSON") }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return .error("could not write \(url.path): \(error.localizedDescription)", status: 500)
        }
        return .json(["saved": url.deletingPathExtension().lastPathComponent,
                      "configs": savedConfigNames()])
    }

    private func loadConfig(_ name: String) -> HTTPResponse {
        guard let url = configURL(name), let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return .error("no saved config '\(name)'", status: 404) }
        return .json(["name": name, "config": object])
    }

    private func deleteConfig(_ name: String) -> HTTPResponse {
        guard let url = configURL(name) else { return .error("bad name") }
        try? FileManager.default.removeItem(at: url)
        return .json(["configs": savedConfigNames()])
    }
}
#endif
