#!/usr/bin/env python3
"""Render the coupling graph as one self-contained HTML blueprint.

Zero external requests: SVG plus vanilla JS, data inlined. Opens from disk.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from .graph import build

TEMPLATE = r"""<!doctype html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>__TITLE__</title>
<style>
  :root{
    --ground:#e6eae6; --surface:#f1f4f0; --raised:#fafbf9; --panel:#eef1ed;
    --ink:#141b19; --ink-mid:#3d4a47; --ink-soft:#68746f;
    --rule:#c8d0cb; --rule-soft:#d8ded9;
    --signal:#2c7a6f; --signal-soft:#d7e7e3;
    --entry:#8a6c22; --entry-soft:#efe6cf;
    --field:#5a6a7d; --field-soft:#dfe4ea;
    --flag:#a8442f; --flag-soft:#f3ddd6;
    --sans:"PingFang SC","Hiragino Sans GB","Microsoft YaHei","Segoe UI",system-ui,sans-serif;
    --mono:ui-monospace,SFMono-Regular,"SF Mono","Cascadia Mono",Consolas,monospace;
  }
  @media (prefers-color-scheme:dark){ :root:not([data-theme="light"]){
    --ground:#101514; --surface:#171e1c; --raised:#1d2523; --panel:#141a19;
    --ink:#dde5e1; --ink-mid:#a9b6b1; --ink-soft:#7f8d88;
    --rule:#2b3533; --rule-soft:#222b29;
    --signal:#57b8aa; --signal-soft:#17322e;
    --entry:#c2a04a; --entry-soft:#2c2617;
    --field:#8fa3ba; --field-soft:#1b2430;
    --flag:#d4765c; --flag-soft:#33201b;
  }}
  :root[data-theme="dark"]{
    --ground:#101514; --surface:#171e1c; --raised:#1d2523; --panel:#141a19;
    --ink:#dde5e1; --ink-mid:#a9b6b1; --ink-soft:#7f8d88;
    --rule:#2b3533; --rule-soft:#222b29;
    --signal:#57b8aa; --signal-soft:#17322e;
    --entry:#c2a04a; --entry-soft:#2c2617;
    --field:#8fa3ba; --field-soft:#1b2430;
    --flag:#d4765c; --flag-soft:#33201b;
  }
  *,*::before,*::after{box-sizing:border-box}
  html,body{height:100%}
  body{margin:0; background:var(--ground); color:var(--ink); font-family:var(--sans);
       display:grid; grid-template-rows:auto 1fr; overflow:hidden}
  :focus-visible{outline:2px solid var(--signal); outline-offset:2px}

  /* ---- top bar ---- */
  .bar{display:flex; flex-wrap:wrap; gap:14px; align-items:center;
       padding:11px 16px; border-bottom:1px solid var(--rule); background:var(--surface)}
  .bar h1{margin:0; font-size:15px; font-weight:700; letter-spacing:-.01em}
  .bar h1 span{font-family:var(--mono); font-weight:400; font-size:11.5px;
               color:var(--ink-soft); letter-spacing:.06em; margin-left:8px}
  .stats{display:flex; gap:13px; font-family:var(--mono); font-size:11px;
         color:var(--ink-soft); font-variant-numeric:tabular-nums}
  .stats b{color:var(--ink); font-weight:600}
  .live{font-family:var(--mono); font-size:10px; letter-spacing:.1em; color:var(--signal)}
  .live.stale{color:var(--flag)}
  .spacer{flex:1}
  .ctl{display:flex; gap:7px; align-items:center; font-size:12px; color:var(--ink-mid)}
  .ctl label{display:flex; gap:5px; align-items:center; cursor:pointer; user-select:none}
  input[type=search]{
    font:inherit; font-size:12px; padding:5px 9px; width:150px; color:var(--ink);
    background:var(--raised); border:1px solid var(--rule); border-radius:3px;
  }
  button.mini{
    font:inherit; font-size:11.5px; font-family:var(--mono); padding:5px 10px; cursor:pointer;
    background:var(--raised); color:var(--ink-mid); border:1px solid var(--rule); border-radius:3px;
  }
  button.mini:hover{border-color:var(--signal); color:var(--signal)}

  /* ---- stage ---- */
  .stage{position:relative; overflow:hidden; background:var(--ground)}
  svg{position:absolute; inset:0; width:100%; height:100%; cursor:grab; touch-action:none}
  svg.drag{cursor:grabbing}
  .lane{fill:var(--surface); opacity:.55}
  .lanelbl{font-family:var(--mono); font-size:10px; fill:var(--ink-soft); letter-spacing:.13em}
  .bandlbl{font-size:19px; font-weight:800; fill:var(--ink); opacity:.4}
  .bandnote{font-family:var(--mono); font-size:10.5px; fill:var(--ink-soft); opacity:.75}
  .bandrule{stroke:var(--rule); stroke-width:1}
  .edge{fill:none; stroke:var(--rule); stroke-width:1.2}
  .edge.state{stroke-dasharray:3 4; opacity:.32; stroke-width:1}
  .edge.hot{stroke:var(--signal); stroke-width:2; opacity:1}
  .edge.dim{opacity:.08}
  .n rect,.n polygon{stroke-width:1.4}
  .n text{font-size:11.5px; fill:var(--ink); dominant-baseline:middle}
  .n .sub{font-family:var(--mono); font-size:9px; fill:var(--ink-soft)}
  .n{cursor:pointer}
  .n.dim{opacity:.16}
  .n.sel rect,.n.sel polygon{stroke:var(--ink); stroke-width:2.4}
  .k-rule rect{fill:var(--raised); stroke:var(--rule)}
  .k-signal polygon{fill:var(--signal-soft); stroke:var(--signal)}
  .k-signal text{fill:var(--signal); font-family:var(--mono); font-size:11px}
  .k-entry rect{fill:var(--entry-soft); stroke:var(--entry)}
  .k-entry text{fill:var(--entry); font-family:var(--mono); font-size:10.5px}
  .k-state polygon,.k-world polygon{fill:var(--field-soft); stroke:var(--field)}
  .k-state text,.k-world text{fill:var(--field); font-family:var(--mono); font-size:10.5px}
  .flagged rect,.flagged polygon{fill:var(--flag-soft)!important; stroke:var(--flag)!important}
  .flagged text{fill:var(--flag)!important}

  /* ---- side panel ---- */
  .panel{
    position:absolute; top:0; right:0; bottom:0; width:min(430px,50vw);
    background:var(--panel); border-left:1px solid var(--rule);
    display:flex; flex-direction:column; transform:translateX(100%);
    transition:transform .16s ease; z-index:5;
  }
  .panel.open{transform:none}
  @media (prefers-reduced-motion:reduce){ .panel{transition:none} }
  .ph{padding:13px 16px; border-bottom:1px solid var(--rule); display:flex; gap:10px; align-items:flex-start}
  .ph h2{margin:0; font-size:14.5px; font-weight:700; word-break:break-all; line-height:1.45}
  .ph .kind{font-family:var(--mono); font-size:9.5px; letter-spacing:.13em; text-transform:uppercase;
            color:var(--ink-soft); display:block; margin-bottom:3px}
  .ph button{margin-left:auto; flex:none}
  .pb{overflow:auto; padding:14px 16px 30px; flex:1}
  .kv{margin:0 0 13px; font-size:12.5px}
  .kv dt{font-family:var(--mono); font-size:9.5px; letter-spacing:.12em; text-transform:uppercase;
         color:var(--ink-soft); margin-bottom:4px}
  .kv dd{margin:0; color:var(--ink-mid); line-height:1.7; word-break:break-word}
  .kv dd code{font-family:var(--mono); font-size:11.5px; background:var(--surface);
              border:1px solid var(--rule-soft); border-radius:2px; padding:1px 5px; margin:0 3px 3px 0;
              display:inline-block; color:var(--ink)}
  .kv dd .none{color:var(--ink-soft); font-style:italic}
  .warn{background:var(--flag-soft); border:1px solid var(--flag); border-radius:3px;
        padding:10px 12px; margin-bottom:14px; font-size:12.5px; color:var(--ink)}
  .warn b{color:var(--flag); font-family:var(--mono); font-size:9.5px; letter-spacing:.12em;
          text-transform:uppercase; display:block; margin-bottom:4px}
  pre{margin:0; overflow-x:auto; background:var(--surface); border:1px solid var(--rule-soft);
      border-radius:3px; padding:12px; font-family:var(--mono); font-size:11px; line-height:1.6;
      color:var(--ink-mid)}
  button.pill{background:var(--flag-soft); border-color:var(--flag); color:var(--flag)}
  button.pill:hover{border-color:var(--flag); color:var(--flag)}
  ul.flist{list-style:none; margin:0; padding:0; display:grid; gap:7px}
  ul.flist li{background:var(--flag-soft); border:1px solid var(--flag); border-radius:3px;
              padding:9px 12px; font-size:12.5px; cursor:pointer; color:var(--ink); line-height:1.6}
  ul.flist li code{font-family:var(--mono); color:var(--flag); font-size:11.5px; display:block;
                   margin-bottom:2px}
  .legend{position:absolute; right:14px; bottom:14px; z-index:3; display:flex; gap:12px;
          background:var(--surface); border:1px solid var(--rule); border-radius:3px;
          padding:8px 12px; font-family:var(--mono); font-size:10px; color:var(--ink-soft)}
  .legend i{display:inline-block; width:9px; height:9px; margin-right:4px; vertical-align:-1px;
            border:1.2px solid}
  .legend .e{background:var(--entry-soft); border-color:var(--entry)}
  .legend .s{background:var(--signal-soft); border-color:var(--signal)}
  .legend .r{background:var(--raised); border-color:var(--rule)}
  .legend .f{background:var(--field-soft); border-color:var(--field)}
