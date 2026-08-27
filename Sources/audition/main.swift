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
  audition plan   <fileA> <fileB> [--json] [--stems on|off] [--set name=value,...]
  audition render <fileA> <fileB> [-o out.wav] [--style plain|sweep|echo|staged] [--fade N]
                                  [--stem acapella|instrumental|duck[:9]]
                                  [--pre N] [--post N] [--set name=value,...]
  audition batch  <corpusDir> [-o outDir] [--pairs a.flac:b.flac,...]
                              [--style ...] [--fade N] [--pre N] [--post N]
                              [--set name=value,...]
  audition serve  [--corpus DIR] [--port 8766] [--host 127.0.0.1,10.147.19.10]
                  [--state DIR]
  audition knobs  [--json]

  --style   force one technique, to hear it in isolation
  --stems   on|off (default off) — tell the planner a vocal separator is
            available, so it may choose vocalDuck / acapellaOver itself. Off is
            the product default and reproduces the pre-stem decision exactly.
  --stem    layer a stem technique on top of the chosen style (render only):
            acapella      the outgoing vocal floats over the incoming mix
            instrumental  the outgoing vocal is wiped, it leaves instrumental
            duck[:9]      the outgoing vocal held N dB down (default 9)
            First use downloads a 64 MiB model; the separated window is cached
            beside the audio as <file>.stems-v1-<start>-<len>.caf.
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
    // The gap above is post-compensation; show what produced it.
    lines.append("  loudness      \(optional(d.outgoingLoudnessLUFS, 1)) →"
                 + " \(optional(d.incomingLoudnessLUFS, 1)) LUFS"
                 + "   trim \(f(d.outgoingTrimDB)) / \(f(d.incomingTrimDB)) dB"
                 + "  (raw gap \(f(d.rawLoudnessGapDB)) dB)")
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
    if d.stemsReady {
        var stemLine = "  stems on      "
        if let technique = d.plannedStemTechnique {
            stemLine += "planner chose \(technique)"
            if let base = d.stemBaselineOutPoint, let baseOverlap = d.stemBaselineOverlap {
                stemLine += "  (without stems: out @ \(mmss(base)),"
                    + " overlap \(f(baseOverlap))s)"
            }
        } else {
            stemLine += "planner chose no stem technique"
                + "   [needs outgoing vocals > \(f(th("stemVocalActiveRatio")))"
                + " and either incoming > \(f(th("vocalClashRatio")))"
                + " (duck) or ≤ \(f(th("stemAcapellaIncomingVocalMax"))) at compatible (acapella)]"
        }
        lines.append(stemLine)
    }
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
    var stem: Audition.StemOverride?
    if let raw = args.flags["stem"], raw != "true" {
        guard let parsed = Audition.StemOverride.parse(raw) else {
            fail("unknown --stem '\(raw)'; expected one of "
                 + Audition.StemOverride.names.joined(separator: "|") + " (duck takes :N dB)")
        }
        stem = parsed
    }
    let stems: StemAvailability
    switch args.flags["stems"] ?? "off" {
    case "on", "ready", "true": stems = .ready
    case "off", "none", "false": stems = .none
    case let raw: fail("unknown --stems '\(raw)'; expected on|off")
    }
    for file in [a, b] where !Audition.hasCachedAnalysis(for: file) {
        FileHandle.standardError.write(Data("  analyzing \(file.lastPathComponent)…\n".utf8))
    }
    do {
        return try Audition.decide(outgoing: a, incoming: b,
                                   style: style, fade: args.double("fade"), stem: stem,
                                   stems: stems,
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
        let r = try Audition.render(d, to: out, preRoll: opts.pre, postRoll: opts.post,
                                    stemProvider: StemService.shared.provider)
        var stemLine = ""
        if let technique = r.stemTechnique {
            stemLine = "\n    stem \(technique) — separated "
                + "\(f(r.stemSeparatedSeconds ?? 0, 1))s in \(f(r.stemSeconds ?? 0))s"
                + (r.stemCacheHit ? " (cached)" : "")
                + ", vocal/mix \(f(r.stemVocalEnergyRatio ?? 0, 3))"
            if (r.stemVocalEnergyRatio ?? 0) < 0.02 {
                stemLine += "\n    ⚠︎ that window is instrumental — the technique had no vocal"
                    + " to act on, so this will sound like the plain render"
            }
        }
        if let reason = r.stemFallbackReason {
            stemLine = "\n    stem NOT applied, rendered whole-mix: \(reason)"
        }
        // Blind-test level matching, applied to the finished file only.
        var normLine = ""
        if let target = r.normalizationTargetLUFS {
            normLine = "\n    blind-test normalization "
                + "\(optional(r.measuredLUFS, 1)) → \(f(target, 1)) LUFS "
                + "(\(f(r.normalizationGainDB)) dB applied to the file)"
        }
        print("""

          wrote \(r.outputURL.path)
            \(f(r.duration))s of audio, hand-over at \(mmss(r.overlapStart)) \
          (overlap \(f(r.overlapDuration))s)
            rendered in \(f(r.renderSeconds))s — \(f(r.realtimeFactor, 1))× real time
            deck trims \(f(r.outgoingTrimDB)) / \(f(r.incomingTrimDB)) dB (as the player would)\(normLine)\(stemLine)
            afplay \(r.outputURL.path)
          """)
    } catch {
        fail("render failed: \(error.localizedDescription)")
    }
}

