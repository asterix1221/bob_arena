#!/usr/bin/env bash
# Все проверки игры на Godot одним запуском (Linux/macOS/WSL). Из корня репозитория:
#   GODOT=/путь/к/godot ./tools/godot_check.sh
# C++-тесты протокола: см. README (g++ ... tests/*.cpp). Совместимость с C++ pong_server_app: ./tools/net_interop.sh
set -euo pipefail
GODOT="${GODOT:-godot}"
"$GODOT" --headless --path godot --import >/dev/null 2>&1 || true
rc=0
for s in run_net_tests run_game_tests run_game_net_tests run_pred_tests run_view_tests run_app_tests run_udp_tests run_repl_tests; do
    line=$("$GODOT" --headless --path godot -s "res://tests/$s.gd" 2>&1 | grep "тестов" | tail -1 || true)
    printf '%-22s %s\n' "$s" "${line:-НЕТ РЕЗУЛЬТАТА}"
    case "$line" in *", 0 провалено"*) ;; *) rc=1 ;; esac
done
exit $rc