</style>
</head>
<body>

<div class="bar">
  <h1><span id="title">__GAME__</span> <span>耦合蓝图</span></h1>
  <div class="stats" id="stats">__STATS__</div>
  <span class="live" id="live" hidden>● 实时</span>
  <div class="spacer"></div>
  <div class="ctl">
    <button class="mini pill" id="fPill" hidden></button>
    <label><input type="checkbox" id="tState" checked> 状态耦合</label>
    <input type="search" id="q" placeholder="搜索节点…" aria-label="搜索节点">
    <button class="mini" id="fit">全景</button>
  </div>
</div>

<div class="stage" id="stage">
  <svg id="svg" aria-label="规则耦合图"><g id="cam"></g></svg>
  <div class="legend">
    <span><i class="e"></i>按钮</span><span><i class="s"></i>信号</span>
    <span><i class="r"></i>规则</span><span><i class="f"></i>状态</span>
    <span>—— 信号</span><span>- - 状态</span>
  </div>
  <aside class="panel" id="panel" aria-live="polite">
    <div class="ph">
      <div><span class="kind" id="pKind"></span><h2 id="pName"></h2></div>
      <button class="mini" id="pClose">关闭</button>
    </div>
    <div class="pb" id="pBody"></div>
  </aside>
</div>

<script>
const NS = "http://www.w3.org/2000/svg";
const KIND = {entry:"按钮 · 玩家入口", signal:"信号 · 总线", rule:"规则",
              state:"实体状态字段", world:"世界状态字段"};
