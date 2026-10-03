#!/usr/bin/env bash
# Автопрогон сценариев T1–T6 ПР №4 (Godot, headless): Listen Server + бот-клиент по реальному ENet
# на localhost, эмуляция сети — встроенная (NetEmu, на исходящем трафике клиента и сервера).
# Использование: GODOT=/path/to/godot tools/godot_scenarios.sh [каталог_логов]
set -u
GODOT="${GODOT:-godot}"
OUT="${1:-docs/godot/runs}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)/godot"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"   # Godot не понимает относительные пути в FileAccess — нужен абсолютный
OUT="$(cd "$OUT" && pwd)"   # Godot не понимает относительные пути в FileAccess — нужен абсолютный
port=24800

run_case() {  # имя  predict  lag  jitter  loss  бот
    local name="$1" predict="$2" lag="$3" jitter="$4" loss="$5" bot="$6"
    port=$((port + 1))
    local host_log="$OUT/${name}.host.log" cli_log="$OUT/${name}.client.log"
    rm -f "$host_log" "$cli_log"
    "$GODOT" --headless --path "$PROJ" -- --host --port=$port --quit-after=60 --exit-on-disconnect \
        --lag="$lag" --jitter="$jitter" --loss="$loss" --out="$host_log" >/dev/null 2>&1 &
    local host_pid=$!
    for _ in $(seq 1 100); do grep -q "LISTEN SERVER" "$host_log" 2>/dev/null && break; sleep 0.2; done
    timeout 90 "$GODOT" --headless --path "$PROJ" -- --join=127.0.0.1 --port=$port --predict="$predict" \
        --lag="$lag" --jitter="$jitter" --loss="$loss" --bot="$bot" --out="$cli_log" >/dev/null 2>&1
    wait "$host_pid" 2>/dev/null
    echo "$name: $(grep -c . "$cli_log") client log lines, $(grep '^\[RESULT\] corrections' "$cli_log")"
}

#        имя                    predict lag jitter loss бот
run_case T1_walk_noemu_pred        1     0    0     0   walk
run_case T2_lag100_nopred          0     100  0     0   dash_latency
run_case T3_lag100_pred            1     100  0     0   dash_latency
run_case T4_lag175loss4_pred       1     175  25    4   loss_mix
run_case T5_lag175loss4_cheat      1     175  25    4   cheat
run_case T6_lag100_wall            1     100  0     0   wall
