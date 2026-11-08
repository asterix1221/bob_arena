#!/usr/bin/env bash
# Совместимость порта на GDScript с C++-реализацией: собирает pong_server_app, запускает его и гоняет
# тесты на реальных UDP-сокетах (включая Ping -> C++ Pong). Запуск из корня репозитория:
#   GODOT=/путь/к/godot ./tools/net_interop.sh
set -euo pipefail
GODOT="${GODOT:-godot}"
PORT="${PORT:-27090}"
g++ -std=c++17 -O2 protocol/protocol.cpp telemetry/transport.cpp server/pong_server.cpp -o /tmp/pong_server_app_interop
/tmp/pong_server_app_interop "$PORT" --delay-ms=20 >/tmp/pong_server_interop.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 0.5
"$GODOT" --headless --path godot --import >/dev/null 2>&1 || true
"$GODOT" --headless --path godot -s res://tests/run_udp_tests.gd -- --cpp-port="$PORT"
