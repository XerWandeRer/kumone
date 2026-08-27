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
  padding:0 0 11rem;-webkit-text-size-adjust:100%}
/* The transport dock. Auditioning is the point of the page, so the render
   button, the player and the jump-to-the-hand-over control stay reachable
   from anywhere in a long scroll — including while a stem render runs. */
.dock{position:fixed;left:0;right:0;bottom:0;z-index:20;background:var(--panel);
  border-top:1px solid var(--line);padding:.55rem .7rem calc(.55rem + env(safe-area-inset-bottom));
  box-shadow:0 -6px 20px rgba(0,0,0,.22)}
.dock .inner{max-width:860px;margin:0 auto}
.dock audio{height:34px;margin:.35rem 0 0}
.dock .now{font-size:.78rem;color:var(--dim);white-space:nowrap;overflow:hidden;
  text-overflow:ellipsis;flex:1 1 12rem;min-width:0}
.wrap{max-width:860px;margin:0 auto;padding:1rem}
h1{font-size:1.3rem;margin:.3rem 0}
h2{font-size:1.02rem;margin:1.6rem 0 .5rem;padding-top:.9rem;border-top:1px solid var(--line);
  display:flex;align-items:center;justify-content:space-between;gap:.5rem}
.lead{color:var(--dim);font-size:.85rem;margin:.2rem 0 0}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;
  padding:.85rem;margin:.7rem 0}
select,input[type=text],input[type=number],textarea{background:var(--panel2);color:var(--fg);
  border:1px solid var(--line);border-radius:8px;padding:.45rem .5rem;font:inherit;
  font-size:.88rem;width:100%;max-width:100%}
