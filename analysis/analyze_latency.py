#!/usr/bin/env python3
# analysis/analyze_latency.py
#
# Читает docs/latency_samples.csv (журнал измерений RTT, см.
# telemetry/telemetry.h::Sample и client/ping_client.cpp) и:
#   1) печатает сводную таблицу по каждой серии (для docs/Latency_Report.md);
#   2) строит три обязательных графика в docs/graphs/:
#      - latency_by_measurement.png — линейный график RTT по измерениям
#        с отмеченными тайм-аутами (для серии combined, самой насыщенной);
#      - mean_rtt_srtt_loss.png — столбчатая диаграмма mean RTT / SRTT /
#        loss rate по всем сериям;
#      - rtt_distribution.png — box plot RTT для baseline/jitter/combined.
#
# Показатели считаются НЕЗАВИСИМО от C++ (см. telemetry::ComputeSeriesStats)
# по одному и тому же CSV — это намеренно: если оба расчёта (C++ тесты и
# этот скрипт) сходятся, это дополнительно подтверждает корректность формул
# из задания (RTT, SRTT, джиттер, Loss Rate).
#
# Использование: python3 analysis/analyze_latency.py [путь_к_csv] [папка_графиков]

import csv
import statistics
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

SERIES_ORDER = ["baseline", "delay_50", "delay_100", "jitter", "loss_5", "combined"]


def load_samples(csv_path):
    series = {name: [] for name in SERIES_ORDER}
    with open(csv_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter=";")
        for row in reader:
            series.setdefault(row["experiment_id"], []).append(row)
    return series


def to_float_or_none(value):
    return float(value) if value not in (None, "") else None


def compute_stats(rows):
    sent = len(rows)
    received = sum(1 for r in rows if r["status"] == "received")
    timed_out = sum(1 for r in rows if r["status"] == "timeout")
    late = sum(1 for r in rows if r["status"] == "late_response")

    # RTT-выборка: received + late_response (у обоих есть измеренный RTT) —
    # то же соглашение, что и в telemetry::ComputeSeriesStats (C++).
    rtts = [to_float_or_none(r["rtt_ms"]) for r in rows if r["status"] in ("received", "late_response")]
    rtts = [v for v in rtts if v is not None]

    received_rtts = [to_float_or_none(r["rtt_ms"]) for r in rows if r["status"] == "received"]
    received_rtts = [v for v in received_rtts if v is not None]

    jitter = 0.0
    if len(received_rtts) > 1:
        diffs = [abs(received_rtts[i] - received_rtts[i - 1]) for i in range(1, len(received_rtts))]
        jitter = sum(diffs) / len(diffs)

    last_srtt = 0.0
    for r in rows:
        if r["srtt_ms"]:
            last_srtt = float(r["srtt_ms"])

    return {
        "sent": sent,
        "received": received,
        "timed_out": timed_out,
        "late": late,
        "min_rtt": min(rtts) if rtts else None,
        "max_rtt": max(rtts) if rtts else None,
        "mean_rtt": statistics.mean(rtts) if rtts else None,
        "median_rtt": statistics.median(rtts) if rtts else None,
        "last_srtt": last_srtt,
        "jitter": jitter,
        "loss_rate_percent": (timed_out / sent * 100.0) if sent else 0.0,
    }


def print_and_collect_stats(series):
    all_stats = {}
    header = f"{'series':<12}{'sent':>6}{'recv':>6}{'timeout':>9}{'late':>6}{'min':>8}{'max':>8}{'mean':>8}{'median':>8}{'srtt':>8}{'jitter':>8}{'loss%':>8}"
    print(header)
    print("-" * len(header))
    for name in SERIES_ORDER:
        rows = series.get(name, [])
        if not rows:
            continue
        s = compute_stats(rows)
        all_stats[name] = s
        fmt = lambda v: f"{v:.2f}" if v is not None else "-"
        print(f"{name:<12}{s['sent']:>6}{s['received']:>6}{s['timed_out']:>9}{s['late']:>6}"
              f"{fmt(s['min_rtt']):>8}{fmt(s['max_rtt']):>8}{fmt(s['mean_rtt']):>8}{fmt(s['median_rtt']):>8}"
              f"{fmt(s['last_srtt']):>8}{fmt(s['jitter']):>8}{fmt(s['loss_rate_percent']):>8}")
    return all_stats


