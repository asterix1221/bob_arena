#!/usr/bin/env python3
"""Обработка логов tools/game_scenarios.sh: сводка (docs/game_runs/summary.md) и графики для docs/media/.
Использование: python tools/game_report.py [каталог_логов] [каталог_графиков]
Подписи графиков — латиницей (шрифты matplotlib), логи и сводка — UTF-8."""
import re, sys, statistics
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

runs = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/game_runs")
media = Path(sys.argv[2] if len(sys.argv) > 2 else "docs/media")
media.mkdir(parents=True, exist_ok=True)


def parse(case):
    d = {"pos": [], "trace": [], "dash": [], "corr": [], "result": {}, "host": ""}
    for line in (runs / f"{case}.client.log").read_text(encoding="utf-8").splitlines():
        if line.startswith("POS,"):
            _, t, seq, x, y, dl = line.split(",")
            d["pos"].append((float(t), float(x), int(dl)))
        elif line.startswith("TRACE,"):
            _, t, ack, sx, sy, px, py, c = line.split(",")
            d["trace"].append((float(t), float(sx), float(px)))
        elif line.startswith("[DASH]"):
            m = re.match(r"\[DASH\] (\w+) t=(\d+) on_screen_ms=([\d.]+) confirmed_ms=([\d.]+)", line)
            if m:
                d["dash"].append((m.group(1), float(m.group(2)), float(m.group(3)), float(m.group(4))))
        elif line.startswith("[CORRECTION]"):
            m = re.match(r"\[CORRECTION\] t=(\d+) err_px=([\d.]+)", line)
            d["corr"].append((float(m.group(1)), float(m.group(2))))
        elif line.startswith("[RESULT]"):
            for k, v in re.findall(r"(\w+)=(\[[^\]]*\]|\S+)", line):
                d["result"][k] = v
    hl = runs / f"{case}.host.log"
    if hl.exists():
        for line in hl.read_text(encoding="utf-8").splitlines():
            if line.startswith("[RESULT] role=host"):
                d["host"] = line
    return d


def nums(s):
    return [float(x) for x in re.findall(r"-?[\d.]+", s)] if s else []


def stat(a):
    return "—" if not a else f"{statistics.mean(a):.0f} ({min(a):.0f}–{max(a):.0f})"


cases = {}
for c in ["T1", "T2", "T3", "T4", "T5"]:
    if (runs / f"{c}.client.log").exists():
        cases[c] = parse(c)

# ---------------------------------------------------------------- сводка
rows = ["| Тест | Сеть | Предсказание рывка | Рывков принято/отклонено | Рывок на экране, мс | Подтверждение сервера, мс | Коррекций | Макс. ошибка, px | Потери (отправлено/сброшено) | Итоговая ошибка, px |",
        "|---|---|---|---|---|---|---|---|---|---|"]
for c, d in cases.items():
    r = d["result"]
    net = f"{r.get('lag', '0')} мс" + (f" ±{r['jitter']}" if r.get("jitter", "0") != "0" else "") + (f", {r['loss']}% потерь" if float(r.get("loss", "0")) > 0 else "")
    rows.append(f"| {c} | {net} | {'вкл' if r.get('predict_dash') == '1' else 'выкл'} | {r.get('dash_accepted')}/{r.get('dash_denied')} | "
                f"{stat(nums(r.get('local_response_ms', '')))} | {stat(nums(r.get('confirm_response_ms', '')))} | {r.get('corrections')} | {r.get('max_error_px')} | "
                f"{r.get('net_sent')}/{r.get('net_dropped')} | {r.get('final_pred_vs_server_px')} |")
(runs / "summary.md").write_text("# Итоги автопрогона сценариев ПР №4 (среднее и диапазон)\n\n" + "\n".join(rows) + "\n\nСтатистика сервера по клиенту:\n\n" +
                                 "\n".join(f"- {c}: `{d['host'].split('remote_player_stats=')[-1]}`" for c, d in cases.items() if d["host"]) + "\n", encoding="utf-8")
print("\n".join(rows))


# ---------------------------------------------------------------- графики
def first_event(d, accepted=True):
    for kind, t, on_screen, conf in d["dash"]:
        if (kind == "ACCEPTED") == accepted:
            return t, conf
    return None


def plot(case, out, title, accepted=True, before=250, after=900):
    d = cases[case]
    ev = first_event(d, accepted)
    if ev is None:
        print("нет события для", case)
        return
    t_resp, conf = ev
    t_press = t_resp - conf
    lo, hi = t_press - before, t_press + after
    px = [(t - t_press, x, dl) for t, x, dl in d["pos"] if lo <= t <= hi]
    sv = [(t - t_press, s) for t, s, _ in d["trace"] if lo <= t <= hi]
    fig, ax = plt.subplots(figsize=(10, 5))
    ax.plot([p[0] for p in px], [p[1] for p in px], lw=2.2, label="client-visible position X (what the player sees)")
    ax.plot([s[0] for s in sv], [s[1] for s in sv], "--", lw=1.6, color="#ff8c1a", label="authoritative X as received from server")
    run, first = None, True
    for t, _, dl in px + [(px[-1][0] + 1, 0, 0)]:      # закрасить каждый непрерывный отрезок «рывок виден у клиента»
        if dl > 0 and run is None:
            run = t
        elif dl == 0 and run is not None:
            ax.axvspan(run, t, color="#2ca02c", alpha=0.18, label="dash visible on client screen" if first else None)
            first, run = False, None
    ax.axvline(0, color="red", lw=1.2)
    ax.text(5, ax.get_ylim()[0], "key press", color="red", va="bottom")
    ax.axvline(t_resp - t_press, color="green", ls=":", lw=1.5)
    ax.text(t_resp - t_press + 5, ax.get_ylim()[1], f"server response\nvisible (+{conf:.0f} ms)", color="green", va="top")
    for t, err in d["corr"]:
        if lo <= t <= hi:
            ax.axvline(t - t_press, color="#d62728", alpha=0.35, lw=3)
            ax.text(t - t_press + 4, ax.get_ylim()[0] + 5, f"correction {err:.0f} px", color="#d62728", rotation=90, va="bottom", fontsize=8)
    ax.set_title(title)
    ax.set_xlabel("time since key press, ms")
    ax.set_ylabel("X, px")
    ax.grid(alpha=0.3)
    ax.legend(loc="upper left", fontsize=8)
    fig.tight_layout()
    fig.savefig(media / out, dpi=120)
    plt.close(fig)
    print("график:", media / out)


if "T2" in cases:
    plot("T2", "baseline_no_prediction.png", "T2: dash WITHOUT prediction, 100 ms one-way lag (RTT ~200 ms)")
if "T3" in cases:
    plot("T3", "prediction_enabled.png", "T3: dash WITH client-side prediction, 100 ms one-way lag")
if "T5" in cases:
    plot("T5", "correction_example.png", "T5: cheating client (dash during cooldown), 175+-25 ms, 4% loss: server rejects, client is corrected", accepted=False, before=300, after=1100)
