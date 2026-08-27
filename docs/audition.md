# `audition` — the offline AutoMix tuning loop

Tuning a transition used to mean: change a constant → build the app → deploy it
→ find a playlist that happens to trigger the case you changed → wait for the
song to end. Ten-plus minutes per iteration, on material you don't control.

`audition` replaces that with:

```
change a constant  →  swift run audition batch …  →  read the distribution
                   →  afplay the two or three pairs that matter  →  decide
```

Seconds per iteration, on a fixed corpus, reproducible A/B.

---

## The loop

### 1. Change a constant

Two files hold everything worth turning:

| file | what its constants decide |
|---|---|
| `Sources/Kumone/Core/Player/Analysis/TransitionPlanner.swift` | **which** transition a pair gets — the tier thresholds (loudness / timbre / tempo / key / vocals), the overlap caps, the beat-match gate. All of it is `Config.standard`; `--set` and the console explore alternatives without editing it |
| `Sources/Kumone/Core/Player/Engine/TransitionAutomation.swift` | **how** that transition sounds — the fader laws, the staged-EQ stage windows, the sweep range, the echo throw and its tail |

### 2. Re-run the corpus

```sh
swift run -c release audition batch ~/Developer/kumone-audition-corpus
```

Analyses are cached in `<file>.analysis.json` sidecars next to the audio (same
format and version gate as the app's own `AudioCache` sidecars), so only the
first run pays for analysis. A 16-track corpus re-runs in ~12 s.

This writes, into `<corpus>/renders/`:

- `NN-<a>__<b>.wav` — one rendered hand-over per adjacent pair;
- `decisions.md` — a table of every pair's decision signals, plus the
  **distribution summary**.

### 3. Read the distribution first

The summary is the point. Before listening to anything, look at whether the
constant you moved changed the shape of the corpus:

```
**Tier**
- `clash`: 12  ████████████
- `neutral`: 2  ██
- `compatible`: 1  █

**Overlap length** — min 2.50s · median 2.50s · mean 3.81s · max 15.18s
```

`decisions.md` also lists **borderline pairs** — every signal sitting within
15 % of a threshold, e.g. *"loudness 6.75 dB just over the clash line
6.50 dB"*. Those are the pairs your next constant change will flip, so they are
the ones to listen to.

### 4. Listen to the ones that matter

```sh
afplay ~/Developer/kumone-audition-corpus/renders/12-*.wav
```

Every render is `preRoll` seconds of the outgoing track, the hand-over, then
`postRoll` seconds of the incoming one (12 s each by default), so you always
hear the transition in context.

### 5. Isolate a single technique

To judge one technique rather than the planner's choice for a pair:

```sh
swift run audition render a.flac b.flac --style echo   -o /tmp/echo.wav
swift run audition render a.flac b.flac --style sweep  -o /tmp/sweep.wav
swift run audition render a.flac b.flac --style staged -o /tmp/staged.wav
swift run audition render a.flac b.flac --style plain --fade 8 -o /tmp/long.wav
```

`--style` and `--fade` override the plan after the planner has run, so the mix
points stay where the planner put them and only the technique / length change.

---

## Commands

```
audition plan   <fileA> <fileB> [--json] [--set name=value,...]
audition render <fileA> <fileB> [-o out.wav] [--style plain|sweep|echo|staged]
                                [--fade N] [--pre N] [--post N] [--set ...]
audition batch  <corpusDir> [-o outDir] [--pairs a.flac:b.flac,...]
                            [--style ...] [--fade N] [--pre N] [--post N] [--set ...]
audition serve  [--corpus DIR] [--port 8766] [--host 127.0.0.1,10.147.19.10]
                [--state DIR]
audition knobs  [--json]
```

`batch` pairs the corpus directory's audio files in filename order (N files →
N−1 adjacent hand-overs) unless `--pairs` names them explicitly.

### `plan` — the decision, explained

