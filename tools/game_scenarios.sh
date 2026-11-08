#!/usr/bin/env bash
# Автопрогон сценариев ПР №4 (T1–T5) по реальному UDP: хост (Listen Server) и клиент, которым управляет скрипт, — два процесса Godot без окна.
# Из корня репозитория:  GODOT=/путь/к/godot ./tools/game_scenarios.sh [T3 T5 ...]   (без аргументов — все T1–T5)
# Логи: docs/game_runs/<Tn>.host.log и <Tn>.client.log; сводка и графики: python tools/game_report.py
set -euo pipefail
GODOT="${GODOT:-godot}"
OUT="$(realpath -m "${OUT:-docs/game_runs}")"
mkdir -p "$OUT"
"$GODOT" --headless --path godot --import >/dev/null 2>&1 || true
CASES=("$@"); [ ${#CASES[@]} -eq 0 ] && CASES=(T1 T2 T3 T4 T5)
port=24800
for c in "${CASES[@]}"; do
    port=$((port + 1))
    hl="$OUT/$c.host.log"; cl="$OUT/$c.client.log"
    rm -f "$hl" "$cl"
    "$GODOT" --headless --path godot -- --scenario="$c" --role=host --port="$port" --quit-after=90 --out="$hl" >/dev/null 2>&1 &
    hp=$!
    for _ in $(seq 1 100); do grep -q "LISTEN SERVER" "$hl" 2>/dev/null && break; sleep 0.2; done
    "$GODOT" --headless --path godot -- --scenario="$c" --role=client --join=127.0.0.1 --port="$port" --quit-after=90 --out="$cl" >/dev/null 2>&1 || true
    wait "$hp" 2>/dev/null || true
    echo "$c: $(grep -m1 '^\[RESULT\] corrections' "$cl" 2>/dev/null || echo 'НЕТ РЕЗУЛЬТАТА (см. логи)')"
done
echo "Логи: $OUT"
