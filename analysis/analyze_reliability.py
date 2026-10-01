#!/usr/bin/env python3
# analysis/analyze_reliability.py
#
# Читает docs/reliability_samples.csv (журнал доставки надёжных команд, см.
# client/reliable_client.cpp) и docs/rto_timeline.csv (ряд измерений RTO) и:
#   1) печатает сводную таблицу по сериям в формате docs/Reliability_Protocol.md;
#   2) сверяет журналы с логами сервера docs/server_rel_<серия>.log (если есть):
#      эффект каждой команды применён на сервере НЕ БОЛЕЕ одного раза, каждая
#      подтверждённая команда реально применена;
#   3) строит два графика в docs/graphs/:
#      - attempts_vs_loss.png — среднее число попыток vs процент потерь
#        (с теоретической кривой);
#      - rto_over_time.png — изменение RTO во времени в серии jitter_loss_10.
#
# Использование: python3 analysis/analyze_reliability.py [папка_docs]

import csv
import re
import statistics
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

MAIN_SERIES = ["baseline", "loss_5", "loss_10", "loss_20", "delay_100_loss_5", "jitter_loss_10"]
LOSS_OF_SERIES = {"baseline": 0, "loss_5": 5, "loss_10": 10, "loss_20": 20}
COMPARISON = [
    ("delay_100_loss_5", "адаптивный RTO"),
    ("cmp_fixed1000_delay_100_loss_5", "фиксированный 1000 мс"),
    ("cmp_fixed100_delay_100_loss_5", "фиксированный 100 мс"),
]
EXTRA_SERIES = "extra_loss_20_max2"
FIXED_RTO_MS = {"cmp_fixed1000_delay_100_loss_5": 1000.0, "cmp_fixed100_delay_100_loss_5": 100.0}
MAX_ATTEMPTS = 5


def load_csv(path):
    rows = {}
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f, delimiter=";"):
            rows.setdefault(row["experiment_id"], []).append(row)
    return rows


def parse_server_log(path):
    """Разбирает лог сервера. Возвращает dict или None, если лога нет.

    applied_set/applied_count — эффекты SHOOT (sequence применялся ли повторно видно по count vs set);
    duplicates — копии, отброшенные окном дедупликации;
    shoot_lost_in / ack_lost_out — потери эмулятора в направлении клиент->сервер (SHOOT) и
    сервер->клиент (ACK); acks_scheduled — сколько ACK сервер пытался отправить (по одному на принятый SHOOT).
    """
    if not path.exists():
        return None
    applied = []
    duplicates = 0
    shoot_lost_in = 0
    ack_lost_out = 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.search(r"SHOOT seq=(\d+) .*ПРИМЕНЁН", line)
        if m:
            applied.append(int(m.group(1)))
        elif "SHOOT seq=" in line and "ДУБЛИКАТ" in line:
            duplicates += 1
        elif re.search(r"пакет типа 4 seq=\d+ потерян", line):
            shoot_lost_in += 1
        elif "ACK seq=" in line and "потерян по пути к клиенту" in line:
            ack_lost_out += 1
    return {
        "applied_set": set(applied),
        "applied_count": len(applied),
        "duplicates": duplicates,
        "shoot_lost_in": shoot_lost_in,
        "shoot_seen": len(applied) + duplicates,
        "ack_lost_out": ack_lost_out,
        "acks_scheduled": len(applied) + duplicates,
    }


def stats_for(name, samples, timeline, docs):
    n = len(samples)
    attempts = [int(r["attempts"]) for r in samples]
    acked = [r for r in samples if r["status"] == "acked"]
    failed = [r for r in samples if r["status"] == "failed"]
    first_try = [r for r in acked if int(r["attempts"]) == 1]
    ack_times = [float(r["time_to_ack_ms"]) for r in acked]
    rtos = [float(r["rto_ms"]) for r in samples]

    if name in FIXED_RTO_MS:
        final_rto = FIXED_RTO_MS[name]
    else:
        points = timeline.get(name, [])
        final_rto = float(points[-1]["rto_ms"]) if points else float("nan")

    server = parse_server_log(docs / f"server_rel_{name}.log")
    return {
        "name": name,
        "sent": n,
        "first_try": len(first_try),
        "first_try_pct": 100.0 * len(first_try) / n,
        "retransmits": sum(a - 1 for a in attempts),
        "failed": len(failed),
        "failed_pct": 100.0 * len(failed) / n,
        "avg_attempts": statistics.mean(attempts),
        "avg_rto": statistics.mean(rtos),
        "final_rto": final_rto,
        "avg_ack": statistics.mean(ack_times) if ack_times else float("nan"),
        "median_ack": statistics.median(ack_times) if ack_times else float("nan"),
        "max_ack": max(ack_times) if ack_times else float("nan"),
        "acked_seqs": {int(r["sequence"]) for r in acked},
        "failed_seqs": {int(r["sequence"]) for r in failed},
        "server": server,
    }


