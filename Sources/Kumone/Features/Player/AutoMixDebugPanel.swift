#if os(macOS)
import AppKit
import SwiftUI

// A developer window for listening tests: what AutoMix is doing, right now,
// without tailing a log while trying to hear a seam. macOS only — there is no
// AutoMix on iOS (every plan is `.gapless`), so there is nothing to watch.
//
// Deliberately **not** compiled out of release builds. The builds that go to
// the listening machine are made by `Scripts/build-app.sh`, which defaults to
// the `debug` configuration but is routinely run with `release` too, and a
// panel that vanishes depending on how the binary was built is a panel nobody
// trusts. It costs a closed window and one Bool test per playback tick; see
// `AutoMixDebugModel`.
//
// Labels are hardcoded English. The app is zh-Hans-first and every user-facing
// string is a Chinese key in `Localizable.strings`, so each label here goes
// through `Text(verbatim:)` — that is the convention-compliant way to say "this
// string is not for translation" rather than leaking developer jargon into the
// string tables.

struct AutoMixDebugPanel: View {

    static let windowID = "automix-debug"
    /// A `String` rather than a literal on purpose: `Window(_:id:)`'s literal
    /// overload takes a `LocalizedStringKey`, and this title must not become
    /// one of those keys.
    static let windowTitle = String("AutoMix Debug")
    /// Same reason: `CommandMenu`'s literal overload localizes its name.
    static let menuTitle = String("Debug")

