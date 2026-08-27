#if os(macOS)
import Foundation
import KumoneCore

// AutoMix tuning loop, offline. See docs/audition.md.
//
//   swift run audition plan   <fileA> <fileB>
//   swift run audition render <fileA> <fileB> [-o out.wav] [--style …] [--fade N]
//   swift run audition batch  <corpusDir> [-o outDir] [--pairs a.flac:b.flac,…]

// MARK: - Argument plumbing

struct Arguments {
    var positional: [String] = []
    var flags: [String: String] = [:]

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let token = raw[i]
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    flags[String(name[name.startIndex..<eq])] = String(name[name.index(after: eq)...])
                } else if i + 1 < raw.count, !raw[i + 1].hasPrefix("-") {
                    flags[name] = raw[i + 1]
                    i += 1
                } else {
                    flags[name] = "true"
                }
            } else if token == "-o", i + 1 < raw.count {
                flags["output"] = raw[i + 1]
                i += 1
            } else {
                positional.append(token)
            }
            i += 1
        }
    }

    func double(_ name: String) -> Double? { flags[name].flatMap(Double.init) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("audition: " + message + "\n").utf8))
    exit(1)
}

func url(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

let usage = """
usage:
  audition plan   <fileA> <fileB> [--json] [--set name=value,...]
  audition render <fileA> <fileB> [-o out.wav] [--style plain|sweep|echo|staged] [--fade N]
                                  [--pre N] [--post N] [--set name=value,...]
  audition batch  <corpusDir> [-o outDir] [--pairs a.flac:b.flac,...]
                              [--style ...] [--fade N] [--pre N] [--post N]
                              [--set name=value,...]
  audition serve  [--corpus DIR] [--port 8766] [--host 127.0.0.1,10.147.19.10]
                  [--state DIR]
  audition knobs  [--json]

  --style   force one technique, to hear it in isolation
  --fade    override the overlap length (seconds)
  --pre/--post  context before / after the hand-over (default 12s each)
  --json    print the full decision — signals, thresholds, derivation chain — as JSON
  --set     override planner thresholds for this run, e.g.
            --set clashTimbreDistance=0.35,neutralLoudnessDB=4
            (`audition knobs` lists every name and its range)
"""

// MARK: - Formatting

func f(_ v: Double, _ digits: Int = 2) -> String {
    String(format: "%.\(digits)f", v)
}

func optional(_ v: Double?, _ digits: Int = 2) -> String {
    v.map { f($0, digits) } ?? "—"
}

func mmss(_ t: TimeInterval) -> String {
    String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}

/// The "why did this pair get this transition" block. Every threshold quoted
/// comes from the decision's own config, so a `--set` run explains itself
/// against the lines it actually used.
func explain(_ d: Audition.Decision) -> String {
    func th(_ name: String) -> Double { d.config[name] ?? 0 }
    var lines: [String] = []
    lines.append("\(d.outgoingName)  →  \(d.incomingName)")
    lines.append("  tier          \(d.tier)"
                 + (d.demotedByKey ? "  (demoted from compatible by the key gate)" : ""))
    lines.append("  loudness gap  \(f(d.loudnessGapDB)) dB"
                 + "   [neutral > \(f(th("neutralLoudnessDB"), 1)),"
                 + " clash > \(f(th("clashLoudnessDB"), 1))]")
    lines.append("  timbre dist   \(f(d.timbreDistance, 3))"
                 + "      [neutral > \(f(th("neutralTimbreDistance"), 2)),"
                 + " clash > \(f(th("clashTimbreDistance"), 2))]")
    let bpm = "\(f(d.outgoingBPM, 1)) → \(f(d.incomingBPM, 1)) BPM"
        + " (conf \(f(d.outgoingBPMConfidence)) / \(f(d.incomingBPMConfidence)))"
    lines.append("  tempo         \(optional(d.tempoRatio, 3)) folded"
                 + "   [beat-match ≤ \(f(th("maxBPMDeltaRatio"), 2)),"
                 + " clash > \(f(th("clashTempoRatio"), 2))]  \(bpm)")
    lines.append("  key distance  \(d.keyDistance.map(String.init) ?? "—")"
                 + "           [demotes at ≥ \(Int(th("clashKeyDistance"))) fifths]")
    lines.append("  vocals        out \(optional(d.outgoingVocalScore))"
                 + " / in \(optional(d.incomingVocalScore))"
                 + "   [both > \(f(th("vocalClashRatio"), 2)) = clash]")
    var mechanics = "  → \(d.planKind), \(d.styleDescription)"
    if d.overlapDuration > 0 {
        mechanics += ", overlap \(f(d.overlapDuration))s"
        if let bars = d.overlapBars { mechanics += " (\(bars) bars)" }
    }
    if let outPoint = d.outPoint { mechanics += ", out @ \(mmss(outPoint))" }
    if let inPoint = d.inPoint { mechanics += ", in @ \(mmss(inPoint))" }
    if let outRate = d.outgoingRate, let inRate = d.incomingRate {
        mechanics += String(format: ", rates %.4f/%.4f", outRate, inRate)
    }
    if d.overridden { mechanics += "  [OVERRIDDEN by --style/--fade]" }
    lines.append(mechanics)
    for miss in d.nearMisses {
        lines.append("  ⚠︎ borderline: \(miss)")
    }
    return lines.joined(separator: "\n")
}

/// `--set name=value,name=value` — the CLI's door onto the same knobs the
/// console's sliders move.
func configOverrides(_ args: Arguments) -> [String: Double] {
    guard let spec = args.flags["set"], spec != "true" else { return [:] }
    let known = Set(Audition.configFields.map(\.name))
    var out: [String: Double] = [:]
    for entry in spec.split(separator: ",") {
        let kv = entry.split(separator: "=", maxSplits: 1)
        guard kv.count == 2, let value = Double(kv[1]) else {
            fail("bad --set entry '\(entry)', expected name=value")
        }
        let name = String(kv[0])
        guard known.contains(name) else {
            fail("unknown knob '\(name)'; run `audition knobs` for the list")
        }
        out[name] = value
    }
    return out
}

func decide(_ args: Arguments, a: URL, b: URL) -> Audition.Decision {
    var style: Audition.StyleOverride?
    if let raw = args.flags["style"] {
        guard let parsed = Audition.StyleOverride(rawValue: raw) else {
            fail("unknown --style '\(raw)'; expected one of "
                 + Audition.StyleOverride.allCases.map(\.rawValue).joined(separator: "|"))
        }
        style = parsed
    }
    for file in [a, b] where !Audition.hasCachedAnalysis(for: file) {
        FileHandle.standardError.write(Data("  analyzing \(file.lastPathComponent)…\n".utf8))
    }
    do {
        return try Audition.decide(outgoing: a, incoming: b,
                                   style: style, fade: args.double("fade"),
                                   config: configOverrides(args))
    } catch {
        fail("\(a.lastPathComponent) → \(b.lastPathComponent): \(error.localizedDescription)")
    }
}

func renderOptions(_ args: Arguments) -> (pre: TimeInterval, post: TimeInterval) {
    (args.double("pre") ?? 12, args.double("post") ?? 12)
}

// MARK: - Commands

func runPlan(_ args: Arguments) {
    guard args.positional.count == 2 else { fail(usage) }
    let d = decide(args, a: url(args.positional[0]), b: url(args.positional[1]))
    if args.flags["json"] != nil {
        guard let data = try? Audition.reportJSON(d) else { fail("could not encode the report") }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        print(explain(d))
    }
}

/// Every tunable, so `--set` names and console sliders are discoverable from
/// the terminal too.
func runKnobs(_ args: Arguments) {
    if args.flags["json"] != nil {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Audition.configFields) else { fail("encode failed") }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return
    }
    var group = ""
    for field in Audition.configFields {
        if field.group != group {
            group = field.group
            print("\n[\(group)]")
        }
        let name = field.name.padding(toLength: max(26, field.name.count + 2),
                                      withPad: " ", startingAt: 0)
        print("  \(name)\(f(field.standard, field.digits))"
              + "   [\(f(field.min, field.digits))…\(f(field.max, field.digits))]")
        print("      \(field.blurb)")
    }
}

