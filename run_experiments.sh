#!/usr/bin/env bash
# run_experiments.sh — прогоняет все 6 серий эксперимента ПР №2 локально
# (127.0.0.1) и дописывает результаты в docs/latency_samples.csv.
# См. docs/Experiment_Config.md для параметров и обоснования эмуляции
# задержки/джиттера/потерь на сервере вместо Clumsy (Windows-only).
set -euo pipefail

CLIENT=${CLIENT:-./ping_client_app}
SERVER=${SERVER:-./pong_server_app}
PORT=${PORT:-27016}
COUNT=${COUNT:-60}
INTERVAL_MS=${INTERVAL_MS:-300}
CSV=${CSV:-docs/latency_samples.csv}
SEED_BASE=${SEED_BASE:-100000}

rm -f "$CSV"

run_series() {
    local name=$1; shift
    local seed=$1; shift
    echo "=== Серия: $name (seed=$seed) ==="
    "$SERVER" "$PORT" --seed="$seed" "$@" > "docs/server_${name}.log" 2>&1 &
    local pid=$!
    sleep 0.4
    "$CLIENT" 127.0.0.1 "$PORT" "$name" "$COUNT" "$INTERVAL_MS" "$CSV"
    sleep 0.2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

run_series baseline    "$((SEED_BASE+1))"
run_series delay_50    "$((SEED_BASE+2))" --delay-ms=50
run_series delay_100   "$((SEED_BASE+3))" --delay-ms=100
run_series jitter      "$((SEED_BASE+4))" --jitter-min-ms=50 --jitter-max-ms=150
run_series loss_5      "$((SEED_BASE+5))" --loss-percent=5
run_series combined    "$((SEED_BASE+6))" --delay-ms=100 --jitter-min-ms=50 --jitter-max-ms=150 --loss-percent=5

echo "Готово: $CSV"