```
$ swift run audition plan corpus/1409914560-…flac corpus/1440222808-…flac
1409914560-lossless-netease.flac  →  1440222808-hires-netease.flac
  tier          clash
  loudness gap  25.70 dB   [neutral > 3.0, clash > 6.5]
  timbre dist   0.194      [neutral > 0.25, clash > 0.45]
  tempo         0.140 folded   [beat-match ≤ 0.08, clash > 0.20]  128.0 → 110.1 BPM (conf 0.90 / 0.94)
  key distance  3           [demotes at ≥ 3 fifths]
  vocals        out 1.01 / in 0.92   [both > 1.10 = clash]
  → crossfade, echoOut(delay 352ms), overlap 2.50s, out @ 6:54.00, in @ 0:04.59
  ⚠︎ borderline: outgoing vocals 1.01 just under the vocal-clash line 1.10
```

Every threshold printed is read from the config the decision was actually made
under, so the explanation cannot drift from the decision — including under
`--set`, where the quoted lines are the moved ones.

`plan --json` prints the same decision in full: both tracks' analysis summary
and curves, the five signals with their thresholds and per-signal verdicts, the
derivation chain (which rule demoted the pair, and to what), the plan's
mechanics, and the style with its reason.

### `--set` / `knobs` — deciding under different thresholds

Every planner threshold is a field of `TransitionPlanner.Config`.
`Config.standard` holds the shipped numbers and is the default on every code
path, so the app's behaviour is exactly what it was when these were bare
constants. `--set` swaps in a modified copy for one run:

```sh
audition knobs                       # every knob, its shipped value and range
audition plan a.flac b.flac --set clashTimbreDistance=0.35
audition batch corpus --set neutralTimbreDistance=0.10,clashLoudnessDB=5.0
```

`audition knobs --json` is the same list the console's sliders are generated
from — adding a field to `Config` plus a row in
`Sources/Kumone/Core/Player/Audition/TransitionConfigFields.swift` is the whole
change needed to expose a new knob everywhere.

---

## `serve` — the decision console

```sh
audition serve --corpus ~/Developer/kumone-audition-corpus
#   http://127.0.0.1:8766/
#   http://10.147.19.10:8766/
```

One process: a small hand-written HTTP server in `Sources/audition/` plus the
planner and the cached analyses, all in memory. Moving a slider re-plans in
**~2 ms**, so the page updates as you drag.

The page (single file, mobile-friendly, follows the system light/dark theme):

- **选曲** — dropdowns over the corpus, prev/next adjacent pair, swap, or any
  local path typed in.
- **时间轴** — both tracks drawn: RMS envelope, vocal-activity contour, downbeat
  grid, phrase-boundary candidates, intro/outro shading, and the chosen
  out-point / in-point with the overlap window highlighted.
- **信号** — the five signals, each on a meter with its threshold lines marked
  so you can see how far the value sits from the line that matters, plus the
  verdict that signal argues for on its own.
- **决策链** — every rule in order, quoted, with the numbers it saw and what it
  did; the steps that actually changed the outcome are highlighted.
- **试听** — renders the current decision (~90× real time) and plays it inline;
  the WAV is served with byte ranges, and a button jumps to 3 s before the
  hand-over.
- **参数** — a slider per `Config` field, grouped, each with a one-line
  explanation; a live diff against `standard`; named presets saved as JSON
  under `<state>/configs/`.
- **批量** — all 15 adjacent pairs under the current config, with every cell
  that differs from `standard` marked `新值 ← 旧值` and the row highlighted.

State (renders and presets) lives in `<corpus>/console/` unless `--state` says
otherwise. Nothing is written back into the planner: the console explores a
config, and adopting one means editing `Config.standard`'s defaults.

---

## Why the render is trustworthy

The whole loop is worthless if the offline render is a look-alike rather than
the real thing. Three pieces of production code are shared, not duplicated:

- **`TransitionAutomation`** — the parameter curves as a pure function of
  `(plan, style, elapsed)`. `PlaybackEngine.updateOverlapLocked` applies one
  frame per 50 Hz tick; `OfflineTransitionRenderer` applies the same frames at
  the same rate. There is exactly one copy of every curve.