textarea{font:12px/1.5 ui-monospace,Menlo,monospace;resize:vertical}
#aiPreview{font-size:.84rem;line-height:1.7}
#aiPreview code{background:var(--panel2);padding:.05rem .35rem;border-radius:4px;
  font:12px ui-monospace,Menlo,monospace}
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
      <summary>用本机上任意两个文件</summary>
      <div class="row" style="margin-top:.4rem">
        <div class="grow"><input type="text" id="outPath" placeholder="/path/to/outgoing.flac"></div>
        <div class="grow"><input type="text" id="inPath" placeholder="/path/to/incoming.flac"></div>
        <button id="usePaths">用这两个路径</button>
      </div>
      <p class="muted">第一次分析一首没分析过的曲子要几秒。</p>
    </details>
  </div>

  <div class="card" id="verdictCard">
    <div class="verdict" id="verdict"></div>
    <div class="muted" id="nearMisses"></div>
    <div class="err" id="err"></div>
  </div>

  <h2>两首歌长什么样</h2>
  <div id="timelines"></div>
  <p class="legend">
    <span><i style="background:var(--accent);opacity:.5"></i>音量起伏</span>
    <span><i style="background:var(--key)"></i>人声密度</span>
    <span><i style="background:var(--good);opacity:.45"></i>两首歌叠在一起的那一段</span>
    <span><i style="background:var(--warn);opacity:.35"></i>前奏 / 尾奏</span>
    <span>▾ 乐句起点 · 底部细刻度 = 每小节第一拍</span>
  </p>

  <h2>五项信号：系统在看什么</h2>
  <div class="card" id="signals"></div>

  <h2>它是怎么一步步想出来的</h2>
  <div class="card"><ol class="chain" id="chain"></ol></div>

  <h2>参数：<span id="knobCount">…</span> 个可以拧的旋钮 <span class="muted" id="diffCount"></span></h2>
  <div class="card">
    <div class="row">
      <button id="resetAll">全部恢复出厂设置</button>
      <div class="grow"><input type="text" id="cfgName" placeholder="给这套参数起个名字"></div>
      <button id="saveCfg">保存</button>
      <select id="cfgList" style="max-width:12rem"></select>
      <button id="loadCfg">载入</button>
    </div>
    <div id="diffBox" class="muted" style="margin-top:.4rem"></div>
    <div class="row" style="margin-top:.5rem">
      <div class="grow">
        <label class="muted" for="styleSel">出曲怎么离场（不选就让系统自己决定）</label>
        <select id="styleSel"></select>
      </div>
      <div class="grow">
        <label class="muted" for="fadeOv">强制叠加多少秒（0 = 让系统自己算）</label>
        <input type="number" id="fadeOv" value="0" min="0" max="60" step="0.5">
      </div>
    </div>
    <div class="row" style="margin-top:.5rem">
      <div class="grow">
        <label class="muted">
          <input type="checkbox" id="stemsReady" checked style="width:auto;margin-right:.35rem">
          告诉规划器「人声分离可用」（这台机器模型就绪，所以默认开）
        </label>
        <p class="muted" style="margin:.15rem 0 0;font-size:.75rem">
          关掉 = 产品里的默认行为，规划器完全不看下面那组 stem 参数，
          结论与没有 stem 功能时逐字段一致。打开后它可以自己选 vocal duck / acapella over，
          并把交接点挪到出曲还在唱的地方。</p>
      </div>
    </div>
    <div class="row" style="margin-top:.5rem">
      <div class="grow">
        <label class="muted" for="stemSel">手动指定 stem 手法（盖掉规划器的选择，只影响试听渲染）</label>
        <select id="stemSel"></select>
      </div>
      <div class="grow" id="duckBox" style="display:none">
        <label class="muted" for="duckDB">vocal duck 深度 <b id="duckVal">−9.0 dB</b></label>
        <input type="range" id="duckDB" min="0" max="24" step="0.5" value="9"
               style="width:100%;accent-color:var(--accent)">
      </div>
    </div>
    <p class="muted" id="stemNote">stem 手法要先把出曲的叠加窗分离成人声/伴奏，首次约 20s，
      同一窗口再渲染走 sidecar 缓存。批量视图不跑 stem。</p>
  </div>
  <div id="knobs"></div>

  <h2>把整个语料跑一遍 <button id="batchBtn">开始</button></h2>
  <div class="card">
    <p class="muted" id="batchInfo">用当前参数把语料里所有相邻的歌两两跑一遍，和出厂设置的结果逐格对照。</p>
    <div class="scroll"><table id="batchTable"></table></div>
  </div>

  <h2>让 AI 帮你调</h2>
  <div class="card">
    <p class="muted">把这一页现在看到的一切——系统怎么决策、每个参数各是什么意思和当前取值、
      这一对歌的五项信号和判断过程、你改动过哪些参数——打包成一段纯文本，
      贴给任意一个 AI 聊天窗口，它回一段 JSON，再贴回来就能应用。</p>
    <div class="row">
      <button id="copyAI" class="go">复制给 AI</button>
      <span class="muted" id="copyInfo"></span>
    </div>
    <textarea id="copyFallback" style="display:none;width:100%;height:9rem;margin-top:.5rem"></textarea>
    <div style="margin-top:.8rem">
      <label class="muted" for="aiPaste">粘贴 AI 的回复（带解释文字也没关系，会自动挑出里面的 JSON）</label>
      <textarea id="aiPaste" style="width:100%;height:7rem"
        placeholder='例如：&#10;```json&#10;{"config": {"neutralTimbreDistance": 0.3}, "rationale": "…"}&#10;```'></textarea>
    </div>
    <div class="row" style="margin-top:.4rem">
      <button id="parseAI">看看它想改什么</button>
      <button id="applyAI" class="go" style="display:none">确认应用</button>
      <button id="cancelAI" style="display:none">取消</button>
    </div>
    <div id="aiPreview" style="margin-top:.5rem"></div>
  </div>
</div>

<div class="dock"><div class="inner">
  <div class="row">
    <button id="renderBtn" class="go">渲染试听</button>
    <button id="toOverlap">跳到交接前 3s</button>
    <span class="now" id="renderInfo">点「渲染试听」听听当前这一版（前后各带 12 秒上下文）。</span>
  </div>
  <audio id="audio" controls preload="none"></audio>
