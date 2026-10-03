#!/usr/bin/env python3
"""Обработка логов tools/godot_scenarios.sh: сводка (markdown) и графики для docs/godot/media/.
Использование: python tools/godot_report.py [каталог_логов] [каталог_графиков]
Только латиница в подписях графиков (шрифты matplotlib), логи — UTF-8.
"""
import re, sys, statistics
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

runs = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/godot/runs")
media = Path(sys.argv[2] if len(sys.argv) > 2 else "docs/godot/media")
media.mkdir(parents=True, exist_ok=True)


def parse(name):
    d = {"pos": [], "trace": [], "events": [], "lag": 0.0, "result": {}}
    for line in (runs / f"{name}.client.log").read_text(encoding="utf-8").splitlines():
        if line.startswith("POS,"):
            _, t, seq, x, y = line.split(",")
            d["pos"].append((float(t), int(seq), float(x), float(y)))
        elif line.startswith("TRACE,"):
            _, t, ack, sx, sy, px, py, c = line.split(",")
            d["trace"].append((float(t), int(ack), float(sx), float(sy), float(px), float(py), int(c)))
        elif line.startswith("["):
            d["events"].append(line)
            m = re.search(r"lag=(\d+)", line)
            if line.startswith("[RESULT] role=client") and m:
                d["lag"] = float(m.group(1))
            m = re.match(r"\[RESULT\] (\w+)=(.*)", line)
            if m:
                d["result"][m.group(1)] = m.group(2)
    return d


def events(d, tag, key=None):
    out = []
    for e in d["events"]:
        if tag in e and (key is None or key in e):
            m = re.search(r"t=(\d+)", e)
            if m:
                out.append((float(m.group(1)), e))
    return out


def server_curve(d):
    """Позиция сервера для команды seq, показанная в момент, когда её ВЫПОЛНИЛ сервер (~ время клиента + односторонняя задержка)."""
    t_of_seq = {seq: t for t, seq, _, _ in d["pos"]}
    pts = []
    for t, ack, sx, sy, px, py, c in d["trace"]:
        if ack in t_of_seq:
            pts.append((t_of_seq[ack] + d["lag"], sx))
    return pts


def dash_plot(name, title, out_name):
    d = parse(name)
    keys = events(d, "[INPUT]")
    k0 = keys[0][0]
    lo, hi = k0 - 150, k0 + 700
    fig, ax = plt.subplots(figsize=(9, 4.6))
    cx = [(t, x) for t, _, x, _ in d["pos"] if lo <= t <= hi]
    ax.plot([t - k0 for t, _ in cx], [x for _, x in cx], color="tab:blue", lw=2, label="client-visible position X")
    sc = [(t, x) for t, x in server_curve(d) if lo <= t <= hi]
    ax.plot([t - k0 for t, _ in sc], [x for _, x in sc], color="tab:orange", lw=1.6, ls="--", label="server authoritative X (at server time)")
    ax.axvline(0, color="red", lw=1.2); ax.text(4, ax.get_ylim()[0], " key press", color="red", va="bottom")
    for t, e in events(d, "[DASH]", "server-confirmed"):
        if lo <= t <= hi:
            ax.axvline(t - k0, color="green", lw=1.2, ls=":"); ax.text(t - k0 + 4, ax.get_ylim()[1], " server response\n visible to client", color="green", va="top")
            break
    for t, e in events(d, "[DASH]", "local response"):
        if lo <= t <= hi:
            ax.axvline(t - k0, color="purple", lw=1.0, ls=":"); break
    ax.set_xlabel("time since key press, ms"); ax.set_ylabel("X, px"); ax.set_title(title); ax.legend(loc="upper left"); ax.grid(alpha=.3)
    fig.tight_layout(); fig.savefig(media / out_name, dpi=130); plt.close(fig)