func runBatch(_ args: Arguments) {
    guard let dirArg = args.positional.first else { fail(usage) }
    // A stem render costs a model pass per pair; a corpus sweep is for
    // comparing planner decisions, not for auditioning one technique.
    var args = args
    if args.flags.removeValue(forKey: "stem") != nil {
        FileHandle.standardError.write(
            Data("audition: --stem is ignored by batch; use render for stem techniques\n".utf8))
    }
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
            // `render --stem` leaves vocal-stem sidecars in the corpus; they
            // are cache, not material.
            .filter { !StemService.isStemSidecar($0) }
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
                    + " | \(f(d.loudnessGapDB)) | \(f(d.rawLoudnessGapDB))"
                    + " | \(f(d.outgoingTrimDB))/\(f(d.incomingTrimDB))"
                    + " | \(f(d.timbreDistance, 3))"
                    + " | \(optional(d.tempoRatio, 3)) | \(d.keyDistance.map(String.init) ?? "—")"
                    + " | \(optional(d.outgoingVocalScore))/\(optional(d.incomingVocalScore))"
                    + " | \(d.planKind) | \(d.styleDescription)"
                    + " | \(d.plannedStemTechnique ?? "—")"
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
    if decisions.contains(where: \.stemsReady) {
        summary.append(histogram("Planner-chosen stem technique",
                                 tally { $0.plannedStemTechnique ?? "(none)" }))
    }
    summary.append("**Overlap length** — \(fadeSummary)\n")

    // Loudness compensation: what the per-track trims did to the gap the tier
    // gate reads, and how far the trims had to reach.
    func spread(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "n/a" }
        let sorted = xs.sorted()
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        return "min \(f(sorted.first!)) · median \(f(sorted[sorted.count / 2])) · "
            + "mean \(f(mean)) · max \(f(sorted.last!))"
    }
    let rawGaps = decisions.map(\.rawLoudnessGapDB)
    let gaps = decisions.map(\.loudnessGapDB)
    let trims = decisions.flatMap { [$0.outgoingTrimDB, $0.incomingTrimDB] }
    summary.append("**Loudness gap (dB)** — before compensation: \(spread(rawGaps))")
    summary.append("")
    summary.append("**Loudness gap (dB)** — after compensation (what the tier gate reads): "
                   + "\(spread(gaps))")
    summary.append("")
    summary.append("**Per-track playback trim (dB)** — \(spread(trims))")
    summary.append("")
    let neutralLine = Audition.standardConfig["neutralLoudnessDB"] ?? 0
    let clashLine = Audition.standardConfig["clashLoudnessDB"] ?? 0
    func over(_ xs: [Double], _ line: Double) -> Int { xs.filter { $0 > line }.count }
    summary.append("**Pairs the loudness signal alone would demote** — "
                   + "over the tolerance line (\(f(neutralLine, 1)) dB): "
                   + "\(over(rawGaps, neutralLine)) → \(over(gaps, neutralLine)); "
                   + "over the red line (\(f(clashLine, 1)) dB): "
                   + "\(over(rawGaps, clashLine)) → \(over(gaps, clashLine))")
    summary.append("")
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
        "| pair | tier | loudness dB | raw loudness dB | trim out/in dB "
            + "| timbre | tempo | key | vocals out/in "
            + "| plan | style | stem | overlap | out point | render |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
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
