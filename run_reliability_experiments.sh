#!/usr/bin/env bash
# run_reliability_experiments.sh — прогоняет 6 обязательных серий эксперимента
# ПР №3 (+ 3 вспомогательные серии: сравнение с фиксированным RTO и демонстрация failed) локально
# (127.0.0.1) и записывает результаты в docs/reliability_samples.csv и
# docs/rto_timeline.csv. Параметры эмуляции сети — см. docs/Reliability_Protocol.md,
# раздел «Методика эксперимента».
set -euo pipefail

CLIENT=${CLIENT:-./reliable_client_app}
SERVER=${SERVER:-./reliable_server_app}
PORT=${PORT:-27017}
COUNT=${COUNT:-100}
INTERVAL_MS=${INTERVAL_MS:-100}
CSV=${CSV:-docs/reliability_samples.csv}
RTO_CSV=${RTO_CSV:-docs/rto_timeline.csv}
SEED_BASE=${SEED_BASE:-200000}

rm -f "$CSV" "$RTO_CSV"

# run_series <имя> <seed> <флаги сервера...> -- <доп. флаги клиента...>
run_series() {
    local name=$1; shift
    local seed=$1; shift
    local server_flags=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do server_flags+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    echo "=== Серия: $name (seed=$seed) ==="
    "$SERVER" "$PORT" --seed="$seed" "${server_flags[@]}" > "docs/server_rel_${name}.log" 2>&1 &
    local pid=$!
    sleep 0.4
    "$CLIENT" 127.0.0.1 "$PORT" "$name" "$COUNT" "$INTERVAL_MS" "$CSV" --rto-csv="$RTO_CSV" "$@"
    sleep 0.2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

run_series baseline         "$((SEED_BASE+1))" --
run_series loss_5           "$((SEED_BASE+2))" --loss-percent=5 --
run_series loss_10          "$((SEED_BASE+3))" --loss-percent=10 --
run_series loss_20          "$((SEED_BASE+4))" --loss-percent=20 --
run_series delay_100_loss_5 "$((SEED_BASE+5))" --delay-ms=100 --loss-percent=5 --
run_series jitter_loss_10   "$((SEED_BASE+6))" --jitter-min-ms=50 --jitter-max-ms=150 --loss-percent=10 --

# Вспомогательные серии: те же условия, что delay_100_loss_5 (тот же seed
# сервера), но с ПОСТОЯННЫМ RTO вместо адаптивного — для раздела «Анализ».
run_series cmp_fixed1000_delay_100_loss_5 "$((SEED_BASE+5))" --delay-ms=100 --loss-percent=5 -- --fixed-rto-ms=1000
run_series cmp_fixed100_delay_100_loss_5  "$((SEED_BASE+5))" --delay-ms=100 --loss-percent=5 -- --fixed-rto-ms=100

# Демонстрация окончательной недоставки: потери 20% и всего 2 попытки на команду
# (в основных сериях с 5 попытками failed почти не случается).
run_series extra_loss_20_max2 "$((SEED_BASE+7))" --loss-percent=20 -- --max-attempts=2

echo "Готово: $CSV, $RTO_CSV"
