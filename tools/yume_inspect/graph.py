#!/usr/bin/env python3
"""Turn the derived couplings into a layered node graph.

WHY SIGNALS AND FIELDS ARE NODES, NOT WIRES
-------------------------------------------
The tempting shape is point-to-point: rule A wires to rule B. It is wrong twice
over. A signal usually has several producers AND several consumers — `descend`
is emitted by a button and consumed by three rules — so point-to-point turns one
named bus into a mesh of identical lines. And a state field is not a wire at all;
it is a location that anyone may write and anyone may read, with no ordering
implied.

Modelling both as NODES says the true thing: play flows

    button -> [signal] -> rule -> [state field] -> rule

and the two node kinds in brackets are exactly the couplings that were invisible
before. Every bug this tool was built for is a missing edge on one of them.

LAYERS ARE REACH, NOT EXECUTION ORDER. A rule's layer is its distance from a
player action. That is honest — Yume's real execution order comes from the phase
scheduler and before/after, which no layout can express — and it is also the
useful reading: layer 0 is what the player touches, and the far right is what
happens as a consequence several steps later.
"""
from __future__ import annotations

import json
from collections import deque
from pathlib import Path

from .analyze import analyze, _queries_engine, _query_state_keys

SUBSYS = {
    "02_calendar": "日历", "03_social": "社交", "04_work_and_debt": "工作与债务",
    "05_conversation": "对话", "06_calendar_display": "日历显示",
    "07_contracts": "委托", "08_descent": "下潜",
}


def _subsys(rule_file: str) -> str:
    stem = Path(rule_file).stem
    return SUBSYS.get(stem, stem)