    @ObservedObject private var model = AutoMixDebugModel.shared
    @State private var alwaysOnTop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nowGroup
                    nextGroup
                    planGroup
                    prerenderGroup
                    seamsGroup
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Toggle(isOn: $alwaysOnTop) { Text(verbatim: "Always on top") }
                    .toggleStyle(.checkbox)
                    .onChange(of: alwaysOnTop) { _, on in setFloating(on) }
                Spacer()
                Text(verbatim: "mirror of PlayerService — read only")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(minWidth: 420, minHeight: 460)
        // The model only publishes while a window is open; nothing ticks for a
        // panel nobody has asked for.
        .onAppear { model.activate() }
        .onDisappear {
            model.deactivate()
            alwaysOnTop = false
        }
    }

    // MARK: - Groups

    private var nowGroup: some View {
        let now = model.snapshot.now
        return DebugGroup("Now") {
            DebugRow("track", now.title ?? "—")
            DebugRow("phase", now.phase)
            DebugRow("deck", now.deck)
            DebugRow("position", "\(AutoMixDebugFormat.clock(now.position))"
                     + " / \(AutoMixDebugFormat.clock(now.duration))")
            DebugRow("trim", String(format: "%+.2f dB", now.trimDB))
            DebugRow("analysis", now.analyzed ? "in hand" : "none")
            deckRow("deck A", now.deckA)
            deckRow("deck B", now.deckB)
        }
    }

    /// One deck's rate and gain stages. The rate goes red when it is bent with
    /// no transition to account for it — that combination *is* the watery-
    /// playback bug, and it is the reason this row exists.
    private func deckRow(_ label: String, _ deck: AutoMixDebugDeck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(verbatim: String(format: "×%.4f", deck.rate))
                .fontWeight(deck.rateIsSuspect ? .bold : .regular)
                .foregroundStyle(deck.rateIsSuspect ? Color.red : Color.primary)
            Text(verbatim: String(format: "pad %+.2f · ride %+.2f · trim %+.2f dB · %@",
                                  deck.ratePadDB, deck.rideDB, deck.trimDB, deck.role))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var nextGroup: some View {
        let next = model.snapshot.next
        return DebugGroup("Next (prefetch)") {
            DebugRow("track", next.title ?? "—")
            DebugRow("stage", next.stage.label)
            if let bpm = next.bpm {
                DebugRow("bpm", String(format: "%.2f (conf %.2f)", bpm, next.bpmConfidence ?? 0))
            }
            if let key = next.key { DebugRow("key", key) }
            if let lufs = next.lufs {
                DebugRow("loudness", String(format: "%.1f LUFS", lufs))
            }
            if let count = next.sectionCount {
                DebugRow("sections", "\(count) (conf "
                         + String(format: "%.2f", next.structureConfidence ?? 0) + ")")
            }
            if next.title != nil {
                DebugRow(".lrc", next.hasLyricSidecar ? "present" : "missing")
            }
        }
    }

    @ViewBuilder
    private var planGroup: some View {
        DebugGroup("Plan (armed)") {
            forceBeatMatchControl
            Divider().padding(.vertical, 2)
            if let plan = model.snapshot.plan {
                DebugRow("kind", plan.kind)
                DebugRow("out point", AutoMixDebugFormat.clock(plan.outPoint)
                         + (plan.outPoint.map { String(format: " (%.2fs)", $0) } ?? ""))
                DebugRow("in point", plan.inPoint.map { String(format: "%.2fs", $0) } ?? "—")
                DebugRow("overlap", String(format: "%.2fs", plan.overlap)
                         + (plan.overlapBars.map { " / \($0) bars" } ?? ""))
                if let out = plan.outgoingRate, let incoming = plan.incomingRate {
                    DebugRow("rates", String(format: "out ×%.4f · in ×%.4f", out, incoming))
                }
                DebugRow("style", plan.outroEffect
                         + (plan.stagedEQ ? " · stagedEQ" : "")
                         + (plan.stemTechnique.map { " · \($0)" } ?? ""))
                DebugRow("ride", String(format: "%+.2f dB", plan.rideDB))
                DebugRow("out section", plan.outSection ?? "no structure")
                DebugRow("in source", plan.inPointSource ?? "—")
                DebugRow("countdown", countdown(to: plan.outPoint))
            } else {
                DebugRow("state", "nothing armed")
            }
        }
    }

    /// The one control on this panel that *changes* what the player does, so it
    /// is labelled as an override and badged while it is on — a listening note
    /// must never record a forced beat match as an organic one.
    @ViewBuilder
    private var forceBeatMatchControl: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { model.forceBeatMatch },
                                     set: { PlayerService.shared.setForceBeatMatch($0) })) {
                    Text(verbatim: "Force beat switch (debug override)")
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 0)
                if model.forceBeatMatch {
                    Text(verbatim: "OVERRIDE ACTIVE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25),
                                    in: RoundedRectangle(cornerRadius: 3))
                }
            }
            if model.forceBeatMatch {
                DebugRow("gates", "loudness / timbre / tempo-clash / key / vocal-clash: off")
                DebugRow("window", String(
                    format: "bpm Δ ≤ %.0f %% · rate ≤ ±%.0f %%",
                    AutoMixDebugOverrides.forcedBPMDeltaCap * 100,
                    AutoMixDebugOverrides.forcedRateCap * 100))
                if let note = model.snapshot.forceNote {
                    Text(verbatim: note)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var prerenderGroup: some View {
        DebugGroup("Stem pre-render") {
            DebugRow("state", model.snapshot.prerender.label)
        }
    }

    private var seamsGroup: some View {
        DebugGroup("Last transitions") {
            if model.snapshot.seams.isEmpty {
                DebugRow("state", "none this session")
            } else {
                ForEach(model.snapshot.seams) { seam in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(seam.from ?? "—")  →  \(seam.to ?? "—")")
                            .fontWeight(.semibold)
                        DebugRow("path", seam.path)
                        DebugRow("executed", "\(seam.executedKind) · out "
                                 + AutoMixDebugFormat.clock(seam.executedOutPoint)
                                 + String(format: " · overlap %.2fs", seam.executedOverlap))
                        DebugRow("planned", seam.planned.map {
                            "\($0.kind) · out " + AutoMixDebugFormat.clock($0.outPoint)
                                + String(format: " · overlap %.2fs", $0.overlap)
                                + ($0.stemTechnique.map { " · \($0)" } ?? "")
                        } ?? "—")
                        DebugRow("fallback", seam.fallback ?? "none — ran as planned")
                        DebugRow("pre-render", seam.prerender)
                    }
                    .padding(.vertical, 3)
                    if seam.id != model.snapshot.seams.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: - Helpers

    /// "T−mm:ss to out point", or why there is no countdown to give.
    private func countdown(to outPoint: TimeInterval?) -> String {
        guard let outPoint else { return "— (no out point: gapless)" }
        let remaining = outPoint - model.snapshot.now.position
        guard remaining > 0 else { return "T+00:00 (out point passed)" }
        return String(format: "T−%02d:%02d", Int(remaining) / 60, Int(remaining) % 60)
    }

    /// SwiftUI has no window-level API, so the pin goes through AppKit — the
    /// same way `DesktopLyrics` floats its overlay.
    private func setFloating(_ on: Bool) {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(Self.windowID) ?? false
        }) else { return }
        window.level = on ? .floating : .normal
    }
}

private struct DebugGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct DebugRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(verbatim: value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
#endif