func runServe(_ args: Arguments) {
    let corpus = url(args.flags["corpus"] ?? args.positional.first
                     ?? "~/Developer/kumone-audition-corpus")
    guard FileManager.default.fileExists(atPath: corpus.path) else {
        fail("no such corpus directory: \(corpus.path)")
    }
    let state = url(args.flags["state"] ?? corpus.appendingPathComponent("console").path)
    let port = UInt16(args.flags["port"].flatMap(Int.init) ?? 8766)
    let hosts = (args.flags["host"] ?? "127.0.0.1,10.147.19.10")
        .split(separator: ",").map(String.init)

    let console = Console(corpus: corpus, stateDir: state)
    let server = HTTPServer { console.handle($0) }
    let bound = server.listen(on: hosts, port: port)
    guard !bound.isEmpty else { fail("could not bind any of \(hosts.joined(separator: ", "))") }

    print("""
      AutoMix 决策台
        corpus  \(corpus.path)  (\(console.tracks.count) tracks, \
      \(console.adjacentPairs.count) adjacent pairs)
        state   \(state.path)
      \(bound.map { "  http://\($0):\(port)/" }.joined(separator: "\n"))
      """)
    fflush(stdout)
    dispatchMain()
}

func runRender(_ args: Arguments) {
    guard args.positional.count == 2 else { fail(usage) }
    let a = url(args.positional[0]), b = url(args.positional[1])
    let d = decide(args, a: a, b: b)
    print(explain(d))
    let out = url(args.flags["output"] ?? "transition.wav")
    try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let opts = renderOptions(args)
    do {
        let r = try Audition.render(d, to: out, preRoll: opts.pre, postRoll: opts.post)
        print("""

          wrote \(r.outputURL.path)
            \(f(r.duration))s of audio, hand-over at \(mmss(r.overlapStart)) \
          (overlap \(f(r.overlapDuration))s)
            rendered in \(f(r.renderSeconds))s — \(f(r.realtimeFactor, 1))× real time
            afplay \(r.outputURL.path)
          """)
    } catch {
        fail("render failed: \(error.localizedDescription)")
    }
}

