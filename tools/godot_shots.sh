#!/usr/bin/env bash
# Автоскриншоты всех экранов игры под виртуальным дисплеем (xvfb). Из корня репозитория:
#   GODOT=/путь/к/godot OUT=docs/game_shots ./tools/godot_shots.sh
# 1) solo: хост + бот, все экраны (меню, лобби, отсчёт, руны, ауры, HP вкл/выкл, net_graph, удар, победа, поражение, обрыв);
# 2) два процесса (хост и клиент по реальному UDP, клиент с эмуляцией 175±25 мс и 4% потерь) — net_graph клиента.
set -euo pipefail
GODOT="${GODOT:-godot}"
OUT="$(realpath -m "${OUT:-docs/game_shots}")"   # абсолютный путь: Godot сохраняет файлы относительно своего cwd
mkdir -p "$OUT/solo" "$OUT/host" "$OUT/client"
X="xvfb-run -a -s '-screen 0 1280x720x24'"
"$GODOT" --headless --path godot --import >/dev/null 2>&1 || true
eval $X "$GODOT" --rendering-driver opengl3 --path godot -- --shots="$OUT/solo"
eval $X "$GODOT" --rendering-driver opengl3 --path godot -- --shots="$OUT/host" --shot-role=host --port=24777 > /dev/null 2>&1 &
sleep 4
eval $X "$GODOT" --rendering-driver opengl3 --path godot -- --shots="$OUT/client" --shot-role=client --join=127.0.0.1 --port=24777 --preset=2
wait
echo "Скриншоты в $OUT"
