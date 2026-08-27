#if os(macOS)
import Foundation

// The single page `audition serve` hands out. Everything it draws — the
// sliders, the signal meters, the derivation chain — is generated from the
// JSON the server sends, so adding a planner knob or a chain step needs no
// change here.

let consolePage = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>AutoMix 决策台</title>
<style>
:root{
  --bg:#0e1116; --panel:#161b22; --panel2:#1c2430; --line:#2a3341;
  --fg:#e6edf3; --dim:#9aa7b4; --accent:#4f9cf9; --good:#3fb950;
  --warn:#d29922; --bad:#f85149; --key:#a371f7;
}
@media (prefers-color-scheme:light){
  :root{--bg:#f6f8fa;--panel:#fff;--panel2:#f0f3f6;--line:#d6dee7;
        --fg:#1c2128;--dim:#5b6774;--accent:#0969da;--good:#1a7f37;--warn:#9a6700;}
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:15px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;
  padding:0 0 4rem;-webkit-text-size-adjust:100%}
.wrap{max-width:860px;margin:0 auto;padding:1rem}
h1{font-size:1.3rem;margin:.3rem 0}
h2{font-size:1.02rem;margin:1.6rem 0 .5rem;padding-top:.9rem;border-top:1px solid var(--line);
  display:flex;align-items:center;justify-content:space-between;gap:.5rem}
.lead{color:var(--dim);font-size:.85rem;margin:.2rem 0 0}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;
  padding:.85rem;margin:.7rem 0}
select,input[type=text],input[type=number]{background:var(--panel2);color:var(--fg);
  border:1px solid var(--line);border-radius:8px;padding:.45rem .5rem;font:inherit;
  font-size:.88rem;width:100%;max-width:100%}
button{background:var(--panel2);color:var(--fg);border:1px solid var(--line);
  border-radius:8px;padding:.45rem .75rem;font:inherit;font-size:.85rem;cursor:pointer;
  -webkit-tap-highlight-color:transparent}