const NW = {rule:186, signal:150, entry:172, state:132, world:142};
const NH = 30, COLW = 258, ROWH = 44;

/* Camera survives a reload on purpose: editing a rule file should not throw away
   where you were looking. */
let cx = 0, cy = 0, cs = 1, everFit = false;
let G = null, byId = new Map(), nodeEls = new Map(), edgeEls = [], sel = null;
const svg = document.getElementById("svg"), stage = document.getElementById("stage"),
      cam = document.getElementById("cam"), panel = document.getElementById("panel");

function initGraph(data) {
  G = data;
  while (cam.firstChild) cam.removeChild(cam.firstChild);
  nodeEls = new Map(); edgeEls = []; sel = null;
  document.getElementById("stats").innerHTML =
    Object.entries(G.stats).map(([k, v]) => `<span>${k} <b>${v}</b></span>`).join("");
  document.getElementById("title").textContent = (G.game || "").replace("demo_", "");

/* ---- layout: layered by reach, then barycentre-ordered to cut crossings ---- */
const byId_ = new Map(G.nodes.map(n => [n.id, n]));
byId = byId_;
const nbr = new Map(G.nodes.map(n => [n.id, []]));
for (const e of G.edges) { nbr.get(e.a).push(e.b); nbr.get(e.b).push(e.a); }

/* Two bands stacked: player-driven above, clock-driven below. Layers run
   left-to-right INSIDE each band, and a barycentre pass reorders each layer to
   cut edge crossings — without it the columns are alphabetical and the wires
   cross the whole canvas. */
const bands = G.bands.map(b => {
  const ns = G.nodes.filter(n => n.band === b.key);
  const layers = [];
  for (const n of ns) (layers[n.layer] ||= []).push(n);
  layers.forEach(L => L && L.sort((a, b2) =>
    (a.sub || "").localeCompare(b2.sub || "") || a.label.localeCompare(b2.label)));
  layers.forEach(L => L && L.forEach((n, i) => n.ord = i));
  for (let pass = 0; pass < 4; pass++) for (const L of layers) {
    if (!L) continue;
    for (const n of L) {
      const o = nbr.get(n.id).map(m => byId.get(m)).filter(m => m && m.layer !== n.layer);
      n.bary = o.length ? o.reduce((t, m) => t + m.ord, 0) / o.length : n.ord;
    }
    L.sort((a, b2) => a.bary - b2.bary || a.label.localeCompare(b2.label));
    L.forEach((n, i) => n.ord = i);
  }
  return {...b, layers, rows: Math.max(1, ...layers.filter(Boolean).map(L => L.length)),
          cols: layers.length};
});

let yTop = 0, maxCols = 0;
const BANDPAD = 78;
for (const b of bands) {
  b.y0 = yTop;
  b.layers.forEach((L, li) => L && L.forEach((n, i) => {
    n.x = 40 + li * COLW; n.y = yTop + BANDPAD + i * ROWH; n.w = NW[n.kind] || 160;
  }));
  b.h = BANDPAD + b.rows * ROWH + 26;
  yTop += b.h;
  maxCols = Math.max(maxCols, b.cols);
}
const W = 40 + maxCols * COLW + 60, H = yTop + 30;

/* ---- draw ---- */
const el = (t, a) => { const x = document.createElementNS(NS, t);
  for (const k in a) x.setAttribute(k, a[k]); return x; };

for (const b of bands) {
  const g = el("g", {});
  b.layers.forEach((L, li) => {
    if (!L || !L.length) return;
    g.appendChild(el("rect", {class:"lane", x: 40 + li*COLW - 14, y: b.y0 + 40,
      width: COLW - 24, height: b.h - 52, rx: 4}));
    const t = el("text", {class:"lanelbl", x: 40 + li*COLW - 6, y: b.y0 + 56});
    t.textContent = li === 0 ? (b.key === "player" ? "0 · 按下按钮" : "0 · 时钟走一格")
                             : li + " 步之后";
    g.appendChild(t);
  });
  // Left-aligned. Right-aligned put them under the side panel, which opens on
  // load — so the two most important labels on the page were invisible in the
  // default view.
  const bl = el("text", {class:"bandlbl", x: 26, y: b.y0 + 24});
  bl.textContent = b.label;
  g.appendChild(bl);
  const bn = el("text", {class:"bandnote", x: 26, y: b.y0 + 24, dy: "1.45em"});
  bn.textContent = b.note;
  g.appendChild(bn);
  if (b.y0 > 0) g.appendChild(el("line", {class:"bandrule", x1: 20, y1: b.y0 + 8,
                                          x2: W - 40, y2: b.y0 + 8}));
  cam.appendChild(g);
}

const gE = el("g", {}); cam.appendChild(gE);
for (const e of G.edges) {
  const a = byId.get(e.a), b = byId.get(e.b);
  if (!a || !b) continue;
  const x1 = a.x + a.w, y1 = a.y + NH/2, x2 = b.x, y2 = b.y + NH/2;
  const dx = Math.max(34, Math.abs(x2 - x1) * .45);
  const p = el("path", {class:"edge " + e.kind,
    d:`M${x1},${y1} C${x1+dx},${y1} ${x2-dx},${y2} ${x2},${y2}`});
  gE.appendChild(p); edgeEls.push({p, e});
}

const gN = el("g", {}); cam.appendChild(gN);
for (const n of G.nodes) {
  const g = el("g", {class:`n k-${n.kind}` + (n.flag ? " flagged" : ""), tabindex:"0",
                     role:"button", "aria-label": n.label});
  const diamondish = n.kind === "signal" || n.kind === "state" || n.kind === "world";
  if (diamondish) {
    const k = 11;
    g.appendChild(el("polygon", {points:
      `${n.x+k},${n.y} ${n.x+n.w},${n.y} ${n.x+n.w-k},${n.y+NH} ${n.x},${n.y+NH}`}));
  } else {
    g.appendChild(el("rect", {x:n.x, y:n.y, width:n.w, height:NH, rx:3}));
  }
  const t = el("text", {x:n.x + (diamondish ? 16 : 9), y:n.y + NH/2});
  const max = Math.floor((n.w - 26) / 6.6);
  t.textContent = n.label.length > max ? n.label.slice(0, max - 1) + "…" : n.label;
  g.appendChild(t);
  if (n.kind === "rule" && n.sub) {
    const s = el("text", {class:"sub", x:n.x + n.w - 6, y:n.y + NH/2, "text-anchor":"end"});
    s.textContent = n.sub; g.appendChild(s);
  }
  g.addEventListener("click", () => select(n.id));
  g.addEventListener("keydown", ev => { if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); select(n.id); } });
  gN.appendChild(g); nodeEls.set(n.id, g);
}

  GW = W; GH = H;
  if (!everFit) { fit(); everFit = true; } else apply();
  wireFindings();
}