</div></div>

<script>
const $ = s => document.querySelector(s);
let BOOT = null, CONFIG = {}, REPORT = null, LAST_RENDER = null, BATCH = null;

// The three tiers, said the way a person would say them. The English term is
// kept as a small annotation rather than dropped: it is what the code, the
// CLI and the batch report all call it.
const TIER_TEXT = {
  compatible: "这两首歌很搭",
  neutral: "一般般，能接但别贪",
  clash: "差异很大，快进快出",
};
const tierText = t => TIER_TEXT[t] || t;

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
  $("#lead").textContent = `${BOOT.corpus} · ${BOOT.tracks.length} 首歌 · ${BOOT.fields.length} 个可调参数。`
    + `选一对歌，看系统怎么决定它们之间的过渡，改参数，然后在底部渲染出来听。`;
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
  const STEM_LABEL = {
    acapella: "acapella over — 出曲人声飘在入曲上",
    instrumental: "instrumental out — 出曲抹掉人声收尾",
    duck: "vocal duck — 出曲人声压低",
  };
  $("#stemSel").innerHTML = ['<option value="none">none（不用 stem）</option>']
    .concat((BOOT.stems || []).map(s => `<option value="${s}">${STEM_LABEL[s] || s}</option>`))
    .join("");
  $("#duckDB").value = Math.abs(BOOT.duckDefaultDB ?? 9);
  $("#knobCount").textContent = BOOT.fields.length;
  paintDuck();
  CONFIG = Object.assign({}, BOOT.standard);
  buildKnobs();
  refreshConfigList(BOOT.configs);
  plan();
}

// ---------------------------------------------------------------- knobs