def build(game: str) -> dict:
    a = analyze(game)
    rules = a["rules"]
    by_id = {r.id: r for r in rules}

    nodes: dict[str, dict] = {}
    edges: list[dict] = []

    def node(nid: str, **kw) -> None:
        if nid not in nodes:
            nodes[nid] = {"id": nid, **kw}

    # ---- rule nodes -------------------------------------------------
    for r in rules:
        reads = sorted(r.reads)
        node(f"r:{r.id}", kind="rule", label=r.id, sub=_subsys(r.file),
             file=r.file, trigger=r.trigger,
             detail={
                 "触发": r.trigger + (f"  ({r.signal_in})" if r.signal_in else ""),
                 "文件": r.file,
                 "可用绑定": sorted(r.bindings),
                 "查询读取": reads,
                 "写入(实体)": sorted(r.writes),
                 "写入(世界)": sorted(r.world_writes),
                 "读取(世界)": sorted(r.world_reads),
                 "发出信号": r.signals_out,
             },
             json=r.raw)

    # ---- signal nodes ------------------------------------------------
    for s in a["signals"]:
        sid = f"s:{s['name']}"
        node(sid, kind="signal", label=s["name"], sub="信号",
             detail={"规则生产者": s["rule_producers"],
                     "界面生产者": s["ui_producers"],
                     "消费者": s["consumers"]})
        for p in s["rule_producers"]:
            if f"r:{p}" in nodes:
                edges.append({"a": f"r:{p}", "b": sid, "kind": "signal"})
        for u in s["ui_producers"]:
            uid = f"u:{u}"
            node(uid, kind="entry", label=u, sub="界面",
                 detail={"说明": "玩家按钮 — 一局游戏真正的起点"})
            edges.append({"a": uid, "b": sid, "kind": "signal"})
        for c in s["consumers"]:
            if f"r:{c}" in nodes:
                edges.append({"a": sid, "b": f"r:{c}", "kind": "signal"})

    # ---- state nodes: only fields that actually COUPLE two rules ------
    # A field one rule owns end to end is not a coupling and would only add
    # noise; the graph exists to show where two rules meet without saying so.
    ent_w: dict[str, set[str]] = {}
    ent_r: dict[str, set[str]] = {}
    for r in rules:
        for f in r.writes:
            ent_w.setdefault(f, set()).add(r.id)
        for f in r.reads:
            if not _queries_engine(r.raw):
                ent_r.setdefault(f, set()).add(r.id)
        for b, path in r.refs:
            if b == "world":
                continue
            parts = path.split(".")
            if len(parts) >= 2 and parts[0] == "state":
                ent_r.setdefault(parts[1], set()).add(r.id)

    for f in sorted(set(ent_w) | set(ent_r)):
        w, rd = ent_w.get(f, set()), ent_r.get(f, set())
        if not w or not rd or (w | rd) == (w & rd) and len(w | rd) < 2:
            continue
        fid = f"f:{f}"
        node(fid, kind="state", label=f, sub="实体状态",
             detail={"写者": sorted(w), "读者": sorted(rd)})
        for x in sorted(w):
            edges.append({"a": f"r:{x}", "b": fid, "kind": "state"})
        for x in sorted(rd):
            edges.append({"a": fid, "b": f"r:{x}", "kind": "state"})

    for wf in a["world_fields"]:
        w, rd = wf["writers"], wf["readers"]
        rd_rules = [x for x in rd if f"r:{x}" in nodes]
        # A field with writers but NO readers still gets a node — it is the most
        # important node on the page. The first version skipped it for having
        # nothing to connect to, which excluded exactly the three defects the
        # tool was built to surface: the findings list pointed at nodes that were
        # not in the graph, so clicking one did nothing.
        #
        # Drawn, it reads as the insight itself: a wire arrives and none leaves.
        if not w and not rd_rules:
            continue
        fid = f"w:{wf['name']}"
        node(fid, kind="world", label=wf["name"], sub="世界状态",
             detail={"写者": w, "读者": rd})
        for x in w:
            if f"r:{x}" in nodes:
                edges.append({"a": f"r:{x}", "b": fid, "kind": "state"})
        for x in rd_rules:
            edges.append({"a": fid, "b": f"r:{x}", "kind": "state"})

    # ---- findings: the orphan edges, carried onto the graph -----------
    findings = []
    for s in a["signals"]:
        if not (s["rule_producers"] + s["ui_producers"]):
            findings.append({"node": f"s:{s['name']}", "why": "有人监听，但没有任何东西发出它"})
        if not s["consumers"]:
            findings.append({"node": f"s:{s['name']}", "why": "发出了，但没有任何规则监听"})
    for wf in a["world_fields"]:
        if wf["orphan_write"]:
            findings.append({"node": f"w:{wf['name']}", "why": "有人写，但没有任何东西读 — 这个效果的结果永远看不见"})
        if wf["orphan_read"]:
            findings.append({"node": f"w:{wf['name']}", "why": "有人读，但没有任何东西写"})
    for b in a["binding_issues"]:
        findings.append({"node": f"r:{b['rule']}", "why": "公式引用了这个触发不提供的绑定: " + ", ".join(b["unknown"])})
    flagged = {f["node"] for f in findings}
    for nid in flagged:
        if nid in nodes:
            nodes[nid]["flag"] = True

    # ---- bands: player-driven vs clock-driven -------------------------
    # The first layout put every node with no incoming edge in layer 0 and
    # labelled that column "player action". For `cal_season_3`, `trust_decay` and
    # `guilds_descend` that was a lie: they are driven by the CLOCK, and they
    # landed there only because nothing points at them.
    #
    # The distinction is real and it is one of the most important facts about
    # this game — some rules answer the player, others run whether or not the
    # player does anything — so it becomes the layout's primary axis instead of
    # being flattened away.
    incoming: dict[str, int] = {n: 0 for n in nodes}
    adj: dict[str, list[str]] = {n: [] for n in nodes}
    for e in edges:
        if e["a"] in nodes and e["b"] in nodes:
            adj[e["a"]].append(e["b"])
            incoming[e["b"]] += 1
    def _spread(roots: list[str]) -> dict[str, int]:
        lay = {r: 0 for r in roots}
        q, seen = deque(roots), set(roots)
        while q:
            n = q.popleft()
            for m in adj[n]:
                cand = min(lay[n] + 1, 14)      # cap so a cycle cannot run away
                if m not in lay or lay[m] < cand:
                    lay[m] = cand
                if m not in seen:
                    seen.add(m)
                    q.append(m)
        return lay

    entries = [n for n in nodes if nodes[n]["kind"] == "entry"]
    player = _spread(entries)

    # Whatever the player cannot reach is driven by the clock (or by the engine).
    # Its roots are the tick/scheduled rules plus anything else with no inbound
    # edge, which is exactly the set that has no player-facing cause.
    rest = [n for n in nodes if n not in player]
    clock_roots = [n for n in rest
                   if nodes[n]["kind"] == "rule"
                   and nodes[n].get("trigger") in ("tick", "scheduled")] \
                  or [n for n in rest if incoming[n] == 0] or rest[:1]
    clock = _spread([n for n in clock_roots if n in nodes])
    for n in rest:
        clock.setdefault(n, 0)

    for n in nodes:
        if n in player:
            nodes[n]["band"] = "player"
            nodes[n]["layer"] = player[n]
        else:
            nodes[n]["band"] = "clock"
            nodes[n]["layer"] = clock.get(n, 0)

    return {
        "game": game,
        "nodes": list(nodes.values()),
        "edges": [e for e in edges if e["a"] in nodes and e["b"] in nodes],
        "findings": findings,
        "bands": [
            {"key": "player", "label": "玩家驱动",
             "note": "从一个按钮出发能走到的一切"},
            {"key": "clock", "label": "时钟驱动",
             "note": "你不动它也在跑 — tick 与日历规则"},
        ],
        "stats": {
            "规则": len(rules), "信号": len(a["signals"]),
            "世界字段": len(a["world_fields"]), "节点": len(nodes),
            "边": len(edges), "发现": len(findings),
        },
    }


if __name__ == "__main__":
    import sys
    g = build(sys.argv[1] if len(sys.argv) > 1 else "demo_thousandgate")
    print(json.dumps(g["stats"], ensure_ascii=False, indent=2))
    from collections import Counter
    print("按类型:", dict(Counter(n["kind"] for n in g["nodes"])))
    print("按层:", dict(sorted(Counter(n["layer"] for n in g["nodes"]).items())))
    print("发现:")
    for f in g["findings"]:
        print("  ", f["node"], "—", f["why"])