/* ---- camera (bound once, not per reload) ---- */
let GW = 1000, GH = 800;
const apply = () => cam.setAttribute("transform", `translate(${cx},${cy}) scale(${cs})`);
function fit() {
  const r = stage.getBoundingClientRect();
  cs = Math.min(r.width / GW, r.height / GH, 1) * .96;
  cx = (r.width - GW * cs) / 2; cy = (r.height - GH * cs) / 2; apply();
}
document.getElementById("fit").addEventListener("click", fit);
addEventListener("resize", fit);
let drag = null;
svg.addEventListener("pointerdown", e => { drag = {x:e.clientX - cx, y:e.clientY - cy};
  svg.classList.add("drag"); svg.setPointerCapture(e.pointerId); });
svg.addEventListener("pointermove", e => { if (!drag) return;
  cx = e.clientX - drag.x; cy = e.clientY - drag.y; apply(); });
svg.addEventListener("pointerup", () => { drag = null; svg.classList.remove("drag"); });
svg.addEventListener("wheel", e => {
  e.preventDefault();
  const r = stage.getBoundingClientRect(), mx = e.clientX - r.left, my = e.clientY - r.top;
  const k = Math.exp(-e.deltaY * .0014), ns = Math.min(2.4, Math.max(.12, cs * k));
  cx = mx - (mx - cx) * (ns / cs); cy = my - (my - cy) * (ns / cs); cs = ns; apply();
}, {passive:false});