button.go{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
button:disabled{opacity:.45;cursor:default}
.row{display:flex;gap:.5rem;flex-wrap:wrap;align-items:center}
.row>.grow{flex:1 1 220px;min-width:0}
.pick label{display:block;font-size:.75rem;color:var(--dim);margin:.35rem 0 .15rem}
.chip{display:inline-block;font-size:.75rem;padding:.1rem .55rem;border-radius:99px;
  border:1px solid var(--line);vertical-align:middle}
.chip.compatible{color:var(--good);border-color:var(--good)}
.chip.neutral{color:var(--warn);border-color:var(--warn)}
.chip.clash{color:var(--bad);border-color:var(--bad)}
.chip.na{color:var(--dim)}
.verdict{display:flex;flex-wrap:wrap;gap:.4rem .9rem;align-items:baseline;margin-top:.4rem}
.verdict b{font-size:1.05rem}
.verdict span{font-size:.85rem;color:var(--dim)}
.verdict code{background:var(--panel2);padding:.05rem .35rem;border-radius:4px;
  font:12px ui-monospace,Menlo,monospace;color:var(--fg)}
.tl{margin:.5rem 0}
.tl h4{margin:0 0 .2rem;font-size:.85rem;font-weight:600;
  display:flex;justify-content:space-between;gap:.5rem}
.tl h4 span{color:var(--dim);font-weight:400;font-size:.78rem}
.tl svg{width:100%;height:auto;display:block;border-radius:8px;background:var(--panel2)}
.ruler{position:relative;height:1.1rem;margin-top:.1rem;font-size:.65rem;color:var(--dim);
  overflow:hidden}
.ruler .tick{position:absolute;top:0;transform:translateX(2px);white-space:nowrap}
.ruler .cue{position:absolute;top:0;transform:translateX(-50%);white-space:nowrap;
  color:var(--good);font-weight:600;background:var(--panel);padding:0 .2rem;border-radius:3px}
.legend{font-size:.72rem;color:var(--dim);margin:.25rem 0 0;display:flex;gap:.8rem;flex-wrap:wrap}
.legend i{display:inline-block;width:.7rem;height:.7rem;border-radius:2px;margin-right:.25rem;
  vertical-align:-1px}
.sig{border-top:1px dashed var(--line);padding:.6rem 0}
.sig:first-child{border-top:0}
.sighead{display:flex;justify-content:space-between;align-items:baseline;gap:.5rem;
  font-size:.88rem}
.sighead b{font-variant-numeric:tabular-nums}
.meter{position:relative;height:26px;margin:.45rem 0 .25rem;background:var(--panel2);
  border-radius:6px;border:1px solid var(--line)}
.meter .fill{position:absolute;top:0;bottom:0;left:0;border-radius:5px 0 0 5px;opacity:.28}
.meter .fill.compatible{background:var(--good)}
.meter .fill.neutral{background:var(--warn)}
.meter .fill.clash{background:var(--bad)}
.meter .mark{position:absolute;top:-1px;bottom:-1px;width:2px;background:var(--fg);opacity:.55}
.meter .mark b{position:absolute;top:-1.05rem;left:50%;transform:translateX(-50%);
  font-size:.64rem;color:var(--dim);font-weight:400;white-space:nowrap}
.meter .dot{position:absolute;top:50%;width:11px;height:11px;margin:-5.5px 0 0 -5.5px;
  border-radius:50%;background:var(--accent);box-shadow:0 0 0 2px var(--panel)}
.sigsay{font-size:.8rem;color:var(--dim);margin-top:.5rem}
.chain{counter-reset:s;margin:0;padding:0;list-style:none}
.chain li{position:relative;padding:.5rem 0 .5rem 1.9rem;border-top:1px dashed var(--line)}
.chain li:first-child{border-top:0}
.chain li::before{counter-increment:s;content:counter(s);position:absolute;left:0;top:.55rem;
  width:1.35rem;height:1.35rem;border-radius:50%;border:1px solid var(--line);
  display:flex;align-items:center;justify-content:center;font-size:.7rem;color:var(--dim)}
.chain li.fired::before{background:var(--accent);border-color:var(--accent);color:#fff}
.chain .t{font-size:.88rem;font-weight:600}
.chain .r{font-size:.76rem;color:var(--dim);border-left:2px solid var(--line);
  padding-left:.5rem;margin:.2rem 0}
.chain .d{font-size:.8rem;font-variant-numeric:tabular-nums}
.chain .o{font-size:.84rem;margin-top:.15rem}
.chain li.fired .o{color:var(--accent);font-weight:600}
details{margin:.5rem 0}
summary{cursor:pointer;font-size:.88rem;font-weight:600;padding:.3rem 0}
.knob{display:grid;grid-template-columns:1fr auto;gap:.15rem .5rem;align-items:center;
  padding:.45rem 0;border-top:1px dashed var(--line)}
.knob:first-child{border-top:0}
.knob .n{font:12px ui-monospace,Menlo,monospace}
.knob .v{font:12px ui-monospace,Menlo,monospace;font-variant-numeric:tabular-nums;
  text-align:right;min-width:4.2rem}
.knob.dirty .n{color:var(--accent);font-weight:700}
.knob .b{font-size:.72rem;color:var(--dim);grid-column:1/3}
.knob input[type=range]{grid-column:1/3;width:100%;margin:.15rem 0;accent-color:var(--accent)}
table{width:100%;border-collapse:collapse;font-size:.78rem;margin:.5rem 0}
th,td{border:1px solid var(--line);padding:.3rem .4rem;text-align:left;white-space:nowrap}
th{background:var(--panel2);position:sticky;top:0}
.scroll{overflow-x:auto;-webkit-overflow-scrolling:touch}
tr.changed td{background:color-mix(in srgb,var(--accent) 14%,transparent)}
.was{color:var(--dim);text-decoration:line-through}
audio{width:100%;margin:.4rem 0;height:38px}
.muted{color:var(--dim);font-size:.8rem}
.err{color:var(--bad);font-size:.82rem}
.spin{display:inline-block;width:.8rem;height:.8rem;border:2px solid var(--line);
  border-top-color:var(--accent);border-radius:50%;animation:spin .7s linear infinite;
  vertical-align:-1px}
@keyframes spin{to{transform:rotate(360deg)}}
</style>
</head>
<body>
<div class="wrap">
  <h1>AutoMix 决策台</h1>
  <p class="lead" id="lead">加载中…</p>

  <div class="card pick">
    <div class="row">
      <div class="grow">
        <label for="outSel">出曲</label>
        <select id="outSel"></select>
      </div>
      <div class="grow">
        <label for="inSel">入曲</label>
        <select id="inSel"></select>
      </div>
    </div>
    <div class="row" style="margin-top:.5rem">
      <button id="prevPair">← 上一对</button>
      <button id="nextPair">下一对 →</button>
      <button id="swap">⇄ 对调</button>
      <span class="muted" id="planTime"></span>
    </div>
    <details>
      <summary>任意本机路径</summary>
      <div class="row" style="margin-top:.4rem">
        <div class="grow"><input type="text" id="outPath" placeholder="/path/to/outgoing.flac"></div>
        <div class="grow"><input type="text" id="inPath" placeholder="/path/to/incoming.flac"></div>
        <button id="usePaths">用这两个路径</button>
      </div>
      <p class="muted">首次分析一首没有 sidecar 的曲子要几秒。</p>
    </details>
  </div>

  <div class="card" id="verdictCard">
    <div class="verdict" id="verdict"></div>
    <div class="muted" id="nearMisses"></div>
    <div class="err" id="err"></div>
  </div>

  <h2>时间轴</h2>
  <div id="timelines"></div>
  <p class="legend">
    <span><i style="background:var(--accent);opacity:.5"></i>RMS 包络</span>
    <span><i style="background:var(--key)"></i>人声活跃度</span>
    <span><i style="background:var(--good);opacity:.45"></i>叠加区间</span>
    <span><i style="background:var(--warn);opacity:.35"></i>intro / outro</span>
    <span>▾ 乐句边界 · 底部细刻度 = downbeat</span>
  </p>

  <h2>信号</h2>
  <div class="card" id="signals"></div>

  <h2>决策链</h2>
  <div class="card"><ol class="chain" id="chain"></ol></div>

  <h2>试听 <button id="renderBtn" class="go">渲染试听</button></h2>
  <div class="card">
    <audio id="audio" controls preload="none"></audio>
    <div class="row">
      <button id="toOverlap">跳到交接前 3s</button>
      <span class="muted" id="renderInfo">按上面的按钮渲染当前决策（含前后各 12s 上下文）。</span>
    </div>
  </div>

  <h2>参数 <span class="muted" id="diffCount"></span></h2>
  <div class="card">
    <div class="row">
      <button id="resetAll">全部恢复 standard</button>
      <div class="grow"><input type="text" id="cfgName" placeholder="预设名字"></div>
      <button id="saveCfg">保存</button>
      <select id="cfgList" style="max-width:12rem"></select>
      <button id="loadCfg">载入</button>
    </div>
    <div id="diffBox" class="muted" style="margin-top:.4rem"></div>
    <div class="row" style="margin-top:.5rem">
      <div class="grow">
        <label class="muted" for="styleSel">style 覆盖</label>
        <select id="styleSel"></select>
      </div>
      <div class="grow">
        <label class="muted" for="fadeOv">fade 覆盖（秒，0 = 不覆盖）</label>
        <input type="number" id="fadeOv" value="0" min="0" max="60" step="0.5">
      </div>
    </div>
  </div>
  <div id="knobs"></div>

  <h2>批量 <button id="batchBtn">跑全语料</button></h2>
  <div class="card">
    <p class="muted" id="batchInfo">用当前参数跑语料里全部相邻对，和 standard 的结果逐格对照。</p>
    <div class="scroll"><table id="batchTable"></table></div>
  </div>
</div>

<script>
const $ = s => document.querySelector(s);
let BOOT = null, CONFIG = {}, REPORT = null, LAST_RENDER = null;

const fmt = (v, d = 2) => (v === null || v === undefined) ? "—" : Number(v).toFixed(d);
const mmss = t => (t === null || t === undefined) ? "—"
  : `${Math.floor(t / 60)}:${(t % 60).toFixed(2).padStart(5, "0")}`;

async function api(path, body) {
  const opt = body ? {method: "POST", body: JSON.stringify(body)} : {};
  const r = await fetch(path, opt);
  const j = await r.json();
  if (j.error) throw new Error(j.error);
  return j;
}

// ---------------------------------------------------------------- boot

async function boot() {
  BOOT = await api("/api/bootstrap");
  $("#lead").textContent = `${BOOT.corpus} · ${BOOT.tracks.length} 首 · `
    + `${BOOT.fields.length} 个可调参数`;
  for (const sel of ["#outSel", "#inSel"]) {
    $(sel).innerHTML = BOOT.tracks
      .map(t => `<option value="${t.path}">${t.name}</option>`).join("");
  }
  if (BOOT.pairs.length) {
    $("#outSel").value = BOOT.pairs[0].outgoing;
    $("#inSel").value = BOOT.pairs[0].incoming;
  }
  $("#styleSel").innerHTML = ['<option value="auto">auto（planner 自己选）</option>']
    .concat(BOOT.styles.map(s => `<option value="${s}">${s}</option>`)).join("");
  CONFIG = Object.assign({}, BOOT.standard);
  buildKnobs();
  refreshConfigList(BOOT.configs);
  plan();
}

// ---------------------------------------------------------------- knobs

const GROUPS = {
  tier: "档位门槛（compatible / neutral / clash）",
  beatmatch: "对拍门槛",
  overlap: "叠加长度",
  shape: "落点与手法",
};

function buildKnobs() {
  let html = "";
  for (const [g, title] of Object.entries(GROUPS)) {
    const fs = BOOT.fields.filter(f => f.group === g);
    if (!fs.length) continue;
    html += `<details ${g === "tier" ? "open" : ""}><summary>${title}</summary><div class="card">`;
    for (const f of fs) {
      html += `<div class="knob" id="k-${f.name}">
        <div class="n">${f.name}</div>
        <div class="v" id="v-${f.name}">${Number(f.standard).toFixed(f.digits)}</div>
        <div class="b">${f.blurb}</div>
        <input type="range" data-name="${f.name}" min="${f.min}" max="${f.max}"
               step="${f.step}" value="${f.standard}">
      </div>`;
    }
    html += "</div></details>";
  }
  $("#knobs").innerHTML = html;
  $("#knobs").addEventListener("input", e => {
    const name = e.target.dataset.name;
    if (!name) return;
    CONFIG[name] = parseFloat(e.target.value);
    paintKnob(name);
    schedulePlan();
  });
}

function paintKnob(name) {
  const f = BOOT.fields.find(x => x.name === name);
  $("#v-" + name).textContent = Number(CONFIG[name]).toFixed(f.digits);
  $("#k-" + name).classList.toggle("dirty", Math.abs(CONFIG[name] - f.standard) > 1e-12);
  paintDiff();
}

function paintDiff() {
  const diff = BOOT.fields.filter(f => Math.abs(CONFIG[f.name] - f.standard) > 1e-12);
  $("#diffCount").textContent = diff.length ? `${diff.length} 项偏离 standard` : "= standard";
  $("#diffBox").innerHTML = diff.length
    ? diff.map(f => `<code>${f.name}</code> ${Number(f.standard).toFixed(f.digits)}`
        + ` → <b>${Number(CONFIG[f.name]).toFixed(f.digits)}</b>`).join(" · ")
    : "当前参数与出厂标定完全一致。";
}

function applyConfig(cfg) {
  CONFIG = Object.assign({}, BOOT.standard, cfg || {});
  for (const f of BOOT.fields) {
    const el = document.querySelector(`input[data-name="${f.name}"]`);
    if (el) el.value = CONFIG[f.name];
    paintKnob(f.name);
  }
  plan();
}

// ---------------------------------------------------------------- plan

let planTimer = null, planSeq = 0;
function schedulePlan() {
  clearTimeout(planTimer);
  planTimer = setTimeout(plan, 90);
}

function requestBody() {
  const fade = parseFloat($("#fadeOv").value) || 0;
  return {
    outgoing: $("#outSel").value, incoming: $("#inSel").value,
    config: CONFIG, style: $("#styleSel").value, fade: fade,
  };
}

async function plan() {
  const seq = ++planSeq;
  const t0 = performance.now();
  try {
    const r = await api("/api/plan", requestBody());
    if (seq !== planSeq) return;               // a newer drag已经在路上
    REPORT = r;
    $("#err").textContent = "";
    $("#planTime").textContent = `重算 ${Math.round(performance.now() - t0)} ms`;
    paintVerdict(); paintTimelines(); paintSignals(); paintChain();
  } catch (e) {
    if (seq === planSeq) $("#err").textContent = String(e.message || e);
  }
}

function paintVerdict() {
  const r = REPORT;
  const bars = r.plan.overlapBars ? ` (${r.plan.overlapBars} 小节)` : "";
  const rates = r.plan.outgoingRate
    ? `<span>变速 <code>${r.plan.outgoingRate.toFixed(4)} / ${r.plan.incomingRate.toFixed(4)}</code></span>`
    : "";
  $("#verdict").innerHTML = `
    <b class="chip ${r.tier}">${r.tier}</b>
    <b>${r.plan.kind}</b>
    <span>手法 <code>${r.style.description}</code></span>
    <span>叠加 <code>${fmt(r.plan.overlapDuration)}s${bars}</code></span>
    <span>出点 <code>${mmss(r.plan.outPoint)}</code></span>
    <span>入点 <code>${mmss(r.plan.inPoint)}</code></span>
    ${rates}
    ${r.demotedByKey ? '<span class="chip neutral">被和声降档</span>' : ""}
    ${r.overridden ? '<span class="chip clash">人工覆盖</span>' : ""}`;
  $("#nearMisses").innerHTML = r.nearMisses.length
    ? "⚠︎ 临界：" + r.nearMisses.join(" · ") : "";
}

// ---------------------------------------------------------------- timelines

function timeline(t, role, r) {
  const W = 1000, H = 132, PAD = 4;
  const x = s => PAD + (s / t.duration) * (W - 2 * PAD);
  const top = 14, base = H - 20, h = base - top;
  let g = "";

  // intro / outro shading
  if (t.introEnd > 0)
    g += `<rect x="${x(0)}" y="${top}" width="${x(t.introEnd) - x(0)}" height="${h}"
           fill="var(--warn)" opacity=".16"/>`;
  if (t.outroFadeStart !== null && t.outroFadeStart !== undefined)
    g += `<rect x="${x(t.outroFadeStart)}" y="${top}"
           width="${x(t.duration) - x(t.outroFadeStart)}" height="${h}"
           fill="var(--warn)" opacity=".16"/>`;

  // overlap window
  const start = role === "out" ? r.plan.outPoint : r.plan.inPoint;
  if (start !== null && start !== undefined && r.plan.overlapDuration > 0) {
    const x0 = x(start), x1 = x(Math.min(t.duration, start + r.plan.overlapDuration));
    g += `<rect x="${x0}" y="${top}" width="${Math.max(1.5, x1 - x0)}" height="${h}"
           fill="var(--good)" opacity=".33"/>`;
    g += `<line x1="${x0}" y1="${top - 6}" x2="${x0}" y2="${base}"
           stroke="var(--good)" stroke-width="2"/>`;
  }

  // RMS envelope, as a filled area
  if (t.rms.length > 1) {
    const step = (W - 2 * PAD) / (t.rms.length - 1);
    let d = `M ${PAD} ${base}`;
    t.rms.forEach((v, i) => { d += ` L ${(PAD + i * step).toFixed(1)} ${(base - v * h).toFixed(1)}`; });
    d += ` L ${W - PAD} ${base} Z`;
    g += `<path d="${d}" fill="var(--accent)" opacity=".45"/>`;
  }
  // vocal activity
  if (t.vocal.length > 1) {
    const step = (W - 2 * PAD) / (t.vocal.length - 1);
    let d = "";
    t.vocal.forEach((v, i) => {
      d += `${i ? "L" : "M"} ${(PAD + i * step).toFixed(1)} ${(base - v * h).toFixed(1)} `;
    });
    g += `<path d="${d}" fill="none" stroke="var(--key)" stroke-width="1.4" opacity=".95"/>`;
  }
  // downbeat grid
  g += t.downbeats.map(d =>
    `<line x1="${x(d).toFixed(1)}" y1="${base}" x2="${x(d).toFixed(1)}" y2="${base + 4}"
      stroke="var(--fg)" opacity=".22"/>`).join("");
  // phrase boundaries, best first — the top few are the real candidates
  g += t.phraseBoundaries.slice(0, 24).map((p, i) =>
    `<polygon points="${x(p) - 4},${top - 8} ${x(p) + 4},${top - 8} ${x(p)},${top - 1}"
      fill="var(--fg)" opacity="${(0.75 - i * 0.02).toFixed(2)}"/>`).join("");
  // minute ruler ticks (the labels live in HTML below, so squashing the
  // viewBox to the panel width never squashes the type)
  for (let s = 0; s <= t.duration; s += 60) {
    g += `<line x1="${x(s)}" y1="${base}" x2="${x(s)}" y2="${base + 8}" stroke="var(--dim)"/>`;
  }

  const pct = s => (PAD + (s / t.duration) * (W - 2 * PAD)) / W * 100;
  let ruler = "";
  for (let s = 0; s <= t.duration; s += 60) {
    ruler += `<span class="tick" style="left:${pct(s)}%">${s / 60}m</span>`;
  }
  if (start !== null && start !== undefined) {
    // Keep the cue label inside the panel at either end of the track.
    const p = pct(start);
    const shift = p > 78 ? "-100%" : (p < 12 ? "0" : "-50%");
    ruler += `<span class="cue" style="left:${p}%;transform:translateX(${shift})">${
      role === "out" ? "out" : "in"} ${mmss(start)}</span>`;
  }
  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none"
           style="height:132px">${g}</svg><div class="ruler">${ruler}</div>`;
}

function paintTimelines() {
  const r = REPORT;
  const block = (t, role, label) => `
    <div class="tl">
      <h4>${label} ${t.name}
        <span>${mmss(t.duration)} · ${fmt(t.bpm, 1)} BPM (${fmt(t.bpmConfidence)})
          · ${t.key || "无调"} (${fmt(t.keyConfidence)})
          · intro ${mmss(t.introEnd)}
          · outro ${t.outroFadeStart != null ? mmss(t.outroFadeStart) : "无"}</span></h4>
      ${timeline(t, role, r)}
    </div>`;
  $("#timelines").innerHTML = block(r.outgoing, "out", "出 ") + block(r.incoming, "in", "入 ");
}

// ---------------------------------------------------------------- signals

function paintSignals() {
  $("#signals").innerHTML = REPORT.signals.map(s => {
    const pct = v => Math.max(0, Math.min(100, (v / s.axisMax) * 100));
    const marks = s.marks.map(m =>
      `<span class="mark" style="left:${pct(m.value)}%"><b>${m.label} ${fmt(m.value, 2)}</b></span>`)
      .join("");
    const dot = s.value === null || s.value === undefined ? ""
      : `<span class="dot" style="left:${pct(s.value)}%"></span>`;
    const fill = s.value === null || s.value === undefined ? ""
      : `<span class="fill ${s.state}" style="width:${pct(s.value)}%"></span>`;
    return `<div class="sig">
      <div class="sighead"><span>${s.label}</span>
        <b class="chip ${s.state}">${s.display}</b></div>
      <div class="meter">${fill}${marks}${dot}</div>
      <div class="sigsay">${s.verdict}</div>
    </div>`;
  }).join("");
}

function paintChain() {
  $("#chain").innerHTML = REPORT.chain.map(c => `
    <li class="${c.fired ? "fired" : ""}">
      <div class="t">${c.title}</div>
      <div class="r">${c.rule}</div>
      <div class="d">${c.detail}</div>
      <div class="o">${c.outcome}</div>
    </li>`).join("");
}

// ---------------------------------------------------------------- render

$("#renderBtn").onclick = async () => {
  const btn = $("#renderBtn");
  btn.disabled = true;
  $("#renderInfo").innerHTML = '<span class="spin"></span> 渲染中…';
  try {
    const r = await api("/api/render", requestBody());
    LAST_RENDER = r;
    $("#audio").src = r.url + "?t=" + Date.now();
    $("#audio").load();
    $("#renderInfo").textContent = r.cached
      ? `复用已渲染的这一版 · 交接在 ${fmt(r.overlapStart)}s`
      : `${fmt(r.duration)}s 音频 · 交接在 ${fmt(r.overlapStart)}s`
        + ` · ${fmt(r.realtimeFactor, 1)}× 实时`;
  } catch (e) {
    $("#renderInfo").innerHTML = `<span class="err">${e.message}</span>`;
  }
  btn.disabled = false;
};

$("#toOverlap").onclick = () => {
  if (!LAST_RENDER) return;
  const a = $("#audio");
  a.currentTime = Math.max(0, LAST_RENDER.overlapStart - 3);
  a.play();
};

// ---------------------------------------------------------------- batch

$("#batchBtn").onclick = async () => {
  const btn = $("#batchBtn");
  btn.disabled = true;
  $("#batchInfo").innerHTML = '<span class="spin"></span> 计算中…';
  try {
    const r = await api("/api/batch", requestBody());
    const changed = r.pairs.filter(p => p.changed).length;
    $("#batchInfo").textContent =
      `${r.pairs.length} 对 · ${changed} 对结果与 standard 不同（高亮行）`;
    const cell = (p, key, digits) => {
      const now = p[key], was = p.standard ? p.standard[key] : undefined;
      const show = digits === undefined ? (now ?? "—") : fmt(now, digits);
      if (was === undefined || was === null) return `<td>${show}</td>`;
      const same = digits === undefined ? was === now : Math.abs(was - now) < 0.005;
      const wasShow = digits === undefined ? was : fmt(was, digits);
      return same ? `<td>${show}</td>`
        : `<td><b>${show}</b> <span class="was">← ${wasShow}</span></td>`;
    };
    $("#batchTable").innerHTML =
      `<tr><th>出 → 入</th><th>档位</th><th>plan</th><th>手法</th><th>叠加 s</th>
        <th>响度 dB</th><th>音色</th><th>出点</th></tr>` +
      r.pairs.map(p => `<tr class="${p.changed ? "changed" : ""}">
        <td title="${p.outgoing} → ${p.incoming}">${p.outgoing.slice(0, 10)} → ${p.incoming.slice(0, 10)}</td>
        ${cell(p, "tier")}${cell(p, "plan")}${cell(p, "style")}${cell(p, "overlap", 2)}
        <td>${fmt(p.loudness)}</td><td>${fmt(p.timbre, 3)}</td><td>${mmss(p.outPoint)}</td>
      </tr>`).join("");
  } catch (e) {
    $("#batchInfo").innerHTML = `<span class="err">${e.message}</span>`;
  }
  btn.disabled = false;
};

// ---------------------------------------------------------------- presets

function refreshConfigList(names) {
  $("#cfgList").innerHTML = names.length
    ? names.map(n => `<option value="${n}">${n}</option>`).join("")
    : '<option value="">（还没有预设）</option>';
}

$("#saveCfg").onclick = async () => {
  const name = $("#cfgName").value.trim();
  if (!name) { $("#cfgName").focus(); return; }
  const r = await api("/api/configs", {name: name, config: CONFIG});
  refreshConfigList(r.configs);
  $("#cfgList").value = r.saved;
};
$("#loadCfg").onclick = async () => {
  const name = $("#cfgList").value;
  if (!name) return;
  const r = await api("/api/configs/" + encodeURIComponent(name));
  applyConfig(r.config);
};
$("#resetAll").onclick = () => applyConfig(BOOT.standard);

// ---------------------------------------------------------------- picking

const pairIndex = () => BOOT.pairs.findIndex(
  p => p.outgoing === $("#outSel").value && p.incoming === $("#inSel").value);
function gotoPair(i) {
  if (!BOOT.pairs.length) return;
  const p = BOOT.pairs[(i + BOOT.pairs.length) % BOOT.pairs.length];
  $("#outSel").value = p.outgoing; $("#inSel").value = p.incoming;
  plan();
}
$("#prevPair").onclick = () => gotoPair((pairIndex() < 0 ? 0 : pairIndex()) - 1);
$("#nextPair").onclick = () => gotoPair((pairIndex() < 0 ? -1 : pairIndex()) + 1);
$("#swap").onclick = () => {
  const a = $("#outSel").value;
  $("#outSel").value = $("#inSel").value; $("#inSel").value = a;
  plan();
};
$("#usePaths").onclick = () => {
  for (const [inp, sel] of [["#outPath", "#outSel"], ["#inPath", "#inSel"]]) {
    const v = $(inp).value.trim();
    if (!v) continue;
    const s = $(sel);
    let opt = [...s.options].find(o => o.value === v);
    if (!opt) { opt = new Option(v.split("/").pop(), v); s.add(opt); }
    s.value = v;
  }
  plan();
};
$("#outSel").onchange = plan;
$("#inSel").onchange = plan;
$("#styleSel").onchange = plan;
$("#fadeOv").oninput = schedulePlan;

boot().catch(e => { $("#lead").textContent = "启动失败：" + e.message; });
</script>
</body>
</html>
"""#
#endif