- **`DeckChain`** — the node types, their order, the EQ band layout
  (200 Hz low shelf / 900 Hz parametric / 3.5 kHz high shelf / high-pass) and
  the neutral pose of every parameter. Both engines build their decks from it,
  at the same fixed 44.1 kHz stereo format.
- **`TrackAnalyzer` / `TransitionPlanner`** — used directly, unwrapped.

What the offline path deliberately does *not* model: seek flush windows,
progressive-stream underruns and plan re-resolution. Those are transport
concerns; none of them shape how a transition sounds.

`.echoOut`'s "throw the delay once" is a stateful event in the live engine
(`echoThrown`). In the pure function it is expressed as a predicate on time —
*has progress crossed the stop point* — which yields identical parameter values
on every tick, because everything the throw sets is constant for the
transition. The engine still latches, so its settling phase knows a tail is
ringing.

### Measured render speed

**72×–206× real time on an Apple M4** (release build; mean 154× over 15 real
song pairs) — a 27–41 s transition clip renders in 0.13–0.36 s. This closes
item 3 of the stems pre-dev doc's §10 checklist: the forum claim that offline
rendering is no faster than real time applies to `.realtime` manual rendering,
not `.offline`.

---

## Building a corpus

Real listening cache, not synthetic tones:

```sh
mkdir -p ~/Developer/kumone-audition-corpus
rsync -av --exclude='*.part' --exclude='*.analysis.json' \
  <host>:Library/Caches/Kumone/Audio/ ~/Developer/kumone-audition-corpus/
```

Keep it **outside the repo** — it is large, copyrighted, and meant to stay
stable across many tuning sessions so A/B comparisons remain comparable.

---

## What the first real corpus run showed

Fifteen adjacent pairs of the author's own listening cache, all defaults:

| tier | count |
|---|---|
| clash | 12 |
| neutral | 2 |
| compatible | 1 |

Two findings the loop surfaced immediately, both about `TransitionPlanner`
rather than the automation:

1. **The timbre signal never fires.** Across the whole corpus the mel cosine
   distance ranged 0.001–0.032, against a neutral line of 0.15 and a clash line
   of 0.30 — an order of magnitude below the gate. On real, mastered music the
   L2-normalized mean log-mel profile is simply not that discriminative; either
   the thresholds want recalibrating to the observed range, or the fingerprint
   wants more resolution (e.g. per-band variance, not just the mean).

   *Fixed (analysis version 4).* The mean log-mel frame is dominated by its
   across-band mean — loudness, MFCC c0 — which every mastered record shares,
   so the cosine agreed by construction. The fingerprint is now the mean
   *level-free* mel shape over the loud half of the track: each frame is
   normalized by its own mean magnitude (gain-invariant), re-compressed, and
   has its across-band mean removed, so cosine distance is a shape
   correlation. Per-band variance, spectral contrast and frame-delta blocks
   were all measured on this corpus and none of them added separation. The 15
   adjacent pairs now spread 0.06–0.62, a track against its own other half
   stays under 0.11, and the lines moved to 0.25 / 0.45 — 5 pairs above
   neutral, 1 above clash.

2. **The loudness gap fires almost always, for a mechanical reason.** It
   compares the outgoing track's mean RMS over its *last 15 seconds* against
   the incoming opening. Tracks that end on an outro fade have near-silence
   there, which reads as a 15–31 dB "clash" (three pairs measured 15.4, 25.7
   and 31.4 dB). That is the signal measuring the fade-out, not a genuine level
   mismatch — the tail window arguably wants to be anchored at
   `outroFadeStart`, the same landmark the crossfade planner already uses to
   pick its out point.

Together these are why 12 of 15 pairs land in `clash` and exit on a 2.5 s
echo-out. Whether that is right is a listening question — which is what the
renders in `renders/` are for.

With both findings addressed, the same 15 pairs now split 7 `clash` / 6
`neutral` / 2 `compatible`; the remaining clashes come from the loudness and
tempo signals, not from timbre.