def check_invariants(st):
    """Сверка журнала клиента с логом сервера. Возвращает список строк-нарушений."""
    problems = []
    if st["server"] is None:
        return problems
    applied_set = st["server"]["applied_set"]
    applied_count = st["server"]["applied_count"]
    if applied_count != len(applied_set):
        problems.append(f"{st['name']}: эффект применён повторно ({applied_count} применений, "
                        f"{len(applied_set)} уникальных sequence)")
    missing = st["acked_seqs"] - applied_set
    if missing:
        problems.append(f"{st['name']}: подтверждены, но не применены на сервере: {sorted(missing)}")
    return problems


def fmt(v, digits=2):
    return "—" if v != v else f"{v:.{digits}f}"


def print_tables(all_stats):
    print("| Серия | Отправлено | Доставлено с 1-й попытки | Retransmit total | Failed | Avg attempts | "
          "Avg RTO, мс | Final RTO, мс | Time-to-ACK, мс (средн./медиана/макс.) |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for name in MAIN_SERIES:
        s = all_stats.get(name)
        if not s:
            continue
        print(f"| {name} | {s['sent']} | {s['first_try']} ({s['first_try_pct']:.1f}%) | {s['retransmits']} | "
              f"{s['failed']} ({s['failed_pct']:.1f}%) | {s['avg_attempts']:.3f} | {s['avg_rto']:.1f} | "
              f"{s['final_rto']:.1f} | {fmt(s['avg_ack'])} / {fmt(s['median_ack'])} / {fmt(s['max_ack'])} |")

    print()
    print("Серверная сторона (по docs/server_rel_<серия>.log):")
    print()
    print("| Серия | Эффектов применено | Дубликатов отброшено окном | Подтверждено клиентом | Failed у клиента, но применено сервером |")
    print("|---|---:|---:|---:|---:|")
    for name in MAIN_SERIES:
        s = all_stats.get(name)
        if not s or s["server"] is None:
            continue
        srv = s["server"]
        failed_but_applied = len(s["failed_seqs"] & srv["applied_set"])
        print(f"| {name} | {srv['applied_count']} | {srv['duplicates']} | {len(s['acked_seqs'])} | {failed_but_applied} |")

    print()
    print("Фактическая доля потерь, созданных эмулятором (по логам сервера):")
    print()
    print("| Серия | Номинал, % (в каждую сторону) | SHOOT потеряно на пути к серверу | ACK потеряно на пути к клиенту |")
    print("|---|---:|---:|---:|")
    nominal = {"baseline": 0, "loss_5": 5, "loss_10": 10, "loss_20": 20, "delay_100_loss_5": 5, "jitter_loss_10": 10}
    for name in MAIN_SERIES:
        s = all_stats.get(name)
        if not s or s["server"] is None:
            continue
        srv = s["server"]
        in_total = srv["shoot_lost_in"] + srv["shoot_seen"]
        pct_in = 100.0 * srv["shoot_lost_in"] / in_total if in_total else 0.0
        pct_out = 100.0 * srv["ack_lost_out"] / srv["acks_scheduled"] if srv["acks_scheduled"] else 0.0
        print(f"| {name} | {nominal[name]} | {srv['shoot_lost_in']} из {in_total} ({pct_in:.1f}%) | "
              f"{srv['ack_lost_out']} из {srv['acks_scheduled']} ({pct_out:.1f}%) |")

    print()
    print("Сравнение адаптивного и фиксированного RTO (условия delay_100_loss_5):")
    print()
    print("| Вариант RTO | Доставлено с 1-й попытки | Retransmit total | Дубликатов на сервере | Avg attempts | Time-to-ACK, мс (средн./макс.) |")
    print("|---|---:|---:|---:|---:|---:|")
    for name, label in COMPARISON:
        s = all_stats.get(name)
        if not s:
            continue
        dups = s["server"]["duplicates"] if s["server"] else float("nan")
        print(f"| {label} | {s['first_try']} ({s['first_try_pct']:.1f}%) | {s['retransmits']} | "
              f"{dups if dups == dups else '—'} | {s['avg_attempts']:.3f} | {fmt(s['avg_ack'])} / {fmt(s['max_ack'])} |")


def print_failed_demo(all_stats):
    s = all_stats.get(EXTRA_SERIES)
    if not s:
        return
    print()
    print("Демонстрация окончательной недоставки (потери 20%, maxAttempts = 2):")
    print()
    print("| Отправлено | Подтверждено | Failed | Failed, но эффект применён сервером | Failed, эффект НЕ дошёл до сервера |")
    print("|---:|---:|---:|---:|---:|")
    applied = s["server"]["applied_set"] if s["server"] else set()
    both = len(s["failed_seqs"] & applied)
    print(f"| {s['sent']} | {len(s['acked_seqs'])} | {s['failed']} ({s['failed_pct']:.1f}%) | {both} | {s['failed'] - both} |")


def theory_attempts(loss_percent, max_attempts=MAX_ATTEMPTS):
    """Ожидаемое число отправок на команду при потере p в КАЖДУЮ сторону.

    Попытка неудачна, если потерян пакет или потерян его ACK: q = 1 - (1 - p)^2.
    Число отправок ограничено max_attempts: E = 1 + q + q^2 + ... + q^(max_attempts-1).
    """
    p = loss_percent / 100.0
    q = 1.0 - (1.0 - p) ** 2
    return sum(q ** k for k in range(max_attempts))


def plot_attempts_vs_loss(all_stats, graphs_dir):
    xs = [LOSS_OF_SERIES[n] for n in LOSS_OF_SERIES if n in all_stats]
    ys = [all_stats[n]["avg_attempts"] for n in LOSS_OF_SERIES if n in all_stats]

    fig, ax = plt.subplots(figsize=(8, 5))
    grid = [i * 0.5 for i in range(0, 49)]
    ax.plot(grid, [theory_attempts(x) for x in grid], "--", color="gray",
            label="теория: потеря p в каждую сторону,\nq = 1 − (1 − p)², ≤ 5 отправок")
    ax.plot(xs, ys, "o-", color="tab:blue", linewidth=2, markersize=8, label="эксперимент (baseline, loss_5/10/20)")
    for x, y in zip(xs, ys):
        ax.annotate(f"{y:.2f}", (x, y), textcoords="offset points", xytext=(0, 9), ha="center")

    extra_marks = [("delay_100_loss_5", 5, "tab:green", "s", "delay_100_loss_5"),
                   ("jitter_loss_10", 10, "tab:red", "^", "jitter_loss_10")]
    for name, loss, color, marker, label in extra_marks:
        if name in all_stats:
            ax.plot([loss], [all_stats[name]["avg_attempts"]], marker, color=color, markersize=9, label=label)

    ax.set_xlabel("Потери пакетов в каждую сторону, %")
    ax.set_ylabel("Среднее число попыток на команду")
    ax.set_title("Среднее число попыток vs процент потерь")
    ax.set_xlim(-1, 25)
    ax.set_ylim(0.95, max(1.7, max(ys) + 0.15))
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left", fontsize=9)
    fig.tight_layout()
    out = graphs_dir / "attempts_vs_loss.png"
    fig.savefig(out, dpi=130)
    plt.close(fig)
    return out


def plot_rto_over_time(timeline, graphs_dir, series="jitter_loss_10"):
    points = timeline.get(series, [])
    if not points:
        return None
    t = [float(p["t_ms"]) / 1000.0 for p in points]
    rto = [float(p["rto_ms"]) for p in points]
    srtt = [float(p["srtt_ms"]) for p in points]

    fig, ax = plt.subplots(figsize=(9, 5))
    ax.step(t, rto, where="post", color="tab:red", linewidth=2, label="RTO = SRTT + 4·RTTVAR")
    ax.plot(t, srtt, color="tab:blue", linewidth=1.5, label="SRTT")
    for source, marker, color in (("ack", "o", "tab:green"), ("ping", "x", "tab:gray")):
        ts = [float(p["t_ms"]) / 1000.0 for p in points if p["source"] == source]
        rs = [float(p["rtt_ms"]) for p in points if p["source"] == source]
        label = "RTT-сэмпл: ACK (1-я попытка)" if source == "ack" else "RTT-сэмпл: PING/PONG"
        ax.scatter(ts, rs, s=14, marker=marker, color=color, alpha=0.7, label=label)
    ax.axhline(1000, color="black", linestyle=":", linewidth=1, label="фиксированный тайм-аут ПР №2 (1000 мс)")
    ax.set_xlabel("Время от начала серии, с")
    ax.set_ylabel("мс")
    ax.set_title(f"Изменение RTO во времени (серия {series}: джиттер 50–150 мс + потери 10%)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper right", fontsize=9)
    fig.tight_layout()
    out = graphs_dir / "rto_over_time.png"
    fig.savefig(out, dpi=130)
    plt.close(fig)
    return out


def main():
    docs = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("docs")
    samples = load_csv(docs / "reliability_samples.csv")
    timeline = load_csv(docs / "rto_timeline.csv")
    graphs_dir = docs / "graphs"
    graphs_dir.mkdir(parents=True, exist_ok=True)

    all_stats = {name: stats_for(name, rows, timeline, docs) for name, rows in samples.items()}

    print_tables(all_stats)
    print_failed_demo(all_stats)

    problems = []
    for st in all_stats.values():
        problems.extend(check_invariants(st))
    print()
    if problems:
        print("НАРУШЕНИЯ ИНВАРИАНТОВ:")
        for p in problems:
            print(" -", p)
    else:
        checked = sum(1 for s in all_stats.values() if s["server"] is not None)
        print(f"Инварианты выполнены во всех сериях с логами сервера ({checked}): "
              "эффект каждой команды применён не более одного раза, каждая подтверждённая команда применена.")

    for out in (plot_attempts_vs_loss(all_stats, graphs_dir), plot_rto_over_time(timeline, graphs_dir)):
        if out:
            print("График:", out)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
