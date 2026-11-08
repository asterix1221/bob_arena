#!/usr/bin/env bash
# Видео и серии подписанных скриншотов сценариев ПР №4 (Linux/WSL, виртуальный дисплей xvfb + ffmpeg). Из корня репозитория:
#   GODOT=/путь/к/godot OUT=docs/media ./tools/game_video.sh [T2 T3 T5]      (без аргументов: T2 T3 T5)
# Запись идёт в режиме ВИРТУАЛЬНОГО ВРЕМЕНИ (--role=sim): хост и клиент в одном процессе поверх LoopHub, кадры видео синхронны с симуляцией
# (Godot Movie Maker, 30 к/с = 4 тика на кадр). Серверная и клиентская логика — те же GameHost/GameClient, что и по UDP, но результат
# не зависит от скорости рендеринга и загрузки процессора, поэтому ролики воспроизводимы. Реальный UDP между двумя окнами записывается
# вручную (OBS / Xbox Game Bar): run_godot_demo.ps1 -Role Scenario -Case T3.
# Результат: <OUT>/baseline_no_prediction.mp4 (T2), prediction_enabled.mp4 (T3), correction_example.mp4 (T5),
#            <OUT>/shots/<имя>_<n>_<момент>.png (подписанные скриншоты), <OUT>/<имя>.sim.log (лог прогона).
set -euo pipefail
GODOT="${GODOT:-godot}"
OUT="$(realpath -m "${OUT:-docs/media}")"
VIZ="${VIZ:-3}"
mkdir -p "$OUT"
CASES=("$@"); [ ${#CASES[@]} -eq 0 ] && CASES=(T2 T3 T5)
"$GODOT" --headless --path godot --import >/dev/null 2>&1 || true
for c in "${CASES[@]}"; do
    case "$c" in T2) name=baseline_no_prediction;; T3) name=prediction_enabled;; T5) name=correction_example;; *) name="scenario_$c";; esac
    tmp="$(mktemp -d)"
    xvfb-run -a -s '-screen 0 1280x720x24' "$GODOT" --rendering-driver opengl3 --path godot --write-movie "$tmp/movie.avi" --fixed-fps 30 \
        -- --scenario="$c" --role=sim --viz="$VIZ" --shots-dir="$tmp/shots" --out="$OUT/$name.sim.log" >/dev/null 2>&1
    ffmpeg -loglevel error -y -i "$tmp/movie.avi" -c:v libx264 -preset medium -crf 26 -pix_fmt yuv420p "$OUT/$name.mp4"
    python3 tools/caption_shots.py "$tmp/shots" "$OUT/shots" "$name" >/dev/null || echo "скриншоты не подписаны (нужен Python с Pillow)"
    echo "$c -> $OUT/$name.mp4 ($(du -h "$OUT/$name.mp4" | cut -f1)), $(grep -c '^\[SHOT\]' "$OUT/$name.sim.log") скриншота"
    rm -rf "$tmp"
done