def correction_plot(name, out_name):
    d = parse(name)
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(10, 6.4), sharex=True, gridspec_kw={"height_ratios": [2, 1]})
    t0 = d["pos"][0][0]
    a1.plot([(t - t0) / 1000 for t, _, x, _ in d["pos"]], [x for _, _, x, _ in d["pos"]], color="tab:blue", lw=1.8, label="client-visible X (prediction)")
    sc = server_curve(d)
    a1.plot([(t - t0) / 1000 for t, _ in sc], [x for _, x in sc], color="tab:orange", lw=1.3, ls="--", label="server authoritative X")
    for t, e in events(d, "[CHEAT]"):
        a1.axvline((t - t0) / 1000, color="crimson", ls=":", lw=1.2)
        a1.text((t - t0) / 1000 + .05, a1.get_ylim()[1], "cheat: " + ("ON" if "=true" in e else "OFF") + (" x3" if "x3" in e else ""), color="crimson", va="top", fontsize=8)
    for t, e in events(d, "[DASH]", "REJECTED"):
        a1.axvline((t - t0) / 1000, color="black", lw=1.0); a1.text((t - t0) / 1000 + .05, a1.get_ylim()[0], "server rejected dash", fontsize=8, va="bottom")
    a1.set_ylabel("X, px"); a1.legend(loc="upper right"); a1.grid(alpha=.3)
    a1.set_title("T5: intentional divergence (client cheats), server correction and convergence")
    cs = events(d, "[CORRECTION]")
    errs = [float(re.search(r"error=([\d.]+)", e).group(1)) for _, e in cs]
    a2.stem([(t - t0) / 1000 for t, _ in cs], errs, linefmt="r-", markerfmt="ro", basefmt="k-")
    a2.set_ylabel("correction error, px"); a2.set_xlabel("time, s"); a2.grid(alpha=.3)
    fig.tight_layout(); fig.savefig(media / out_name, dpi=130); plt.close(fig)


def stats(xs):
    return "-" if not xs else f"min {min(xs):.0f} / avg {statistics.mean(xs):.0f} / max {max(xs):.0f} ms (n={len(xs)})"


def nums(s):
    return [float(v) for v in re.findall(r"[\d.]+", s)] if s and s != "[]" else []


dash_plot("T2_lag100_nopred", "T2: NO prediction, 100 ms one-way lag (RTT ~200 ms)", "baseline_no_prediction.png")
dash_plot("T3_lag100_pred", "T3: client-side prediction, 100 ms one-way lag", "prediction_enabled.png")
correction_plot("T5_lag175loss4_cheat", "correction_example.png")

rows = []
for p in sorted(runs.glob("*.client.log")):
    name = p.name[: -len(".client.log")]
    r = parse(name)["result"]
    loc, conf = nums(r.get("local_response_ms", "")), nums(r.get("confirm_response_ms", ""))
    host = (runs / f"{name}.host.log").read_text(encoding="utf-8")
    sm = re.search(r"dash_rejects\": (\d+).*?dash_accepts\": (\d+)", host.replace("\n", " "))
    rows.append((name, r.get("corrections", "?").split()[0], re.search(r"max_error_px=([\d.]+)", r.get("corrections", "") + " max_error_px=" + "") and r.get("max_error_px", ""), r))
out = ["| Scenario | local response (key -> own screen) | server-visible response (key -> confirmation) | corrections | max error, px | server rejects / accepts | final client-vs-server error, px |", "|---|---|---|---|---|---|---|"]
for p in sorted(runs.glob("*.client.log")):
    name = p.name[: -len(".client.log")]
    log = p.read_text(encoding="utf-8")
    g = lambda pat: (re.search(pat, log) or [None, "?"])[1]
    loc = nums(g(r"local_response_ms=(\[.*?\])")); conf = nums(g(r"confirm_response_ms=(\[.*?\])"))
    host = (runs / f"{name}.host.log").read_text(encoding="utf-8")
    rej = (re.search(r"dash_rejects\": (\d+)", host) or [None, "?"])[1]; acc = (re.search(r"dash_accepts\": (\d+)", host) or [None, "?"])[1]
    out.append(f"| {name} | {stats(loc)} | {stats(conf)} | {g(r'corrections=(\d+)')} | {g(r'max_error_px=([\d.]+)')} | {rej} / {acc} | {g(r'final_pred_vs_server_px=([\d.]+)')} |")
(runs / "summary.md").write_text("\n".join(out) + "\n", encoding="utf-8")
print("\n".join(out))