func runBatch(_ args: Arguments) {
    guard let dirArg = args.positional.first else { fail(usage) }
    let corpus = url(dirArg)
    let outDir = url(args.flags["output"] ?? corpus.appendingPathComponent("renders").path)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    // Pairs: either an explicit --pairs list, or every adjacent pair in
    // filename order (so a corpus gives N-1 hand-overs deterministically).
    var pairs: [(URL, URL)] = []
    if let spec = args.flags["pairs"] {
        for entry in spec.split(separator: ",") {
            let sides = entry.split(separator: ":")
            guard sides.count == 2 else { fail("bad --pairs entry '\(entry)', expected a:b") }
            pairs.append((corpus.appendingPathComponent(String(sides[0])),
                          corpus.appendingPathComponent(String(sides[1]))))
        }
    } else {
        let audioExtensions: Set<String> = ["flac", "mp3", "m4a", "wav", "aiff", "caf", "aac"]
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: corpus, includingPropertiesForKeys: nil)) ?? [])
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count >= 2 else { fail("need at least two audio files in \(corpus.path)") }
        pairs = zip(files, files.dropFirst()).map { ($0, $1) }
    }

    var rows: [String] = []
    var decisions: [Audition.Decision] = []
    var renderFactors: [Double] = []

    for (index, pair) in pairs.enumerated() {
        let d = decide(args, a: pair.0, b: pair.1)
        decisions.append(d)
        let name = String(format: "%02d-%@__%@.wav", index + 1,
                          pair.0.deletingPathExtension().lastPathComponent,
                          pair.1.deletingPathExtension().lastPathComponent)
        let out = outDir.appendingPathComponent(name)
        let opts = renderOptions(args)
        var rendered = "—"
        do {
            let r = try Audition.render(d, to: out, preRoll: opts.pre, postRoll: opts.post)
            renderFactors.append(r.realtimeFactor)
            rendered = "[\(name)](\(name)) @ \(mmss(r.overlapStart))"
            print("[\(index + 1)/\(pairs.count)] \(name)  "
                  + "\(d.tier)/\(d.planKind)/\(d.styleDescription)  "
                  + "\(f(r.realtimeFactor, 1))×")
        } catch {
            rendered = "render failed: \(error.localizedDescription)"
            print("[\(index + 1)/\(pairs.count)] \(name)  RENDER FAILED: "
                  + error.localizedDescription)
        }
        rows.append("| \(d.outgoingName) → \(d.incomingName) | \(d.tier)"
                    + (d.demotedByKey ? " (key)" : "")
                    + " | \(f(d.loudnessGapDB)) | \(f(d.timbreDistance, 3))"
                    + " | \(optional(d.tempoRatio, 3)) | \(d.keyDistance.map(String.init) ?? "—")"
                    + " | \(optional(d.outgoingVocalScore))/\(optional(d.incomingVocalScore))"
                    + " | \(d.planKind) | \(d.styleDescription)"
                    + " | \(f(d.overlapDuration))s"
                    + " | \(d.outPoint.map(mmss) ?? "—") | \(rendered) |")
    }

    // Distribution: the thing to look at first after moving a threshold.
    func histogram(_ title: String, _ counts: [(String, Int)]) -> String {
        var out = ["**\(title)**", ""]
        for (label, count) in counts where count > 0 {
            out.append("- `\(label)`: \(count)  \(String(repeating: "█", count: count))")
        }
        out.append("")
        return out.joined(separator: "\n")
    }
    func tally(_ key: (Audition.Decision) -> String) -> [(String, Int)] {
        Dictionary(grouping: decisions, by: key)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    let fades = decisions.map(\.overlapDuration).sorted()
    let fadeSummary: String
    if fades.isEmpty {
        fadeSummary = "n/a"
    } else {
        let mean = fades.reduce(0, +) / Double(fades.count)
        fadeSummary = "min \(f(fades.first!))s · median \(f(fades[fades.count / 2]))s · "
            + "mean \(f(mean))s · max \(f(fades.last!))s"
    }

    var summary = ["## Distribution", ""]
    summary.append(histogram("Tier", tally { $0.tier }))
    summary.append(histogram("Plan", tally { $0.planKind }))
    summary.append(histogram("Style", tally { $0.styleDescription }))
    summary.append("**Overlap length** — \(fadeSummary)\n")
    let borderline = decisions.filter { !$0.nearMisses.isEmpty }
    if !borderline.isEmpty {
        summary.append("**Borderline pairs** (a threshold nudge would reclassify these)\n")
        for d in borderline {
            for miss in d.nearMisses {
                summary.append("- \(d.outgoingName) → \(d.incomingName): \(miss)")
            }
        }
        summary.append("")
    }
    if !renderFactors.isEmpty {
        let mean = renderFactors.reduce(0, +) / Double(renderFactors.count)
        summary.append("**Offline render speed** — \(f(renderFactors.min()!, 1))×–"
                       + "\(f(renderFactors.max()!, 1))× real time (mean \(f(mean, 1))×)\n")
    }

    let document = ([
        "# AutoMix transition decisions",
        "",
        "Corpus: `\(corpus.path)` · \(pairs.count) pairs · "
            + "generated \(ISO8601DateFormatter().string(from: Date()))",
        "",
        summary.joined(separator: "\n"),
        "## Per-pair decisions",
        "",
        "| pair | tier | loudness dB | timbre | tempo | key | vocals out/in "
            + "| plan | style | overlap | out point | render |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|",
    ] + rows).joined(separator: "\n") + "\n"

    let docURL = outDir.appendingPathComponent("decisions.md")
    do {
        try document.write(to: docURL, atomically: true, encoding: .utf8)
    } catch {
        fail("could not write \(docURL.path): \(error.localizedDescription)")
    }
    print("\n" + summary.joined(separator: "\n"))
    print("wrote \(docURL.path)")
}

// MARK: - Entry

let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else { fail(usage) }
let args = Arguments(Array(raw.dropFirst()))

switch command {
case "plan": runPlan(args)
case "render": runRender(args)
case "batch": runBatch(args)
case "serve": runServe(args)
case "knobs": runKnobs(args)
case "-h", "--help", "help": print(usage)
default: fail("unknown command '\(command)'\n\n" + usage)
}

#else
import Foundation
FileHandle.standardError.write(Data("audition is macOS-only\n".utf8))
exit(1)
#endif