/* ---- selection + focus ---- */
function clearHL() {
  nodeEls.forEach(g => g.classList.remove("dim", "sel"));
  edgeEls.forEach(({p}) => p.classList.remove("hot", "dim"));
}
function select(id) {
  const n = byId.get(id); if (!n) return;
  sel = id; clearHL();
  const keep = new Set([id]);
  edgeEls.forEach(({p, e}) => {
    if (e.a === id || e.b === id) { p.classList.add("hot"); keep.add(e.a); keep.add(e.b); }
    else p.classList.add("dim");
  });
  nodeEls.forEach((g, k) => { if (!keep.has(k)) g.classList.add("dim"); });
  nodeEls.get(id).classList.add("sel");
  showPanel(n);
}
function esc(s) { return String(s).replace(/[&<>]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;"}[c])); }
function chips(v) {
  if (!v || (Array.isArray(v) && !v.length)) return '<span class="none">无</span>';
  if (!Array.isArray(v)) return esc(v);
  return v.map(x => `<code>${esc(x)}</code>`).join("");
}
function showPanel(n) {
  document.getElementById("pKind").textContent = KIND[n.kind] || n.kind;
  document.getElementById("pName").textContent = n.label;
  let h = "";
  const f = G.findings.filter(x => x.node === n.id);
  for (const x of f) h += `<div class="warn"><b>断开的边</b>${esc(x.why)}</div>`;
  h += '<dl class="kv">';
  for (const k in (n.detail || {})) h += `<dt>${esc(k)}</dt><dd>${chips(n.detail[k])}</dd>`;
  h += "</dl>";
  if (n.json) h += `<dl class="kv"><dt>真正的 JSON</dt></dl><pre>${esc(JSON.stringify(n.json, null, 2))}</pre>`;
  document.getElementById("pBody").innerHTML = h;
  panel.classList.add("open");
}
document.getElementById("pClose").addEventListener("click", () => {
  panel.classList.remove("open"); clearHL(); sel = null;
});

/* ---- state-edge toggle + search ---- */
document.getElementById("tState").addEventListener("change", e => {
  const on = e.target.checked;
  edgeEls.forEach(({p, e:d}) => { if (d.kind === "state") p.style.display = on ? "" : "none"; });
});
document.getElementById("q").addEventListener("input", e => {
  const v = e.target.value.trim().toLowerCase();
  if (!v) { clearHL(); return; }
  clearHL();
  nodeEls.forEach((g, k) => {
    if (!byId.get(k).label.toLowerCase().includes(v)) g.classList.add("dim");
  });
});

/* ---- findings: shown in the panel on load, reopened from the bar ---- */
function wireFindings() {
  const pill = document.getElementById("fPill");
  pill.hidden = !G.findings.length;
  if (!G.findings.length) { panel.classList.remove("open"); return; }
  pill.textContent = G.findings.length + " 处断开";
  showFindings();
}
function showFindings() {
  document.getElementById("pKind").textContent = "静态分析";
  document.getElementById("pName").textContent = G.findings.length + " 处断开的边";
  document.getElementById("pBody").innerHTML =
    '<dl class="kv"><dd>每一条都是「有人写/发，但没有任何东西读/听」。' +
    '不会报错，不会失败测试 — 只是那个效果的结果永远不会被任何人看见。点一条跳到图上。</dd></dl>' +
    '<ul class="flist">' + G.findings.map(f =>
      `<li data-n="${esc(f.node)}"><code>${esc(byId.get(f.node)?.label || f.node)}</code>${esc(f.why)}</li>`
    ).join("") + "</ul>";
  document.getElementById("pBody").querySelectorAll("li").forEach(li =>
    li.addEventListener("click", () => select(li.dataset.n)));
  panel.classList.add("open");
}
document.getElementById("fPill").addEventListener("click", showFindings);

__BOOTSTRAP__
</script>
</body>
</html>
"""


# The two bootstraps are the ONLY difference between a baked file and the live
# server. Everything above — layout, drawing, selection, the panel — is one view,
# so a change to how the graph reads cannot drift between the two modes.
BOOT_STATIC = "initGraph(__DATA__);"

BOOT_LIVE = """
const liveEl = document.getElementById("live");
liveEl.hidden = false;
async function load() {
  try {
    const r = await fetch("/api/graph?game=" + encodeURIComponent(GAME));
    initGraph(await r.json());
    liveEl.classList.remove("stale");
    liveEl.textContent = "● 实时";
  } catch (e) {
    liveEl.classList.add("stale");
    liveEl.textContent = "● 断开";
  }
}
load();
// Server-Sent Events, not a WebSocket: this push is one-way (the server says
// "the files changed"), so the simpler transport is the honest one and it needs
// no dependency beyond the stdlib on the server side.
const es = new EventSource("/api/events");
es.addEventListener("changed", load);
es.addEventListener("error", () => {
  liveEl.classList.add("stale");
  liveEl.textContent = "● 断开";
});
"""


def page(game: str, data: dict | None) -> str:
    """One template, two data sources. `data=None` -> live (fetch + SSE)."""
    stats = "".join(f"<span>{k} <b>{v}</b></span>" for k, v in (data or {}).get("stats", {}).items())
    boot = (BOOT_STATIC.replace("__DATA__", json.dumps(data, ensure_ascii=False))
            if data is not None
            else f"const GAME = {json.dumps(game)};" + BOOT_LIVE)
    return (TEMPLATE
            .replace("__TITLE__", f"{game} · 耦合蓝图")
            .replace("__GAME__", game.replace("demo_", ""))
            .replace("__STATS__", stats)
            .replace("__BOOTSTRAP__", boot))


def render(game: str, out: Path) -> Path:
    out.write_text(page(game, build(game)), encoding="utf-8")
    return out


if __name__ == "__main__":
    game = sys.argv[1] if len(sys.argv) > 1 else "demo_thousandgate"
    dest = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(f"/tmp/{game}_blueprint.html")
    p = render(game, dest)
    print(f"{p}  ({p.stat().st_size} bytes)")