const GROUPS = {
  tier: "先判断两首歌搭不搭（很搭 / 一般般 / 差异很大）",
  beatmatch: "能不能踩到同一个拍子上",
  overlap: "两首歌该叠多久",
  shape: "从哪里交接、出曲怎么离场",
  stem: "要不要动用人声分离（只在上面的「人声分离可用」打开时才生效）",
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
  $("#diffCount").textContent = diff.length ? `${diff.length} 项和出厂设置不同` : "和出厂设置一致";
  $("#diffBox").innerHTML = diff.length
    ? diff.map(f => `<code>${f.name}</code> ${Number(f.standard).toFixed(f.digits)}`
        + ` → <b>${Number(CONFIG[f.name]).toFixed(f.digits)}</b>`).join(" · ")
    : "当前每一个参数都还是出厂设置。";
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

function paintDuck() {
  const stem = $("#stemSel").value;
  $("#duckBox").style.display = stem === "duck" ? "" : "none";
  $("#duckVal").textContent = `−${Number($("#duckDB").value).toFixed(1)} dB`;
}

function requestBody() {
  const fade = parseFloat($("#fadeOv").value) || 0;
  return {
    outgoing: $("#outSel").value, incoming: $("#inSel").value,
    config: CONFIG, style: $("#styleSel").value, fade: fade,
    stem: $("#stemSel").value,
    stems: $("#stemsReady").checked,
    duckDB: -Math.abs(parseFloat($("#duckDB").value) || 9),
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
    ? `<span>为了对拍各自变速 <code>${((r.plan.outgoingRate - 1) * 100).toFixed(2)}% / `
      + `${((r.plan.incomingRate - 1) * 100).toFixed(2)}%</code></span>`
    : "";
  const PLAN_TEXT = {
    beatMatched: "踩着同一个拍子叠进去",
    crossfade: "普通的交叉淡入淡出",
    gapless: "不做过渡，一首接一首",
  };
  $("#verdict").innerHTML = `
    <b class="chip ${r.tier}">${tierText(r.tier)}</b>
    <b>${PLAN_TEXT[r.plan.kind] || r.plan.kind}</b>
    <span>出曲怎么离场 <code>${r.style.description}</code></span>
    <span>叠多久 <code>${fmt(r.plan.overlapDuration)} 秒${bars}</code></span>
    <span>出曲从 <code>${mmss(r.plan.outPoint)}</code> 开始交接</span>
    <span>入曲从 <code>${mmss(r.plan.inPoint)}</code> 进来</span>
    ${rates}
    ${r.demotedByKey ? '<span class="chip neutral">因为和声不合降了一级</span>' : ""}
    ${r.overridden ? '<span class="chip clash">这一版是手动改过的</span>' : ""}
    <span class="muted" style="font-size:.72rem">（内部术语：${r.tier} / ${r.plan.kind}）</span>`;
  $("#nearMisses").innerHTML = r.nearMisses.length
    ? "⚠︎ 这几项就卡在门槛边上，参数稍微一动结论就会翻过去：" + r.nearMisses.join(" · ") : "";
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

// A whole-mix render takes ~0.3s, a first stem render ~20s (人声分离). Both go
// through the same job + poll path so the page never sits on a dead socket.
const STAGE_TEXT = {planning: "读取决策…", separating: "分离人声…", rendering: "渲染中…"};

function describeRender(r) {
  const bits = [];
  bits.push(r.cached ? "复用已渲染的这一版"
    : `${fmt(r.duration)}s 音频 · ${fmt(r.realtimeFactor, 1)}× 实时`);
  bits.push(`交接在 ${fmt(r.overlapStart)}s`);
  if (r.style) bits.push(`手法 ${r.style}`);
  if (r.stemTechnique) {
    bits.push(`stem ${r.stemTechnique} · 分离 ${fmt(r.stemSeparatedSeconds, 1)}s 用时`
      + ` ${fmt(r.stemSeconds)}s${r.stemCacheHit ? "（缓存命中）" : ""}`);
  }
  let html = bits.join(" · ");
  if (r.stemFallbackReason) {
    html += ` <span class="err">· stem 未生效，已降级为整混渲染：${r.stemFallbackReason}</span>`;
  }
  return html;
}

$("#renderBtn").onclick = async () => {
  const btn = $("#renderBtn");
  btn.disabled = true;
  const t0 = performance.now();
  const tick = (stage, elapsed) =>
    $("#renderInfo").innerHTML = `<span class="spin"></span> ${STAGE_TEXT[stage] || stage}`
      + ` ${elapsed.toFixed(0)}s`;
  tick("planning", 0);
  try {
    const started = await api("/api/render", requestBody());
    let r = null;
    for (;;) {
      const s = await api("/api/render-status/" + encodeURIComponent(started.job));
      if (s.status === "done") { r = s; break; }
      if (s.status === "failed") throw new Error(s.error);
      tick(s.stage, s.elapsed ?? (performance.now() - t0) / 1000);
      await new Promise(res => setTimeout(res, 400));
    }
    LAST_RENDER = r;
    $("#audio").src = r.url + "?t=" + Date.now();
    $("#audio").load();
    $("#renderInfo").innerHTML = describeRender(r);
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
    BATCH = r;
    const changed = r.pairs.filter(p => p.changed).length;
    $("#batchInfo").textContent = changed
      ? `一共 ${r.pairs.length} 对，其中 ${changed} 对的结论被你的改动挪动了（高亮那几行）。`
      : `一共 ${r.pairs.length} 对，结论和出厂设置完全一致。`;
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
      `<tr><th>出 → 入</th><th>搭不搭</th><th>怎么接</th><th>出曲怎么离场</th><th>stem 手法</th>
        <th>叠多久 s</th><th>音量差 dB</th><th>音色差</th><th>出曲交接点</th></tr>` +
      r.pairs.map(p => `<tr class="${p.changed ? "changed" : ""}">
        <td title="${p.outgoing} → ${p.incoming}">${p.outgoing.slice(0, 10)} → ${p.incoming.slice(0, 10)}</td>
        ${cell(p, "tier")}${cell(p, "plan")}${cell(p, "style")}${cell(p, "stem")}
        ${cell(p, "overlap", 2)}
        <td>${fmt(p.loudness)}</td><td>${fmt(p.timbre, 3)}</td><td>${mmss(p.outPoint)}</td>
      </tr>`).join("");
  } catch (e) {
    $("#batchInfo").innerHTML = `<span class="err">${e.message}</span>`;
  }
  btn.disabled = false;
};

// ------------------------------------------------------------------- AI 回路
//
// The console knows everything an outside model would need — what each of the
// 31 knobs means and where it sits, what the five signals said, how the
// decision was derived — but only as pixels. These two buttons turn that into
// text a chat window can read, and read a reply back in. No network call
// leaves this page: the user carries the text across by hand, which is also
// why the reply has to be parsed leniently.

function aiSystemPrompt() {
  const lines = [];
  lines.push("你是一位 DJ 自动过渡（AutoMix）的调参专家。我会给你一套过渡决策系统的完整状态，");
  lines.push("请你像调音师那样判断参数该怎么改，并按我指定的格式回复。");
  lines.push("");
  lines.push("## 这个系统怎么决策");
  lines.push("对每一对相邻的歌，系统先算五项信号，据此定一个“档位”，再决定用什么手法交接：");
  lines.push("1. 音量差（dB）：出曲结尾和入曲开头各取一段的平均响度之差。越大越不适合长叠。");
  lines.push("2. 音色差距（0–1 的余弦距离）：两首歌整体频谱形状的差别。同一首歌自比约 0.03。");
  lines.push("3. 速度差（比例）：两边 BPM 按倍速关系折算后的相对差。够小才谈得上对拍。");
  lines.push("4. 调性远近（五度圈步数 0–6）：只会把“很搭”降一级，从不单独判定“差异很大”。");
  lines.push("5. 人声密度（倍数）：交接窗口内的人声活跃度相对各自整首歌均值。两边都高 = 两个主唱打架。");
  lines.push("");
  lines.push("档位三档：compatible（很搭，可长叠、可对拍）、neutral（一般般，只给短交接）、");
  lines.push("clash（差异很大，只给最短的礼貌淡出）。");
  lines.push("出曲的离场手法有三种：fade（普通淡出）、filterSweep（滤波掏空）、echoOut（拍点上停住留回声），");
  lines.push("外加 stagedEQ（高中低三段分批交接）。另有一组需要人声分离的 stem 手法（见下文上下文）。");
  lines.push("");
  lines.push("## 可调参数（共 " + BOOT.fields.length + " 个）");
  lines.push("格式：名称 | 分组 | 当前值 | 出厂值 | 允许范围 | 含义");
  for (const f of BOOT.fields) {
    lines.push(`${f.name} | ${f.group} | ${Number(CONFIG[f.name]).toFixed(f.digits)}`
      + ` | ${Number(f.standard).toFixed(f.digits)}`
      + ` | ${Number(f.min).toFixed(f.digits)}–${Number(f.max).toFixed(f.digits)}`
      + ` | ${f.blurb}`);
  }
  lines.push("");
  lines.push("超出范围的取值会被系统自动收进范围内；不认识的参数名会被忽略。");
  return lines.join("\n");
}

function aiContext() {
  const r = REPORT;
  const lines = [];
  if (!r) return "（当前没有可用的决策，先在页面上选一对歌。）";
  lines.push("## 当前这一对");
  for (const [role, t] of [["出曲", r.outgoing], ["入曲", r.incoming]]) {
    lines.push(`${role}：${t.name} · 时长 ${mmss(t.duration)} · ${fmt(t.bpm, 1)} BPM`
      + `（把握 ${fmt(t.bpmConfidence)}）· 调 ${t.key || "听不出"}（把握 ${fmt(t.keyConfidence)}）`
      + ` · intro 到 ${mmss(t.introEnd)}`
      + ` · ${t.outroFadeStart != null ? "自带淡出，从 " + mmss(t.outroFadeStart) + " 起" : "结尾没有自带淡出"}`);
  }
  lines.push("");
  lines.push("## 五项信号");
  for (const s of r.signals) {
    const marks = s.marks.map(m => `${m.label} ${fmt(m.value, 3)}(${m.field})`).join("，");
    lines.push(`- ${s.label}：${s.display}　[门槛：${marks}]　判定 ${s.state}`);
    lines.push(`  ${s.verdict}`);
  }
  lines.push("");
  lines.push("## 判断过程");
  r.chain.forEach((c, i) => {
    lines.push(`${i + 1}. ${c.title}${c.fired ? "（这一步改变了结果）" : ""}`);
    lines.push(`   规则：${c.rule}`);
    lines.push(`   数据：${c.detail}`);
    lines.push(`   结果：${c.outcome}`);
  });
  lines.push("");
  lines.push("## 人声分离");
  lines.push(r.stemsReady
    ? `这次告诉规划器人声分离可用，它${r.plannedStemTechnique
        ? "自己选了 " + r.plannedStemTechnique : "没有选任何 stem 手法"}。`
    : "这次没有告诉规划器人声分离可用，stem 那一组参数完全没参与判断。");
  lines.push("");
  lines.push("## 当前结论");
  lines.push(`档位 ${r.tier}（${tierText(r.tier)}）${r.demotedByKey ? "，被和声降过一级" : ""}`
    + ` · 接法 ${r.plan.kind} · 出曲离场手法 ${r.style.description}`
    + ` · 叠加 ${fmt(r.plan.overlapDuration)} 秒`
    + (r.plan.overlapBars ? `（${r.plan.overlapBars} 小节）` : "")
    + ` · 出点 ${mmss(r.plan.outPoint)} · 入点 ${mmss(r.plan.inPoint)}`);
  if (r.nearMisses.length) lines.push("卡在门槛边上的：" + r.nearMisses.join("；"));
  lines.push("");
  lines.push("## 参数相对出厂设置的改动");
  const diff = BOOT.fields.filter(f => Math.abs(CONFIG[f.name] - f.standard) > 1e-12);
  lines.push(diff.length
    ? diff.map(f => `${f.name}: ${Number(f.standard).toFixed(f.digits)}`
        + ` → ${Number(CONFIG[f.name]).toFixed(f.digits)}`).join("\n")
    : "（没有改动，就是出厂设置）");
  lines.push("");
  lines.push("## 全语料分布");
  if (BATCH) {
    const tally = key => {
      const m = {};
      for (const p of BATCH.pairs) m[p[key]] = (m[p[key]] || 0) + 1;
      return Object.entries(m).sort((a, b) => b[1] - a[1])
        .map(([k, v]) => `${k} × ${v}`).join("，");
    };
    lines.push(`共 ${BATCH.pairs.length} 对相邻歌曲。`);
    lines.push(`档位分布：${tally("tier")}`);
    lines.push(`接法分布：${tally("plan")}`);
    lines.push(`离场手法分布：${tally("style")}`);
    const changed = BATCH.pairs.filter(p => p.changed);
    lines.push(changed.length
      ? `与出厂设置结论不同的 ${changed.length} 对：`
        + changed.map(p => `${p.outgoing} → ${p.incoming}`).join("；")
      : "与出厂设置的结论完全一致。");
  } else {
    lines.push("（还没跑过批量视图，没有分布数据。）");
  }
  return lines.join("\n");
}

const AI_OUTPUT_SPEC = `## 请这样回复

先用几句话说你的判断，然后给出**一个** fenced JSON 代码块，格式如下：

\`\`\`json
{
  "config": {"参数名": 新值, "另一个参数名": 新值},
  "styleOverride": "auto | plain | sweep | echo | staged",
  "stem": "none | acapella | instrumental | duck",
  "rationale": "为什么这么改，一两句话"
}
\`\`\`

约束：
- "config" 里只放你真的想改的参数，用上面表格里的准确名称，值必须是数字。
- "styleOverride" 和 "stem" 可以省略；省略就表示保持现状。
- "rationale" 用中文，说清楚你想让听感往哪个方向走。
- 只给一个 JSON 块，不要给多个候选方案。`;

function aiBundle() {
  return [aiSystemPrompt(), "", "=".repeat(60), "", aiContext(), "", "=".repeat(60), "",
          AI_OUTPUT_SPEC].join("\n");
}

/// The console is served over plain HTTP on a LAN address, so
/// `navigator.clipboard` is usually unavailable (it needs a secure context).
/// Fall back to the old selection + execCommand path, and if even that is
/// refused, hand the user a pre-selected textarea to copy by hand.
async function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    try { await navigator.clipboard.writeText(text); return "clipboard"; } catch (e) { /* fall through */ }
  }
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.setAttribute("readonly", "");
  ta.style.cssText = "position:fixed;top:0;left:0;width:1px;height:1px;opacity:0";
  document.body.appendChild(ta);
  ta.select();
  ta.setSelectionRange(0, text.length);
  let ok = false;
  try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
  document.body.removeChild(ta);
  return ok ? "execCommand" : "manual";
}

$("#copyAI").onclick = async () => {
  const text = aiBundle();
  const how = await copyText(text);
  const box = $("#copyFallback");
  if (how === "manual") {
    box.style.display = "";
    box.value = text;
    box.focus();
    box.select();
    $("#copyInfo").innerHTML =
      '<span class="err">浏览器不让脚本写剪贴板（非 HTTPS 页面）。文本已全选，按 ⌘C 复制。</span>';
  } else {
    box.style.display = "none";
    $("#copyInfo").textContent =
      `已复制 ${text.length} 个字符（含 system prompt、当前上下文、回复格式三段）。`;
  }
};

/// Pull the first JSON object out of whatever the model wrote. Fenced block
/// first, then the first balanced `{…}` anywhere in the text — models put
/// prose on both sides of it more often than not.
function extractJSON(raw) {
  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const candidates = [];
  if (fenced) candidates.push(fenced[1]);
  const start = raw.indexOf("{");
  if (start >= 0) {
    let depth = 0, inString = false, escaped = false;
    for (let i = start; i < raw.length; i++) {
      const ch = raw[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') inString = true;
      else if (ch === "{") depth++;
      else if (ch === "}" && --depth === 0) { candidates.push(raw.slice(start, i + 1)); break; }
    }
  }
  for (const c of candidates) {
    try {
      const v = JSON.parse(c);
      if (v && typeof v === "object" && !Array.isArray(v)) return v;
    } catch (e) { /* try the next candidate */ }
  }
  return null;
}

let PENDING_AI = null;

$("#parseAI").onclick = () => {
  const raw = $("#aiPaste").value.trim();
  const preview = $("#aiPreview");
  $("#applyAI").style.display = $("#cancelAI").style.display = "none";
  PENDING_AI = null;
  if (!raw) { preview.innerHTML = '<span class="err">先把 AI 的回复粘进上面的框里。</span>'; return; }

  const parsed = extractJSON(raw);
  if (!parsed) {
    preview.innerHTML = '<span class="err">在这段文字里没找到能解析的 JSON。'
      + '让 AI 用 ```json 代码块把结果包起来再试一次。</span>';
    return;
  }
  const cfg = parsed.config;
  if (cfg !== undefined && (typeof cfg !== "object" || cfg === null || Array.isArray(cfg))) {
    preview.innerHTML = '<span class="err">JSON 里的 "config" 不是一个对象。</span>';
    return;
  }

  const accepted = {}, rows = [], ignored = [], bad = [];
  for (const [name, value] of Object.entries(cfg || {})) {
    const f = BOOT.fields.find(x => x.name === name);
    if (!f) { ignored.push(name); continue; }
    const n = typeof value === "number" ? value : parseFloat(value);
    if (!isFinite(n)) { bad.push(`${name}=${JSON.stringify(value)}`); continue; }
    // Same clamp the server applies to every override, applied here too so
    // the preview shows the value that will actually take effect.
    const clamped = Math.min(Math.max(n, f.min), f.max);
    if (Math.abs(clamped - CONFIG[name]) < 1e-12) continue;
    accepted[name] = clamped;
    rows.push(`<code>${name}</code> ${Number(CONFIG[name]).toFixed(f.digits)}`
      + ` → <b>${clamped.toFixed(f.digits)}</b>`
      + (Math.abs(clamped - n) > 1e-9
         ? ` <span class="err">（原本给的是 ${n}，超出 ${f.min}–${f.max}，已收进范围）</span>` : ""));
  }

  let style = null;
  if (typeof parsed.styleOverride === "string") {
    const s = parsed.styleOverride.trim();
    if (s === "auto" || BOOT.styles.includes(s)) style = s;
    else bad.push(`styleOverride=${JSON.stringify(parsed.styleOverride)}`);
  }
  let stem = null;
  if (typeof parsed.stem === "string") {
    const s = parsed.stem.trim();
    if (s === "none" || (BOOT.stems || []).includes(s)) stem = s;
    else bad.push(`stem=${JSON.stringify(parsed.stem)}`);
  }

  const notes = [];
  if (rows.length) notes.push("<b>要改的参数</b><br>" + rows.join("<br>"));
  if (style) notes.push(`<b>出曲离场手法</b> 改为 <code>${style}</code>`);
  if (stem) notes.push(`<b>stem 手法</b> 改为 <code>${stem}</code>`);
  if (parsed.rationale) notes.push(`<b>AI 给的理由</b><br>${String(parsed.rationale)}`);
  if (ignored.length) {
    notes.push(`<span class="err">这些名字不存在，已忽略：${ignored.join("、")}</span>`);
  }
  if (bad.length) {
    notes.push(`<span class="err">这些取值不合法，已拒绝：${bad.join("、")}</span>`);
  }
  if (!rows.length && !style && !stem) {
    notes.push('<span class="err">解析出来了，但没有一项是能应用的改动。</span>');
    preview.innerHTML = notes.join("<br><br>");
    return;
  }
  PENDING_AI = {config: accepted, style: style, stem: stem};
  preview.innerHTML = notes.join("<br><br>");
  $("#applyAI").style.display = $("#cancelAI").style.display = "";
};

$("#applyAI").onclick = () => {
  if (!PENDING_AI) return;
  if (PENDING_AI.style) $("#styleSel").value = PENDING_AI.style;
  if (PENDING_AI.stem) { $("#stemSel").value = PENDING_AI.stem; paintDuck(); }
  $("#applyAI").style.display = $("#cancelAI").style.display = "none";
  const applied = Object.keys(PENDING_AI.config).length;
  applyConfig(Object.assign({}, CONFIG, PENDING_AI.config));   // re-plans
  BATCH = null;
  $("#aiPreview").innerHTML = `已应用${applied ? ` ${applied} 项参数改动` : "手法改动"}，决策已重算。`;
  PENDING_AI = null;
};

$("#cancelAI").onclick = () => {
  PENDING_AI = null;
  $("#applyAI").style.display = $("#cancelAI").style.display = "none";
  $("#aiPreview").innerHTML = "";
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
$("#stemSel").onchange = () => { paintDuck(); plan(); };
$("#stemsReady").onchange = () => { BATCH = null; plan(); };
$("#duckDB").oninput = () => { paintDuck(); schedulePlan(); };

boot().catch(e => { $("#lead").textContent = "启动失败：" + e.message; });
</script>
</body>
</html>
"""#
#endif