def plot_latency_by_measurement(series, out_dir, series_name="combined"):
    rows = series.get(series_name, [])
    if not rows:
        return
    samples = [int(r["sample"]) for r in rows]
    rtts = [to_float_or_none(r["rtt_ms"]) for r in rows]
    srtts = [to_float_or_none(r["srtt_ms"]) for r in rows]

    fig, ax = plt.subplots(figsize=(10, 5))
    ok_x = [s for s, v in zip(samples, rtts) if v is not None]
    ok_y = [v for v in rtts if v is not None]
    ax.plot(ok_x, ok_y, marker="o", markersize=3, linewidth=1, label="RTT", color="#1f77b4")

    srtt_x = [s for s, v in zip(samples, srtts) if v is not None]
    srtt_y = [v for v in srtts if v is not None]
    ax.plot(srtt_x, srtt_y, linewidth=1.5, label="SRTT (сглаженный)", color="#ff7f0e")

    timeout_x = [s for s, r in zip(samples, rows) if r["status"] == "timeout"]
    if timeout_x:
        y_top = max(ok_y) if ok_y else 1.0
        ax.scatter(timeout_x, [y_top * 1.05] * len(timeout_x), marker="x", color="red",
                   s=60, label="timeout", zorder=5)

    ax.set_title(f"RTT по измерениям, серия '{series_name}' (с отметками тайм-аутов)")
    ax.set_xlabel("Номер измерения (sample)")
    ax.set_ylabel("Время, мс")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_dir / "latency_by_measurement.png", dpi=150)
    plt.close(fig)


def plot_mean_rtt_srtt_loss(all_stats, out_dir):
    names = [n for n in SERIES_ORDER if n in all_stats]
    mean_rtt = [all_stats[n]["mean_rtt"] or 0.0 for n in names]
    srtt = [all_stats[n]["last_srtt"] for n in names]
    loss = [all_stats[n]["loss_rate_percent"] for n in names]

    x = range(len(names))
    width = 0.28

    fig, ax1 = plt.subplots(figsize=(10, 5))
    ax1.bar([i - width for i in x], mean_rtt, width=width, label="Mean RTT, мс", color="#1f77b4")
    ax1.bar([i for i in x], srtt, width=width, label="Итоговый SRTT, мс", color="#ff7f0e")
    ax1.set_ylabel("Время, мс")
    ax1.set_xticks(list(x))
    ax1.set_xticklabels(names)

    ax2 = ax1.twinx()
    ax2.bar([i + width for i in x], loss, width=width, label="Loss rate, %", color="#2ca02c")
    ax2.set_ylabel("Loss rate, %")

    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="upper left")

    ax1.set_title("Mean RTT / SRTT / Loss rate по сериям")
    fig.tight_layout()
    fig.savefig(out_dir / "mean_rtt_srtt_loss.png", dpi=150)
    plt.close(fig)


def plot_rtt_distribution(series, out_dir, names=("baseline", "jitter", "combined")):
    data = []
    labels = []
    for name in names:
        rows = series.get(name, [])
        rtts = [to_float_or_none(r["rtt_ms"]) for r in rows if r["status"] in ("received", "late_response")]
        rtts = [v for v in rtts if v is not None]
        if rtts:
            data.append(rtts)
            labels.append(name)

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.boxplot(data, tick_labels=labels, showmeans=True)
    ax.set_title("Распределение RTT: baseline vs jitter vs combined")
    ax.set_ylabel("RTT, мс")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_dir / "rtt_distribution.png", dpi=150)
    plt.close(fig)


def main():
    csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("docs/latency_samples.csv")
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("docs/graphs")
    out_dir.mkdir(parents=True, exist_ok=True)

    series = load_samples(csv_path)
    all_stats = print_and_collect_stats(series)

    plot_latency_by_measurement(series, out_dir, "combined")
    plot_mean_rtt_srtt_loss(all_stats, out_dir)
    plot_rtt_distribution(series, out_dir)

    print(f"\nГрафики сохранены в {out_dir}/")


if __name__ == "__main__":
    main()
