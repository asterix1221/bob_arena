extends Node2D
## ПР №4 (Godot): сетевой прототип с серверно-авторитетным движением, Client-Side Prediction и
## Server Reconciliation. Это «клей»: ENet + RPC + ввод + отрисовка. Вся логика — в scripts/sim.
##
## Запуск (аргументы после `--`):
##   godot --path godot -- --host                      слушающий сервер (хост тоже играет)
##   godot --path godot -- --join=127.0.0.1            клиент
##   ... --predict=0|1  --lag=100 --jitter=0 --loss=0   режим рывка и эмуляция сети клиента
##   ... --bot=dash_latency --out=run.log               автоматический сценарий + лог (T1–T5)
##   ... --viz=0|1|2|3                                  визуализация предсказания (клавиша F8 переключает в игре)
## Без аргументов: клавиша H — хост, J — клиент к 127.0.0.1.

const PORT_DEFAULT := 24680
const SNAPSHOT_EVERY := 2                    # тиков между снимками (30 Гц)
# Визуализация предсказания (F8 переключает по кругу, --viz=N задаёт стартовый режим).
const VIZ_OFF := 0      # только свой персонаж
const VIZ_GHOST := 1    # + полупрозрачный «призрак» авторитетного положения сервера
const VIZ_FADED := 2    # свой (предсказанный) персонаж полупрозрачный, подтверждённое сервером положение — плотное
const VIZ_FULL := 3     # оба + путь неподтверждённых команд, линия ошибки, подписи
const VIZ_NAMES := ["off", "server ghost", "predicted faded", "full (path + error)"]
const FLASH_MS := 700.0
const SPAWNS := [Vector2(120, 200), Vector2(120, 360), Vector2(120, 520)]

var args := {}
var role := ""                               # "host" | "client" | ""
var emu := NetEmu.new(7)
var t0_us := 0
var tick := 0

var server: ServerSim                        # только хост
var host_cmd_seq := 1
var predictor: ClientPredictor               # только клиент
var my_id := 0
var remotes := {}                            # id -> RemoteInterp
var last_world := {}

var bot: Bot
var bot_tick := 0
var finishing := 0
var quit_at_ms := -1.0
var out: FileAccess
var prev_keys := {}
var hud: Label
var started := false
var disconnected_at_ms := -1.0
var snapshots_in := 0
var viz_mode := VIZ_GHOST
var seen_corrections := 0
var flash_t0_ms := -1.0                      # момент последней коррекции (для красной вспышки)
var flash_pos := Vector2.ZERO


func _ready() -> void:
	t0_us = Time.get_ticks_usec()
	Engine.max_fps = 120
	_parse_args()
	hud = Label.new()
	hud.position = Vector2(16, 12)
	hud.add_theme_color_override("font_color", Color.WHITE)
	hud.add_theme_color_override("font_shadow_color", Color.BLACK)
	add_child(hud)
	emu.configure(float(args.get("lag", 0.0)), float(args.get("jitter", 0.0)), float(args.get("loss", 0.0)))
	emu.rng.seed = int(args.get("seed", 7))
	viz_mode = clampi(int(args.get("viz", VIZ_GHOST)), VIZ_OFF, VIZ_FULL)
	if args.has("out"):
		out = FileAccess.open(str(args["out"]), FileAccess.WRITE)
	if args.has("quit-after"):
		quit_at_ms = float(args["quit-after"]) * 1000.0
	if args.has("bot"):
		bot = Bot.new(str(args["bot"]))
	if args.has("host"):
		_start_host()
	elif args.has("join"):
		_start_client(str(args["join"]))
	else:
		hud.text = "Press H to host (Listen Server) or J to join 127.0.0.1\nOr run with: -- --host / -- --join=<ip>"


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var s := String(a).trim_prefix("--")
		var kv := s.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else true


func _now() -> float:
	return (Time.get_ticks_usec() - t0_us) / 1000.0


func _log(line: String) -> void:
	print(line)
	if out and out.is_open():      # после _finish() файл закрыт, а тики ещё идут до выхода
		out.store_line(line)
		out.flush()


# ------------------------------------------------------------------ старт ролей

func _start_host() -> void:
	role = "host"
	server = ServerSim.new()
	server.add_player(1, SPAWNS[0])
	my_id = 1
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(int(args.get("port", PORT_DEFAULT)), 8)
	if err != OK:
		_log("[NET] cannot create server: error %d" % err)
		get_tree().quit(2)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	started = true
	_log("[NET] LISTEN SERVER started on port %d (host plays as peer 1)" % int(args.get("port", PORT_DEFAULT)))


func _start_client(host: String) -> void:
	role = "client"
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, int(args.get("port", PORT_DEFAULT)))
	if err != OK:
		_log("[NET] cannot connect: error %d" % err)
		get_tree().quit(2)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connection_failed.connect(func(): _log("[NET] connection failed"); get_tree().quit(3))
	multiplayer.server_disconnected.connect(func(): _log("[NET] server disconnected"); disconnected_at_ms = _now())
	_log("[NET] CLIENT connecting to %s, predict_dash=%s lag=%.0f jitter=%.0f loss=%.1f%%" % [host, str(_predict_arg()), emu.lag_ms, emu.jitter_ms, emu.loss_pct])


func _predict_arg() -> bool:
	return str(args.get("predict", "1")) != "0"


func _on_peer_connected(id: int) -> void:
	var idx := server.players.size()
	var spawn: Vector2 = SPAWNS[idx % SPAWNS.size()]
	server.add_player(id, spawn)
	_log("[NET] peer %d connected, spawn=%s" % [id, str(spawn)])
	emu.send(_now(), func(): rpc_id(id, "cli_welcome", id, spawn), true)


func _on_peer_disconnected(id: int) -> void:
	server.remove_player(id)
	_log("[NET] peer %d disconnected" % id)
	if args.has("exit-on-disconnect"):
		quit_at_ms = _now() + 500.0


# ------------------------------------------------------------------ RPC

## Клиент -> сервер: пачка последних неподтверждённых КОМАНД ВВОДА (позиции здесь нет).
@rpc("any_peer", "call_remote", "unreliable_ordered")
func srv_cmds(cmds: Array) -> void:
	if multiplayer.is_server():
		server.receive_cmds(multiplayer.get_remote_sender_id(), cmds)


## Клиент -> сервер (вариант БЕЗ предсказания): «хочу рывок». Решение примет сервер.
@rpc("any_peer", "call_remote", "reliable")
func srv_request_dash() -> void:
	if multiplayer.is_server():
		server.request_dash(multiplayer.get_remote_sender_id())


@rpc("authority", "call_remote", "reliable")
func cli_welcome(id: int, spawn: Vector2) -> void:
	my_id = id
	predictor = ClientPredictor.new(spawn)
	predictor.predict_dash = _predict_arg()
	started = true
	_log("[NET] welcome: my_id=%d spawn=%s" % [id, str(spawn)])


@rpc("authority", "call_remote", "unreliable_ordered")
func cli_owner(snap: Dictionary) -> void:
	if predictor == null:
		return
	snapshots_in += 1
	predictor.now_ms = _now()
	var before := predictor.events.size()
	predictor.on_owner_snapshot(snap)
	for i in range(before, predictor.events.size()):
		_log(predictor.events[i])
	var s: PlayerState = predictor.last_server_state
	var p := predictor.state
	_log("TRACE,%d,%d,%.2f,%.2f,%.2f,%.2f,%d" % [int(_now()), snap["ack"], s.pos.x, s.pos.y, p.pos.x, p.pos.y, predictor.corrections])


@rpc("authority", "call_remote", "unreliable_ordered")
func cli_world(snap: Dictionary) -> void:
	last_world = snap
	var now := _now()
	for id in snap["p"]:
		if id == my_id:
			continue
		if not remotes.has(id):
			remotes[id] = RemoteInterp.new()
		remotes[id].push(snap["tick"], snap["p"][id]["pos"], snap["p"][id]["dash"], now)


# ------------------------------------------------------------------ цикл

func _process(_delta: float) -> void:
	emu.poll(_now())
	if quit_at_ms >= 0.0 and _now() >= quit_at_ms:
		_finish()
		return
	if disconnected_at_ms >= 0.0 and _now() - disconnected_at_ms > 300.0:
		_finish()
		return
	_handle_ui_keys()
	_track_corrections()
	_update_hud()
	queue_redraw()


## Запомнить момент и место новой коррекции — визуализация нарисует там затухающее красное кольцо.
func _track_corrections() -> void:
	if predictor == null:
		return
	if predictor.corrections > seen_corrections:
		seen_corrections = predictor.corrections
		flash_t0_ms = _now()
		flash_pos = predictor.display_pos()


func _physics_process(_delta: float) -> void:
	if not started:
		return
	tick += 1
	var sample := _sample_input()
	if role == "host":
		_host_tick(sample)
	elif role == "client" and predictor != null:
		_client_tick(sample)


func _sample_input() -> Dictionary:
	if bot != null:
		if role == "host" or predictor == null:
			return {"move": Vector2.ZERO, "dash": false}
		var s := bot.sample(bot_tick)
		bot_tick += 1
		if s["cheat"] != null:
			predictor.set_cheat(s["cheat"]["ignore"], s["cheat"]["speed"])
			_log("[CHEAT] t=%d client ignores dash rules=%s speed x%.1f" % [int(_now()), str(s["cheat"]["ignore"]), s["cheat"]["speed"]])
		if s["done"] and finishing == 0:
			finishing = 90                      # «остывание»: дать дойти последним снимкам
		if finishing > 0:
			finishing -= 1
			if finishing == 0:
				_finish()
			return {"move": Vector2.ZERO, "dash": false}
		return {"move": s["move"], "dash": s["dash"]}
	var m := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	return {"move": m, "dash": _just_pressed(KEY_SHIFT)}


func _just_pressed(key: Key) -> bool:
	var down := Input.is_physical_key_pressed(key)
	var was: bool = prev_keys.get(key, false)
	prev_keys[key] = down
	return down and not was


# Пакет, задержанный эмуляцией, может «долететь» уже после отключения собеседника — тогда не шлём (иначе
# Godot пишет в консоль ошибки про неизвестный peer, хотя на игру это не влияет).
func _rpc_if_connected(peer_id: int, method: String, arg: Variant = null) -> void:
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	if multiplayer.is_server() and not multiplayer.get_peers().has(peer_id):
		return
	if arg == null:
		rpc_id(peer_id, method)
	else:
		rpc_id(peer_id, method, arg)


func _host_tick(sample: Dictionary) -> void:
	# Хост — авторитет: его ввод идёт прямо в серверную симуляцию, предсказание не нужно.
	var cmd := PlayerSim.make_cmd(host_cmd_seq, sample["move"], sample["dash"])
	host_cmd_seq += 1
	server.receive_cmds(1, [cmd])
	for line in server.tick():
		_log(line)
	if tick % SNAPSHOT_EVERY == 0:
		var world := server.world_snapshot()
		for id in server.players:
			if id == 1:
				continue
			var owner_snap := server.owner_snapshot(id)
			emu.send(_now(), func(): _rpc_if_connected(id, "cli_owner", owner_snap))
			emu.send(_now(), func(): _rpc_if_connected(id, "cli_world", world))


func _client_tick(sample: Dictionary) -> void:
	predictor.now_ms = _now()
	if sample["dash"]:
		_log("[INPUT] t=%d dash key pressed (tick %d)" % [int(_now()), tick])
	var before := predictor.events.size()
	var res := predictor.local_input(sample["move"], sample["dash"])
	for i in range(before, predictor.events.size()):
		_log(predictor.events[i])
	_log("POS,%d,%d,%.2f,%.2f" % [int(_now()), predictor.next_seq - 1, predictor.state.pos.x, predictor.state.pos.y])
	var cmds := predictor.packet_cmds()
	emu.send(_now(), func(): _rpc_if_connected(1, "srv_cmds", cmds))
	if res["send_dash_request"]:
		emu.send(_now(), func(): _rpc_if_connected(1, "srv_request_dash"), true)


func _handle_ui_keys() -> void:
	if role == "":
		if _just_pressed(KEY_H):
			_start_host()
		elif _just_pressed(KEY_J):
			_start_client("127.0.0.1")
		return
	if role != "client" or predictor == null or bot != null:
		return
	if _just_pressed(KEY_F1):
		predictor.set_cheat(true, 1.0)
		_log("[CHEAT] client ignores dash cooldown/stamina")
	if _just_pressed(KEY_F2):
		predictor.set_cheat(true, 3.0)
		_log("[CHEAT] client ignores rules and dashes x3 faster")
	if _just_pressed(KEY_F3):
		predictor.set_cheat(false, 1.0)
		_log("[CHEAT] off")
	if _just_pressed(KEY_F4):
		predictor.predict_dash = not predictor.predict_dash
		_log("[MODE] predict_dash=%s" % str(predictor.predict_dash))
	if _just_pressed(KEY_F8):
		viz_mode = (viz_mode + 1) % VIZ_NAMES.size()
		_log("[VIZ] mode=%d (%s)" % [viz_mode, VIZ_NAMES[viz_mode]])
	if _just_pressed(KEY_F5):
		emu.configure(0.0, 0.0, 0.0)
	if _just_pressed(KEY_F6):
		emu.configure(100.0, 0.0, 0.0)
	if _just_pressed(KEY_F7):
		emu.configure(175.0, 25.0, 4.0)


func _finish() -> void:
	if role == "client" and predictor != null:
		var srv := predictor.last_server_state
		var final_err := predictor.state.pos.distance_to(srv.pos)
		_log("[RESULT] role=client predict_dash=%s lag=%.0f jitter=%.0f loss=%.1f" % [str(predictor.predict_dash), emu.lag_ms, emu.jitter_ms, emu.loss_pct])
		_log("[RESULT] corrections=%d max_error_px=%.2f last_error_px=%.2f rejects_seen=%d snapshots_in=%d" % [predictor.corrections, predictor.max_error, predictor.last_error, predictor.rejects_seen, snapshots_in])
		_log("[RESULT] local_response_ms=%s" % str(predictor.local_response_ms))
		_log("[RESULT] confirm_response_ms=%s" % str(predictor.confirm_response_ms))
		_log("[RESULT] net_sent=%d net_dropped=%d final_pred_vs_server_px=%.3f" % [emu.sent, emu.dropped, final_err])
	elif role == "host":
		_log("[RESULT] role=host server_stats=%s tick=%d" % [str(server.stats), server.tick_no])
	if out:
		out.close()
	get_tree().quit(0)


# ------------------------------------------------------------------ вид

func _update_hud() -> void:
	if role == "":
		return
	var lines: PackedStringArray = []
	lines.append("Role: %s   my_id=%d   lag=%.0f ms (one way) jitter=%.0f loss=%.1f%%" % [role, my_id, emu.lag_ms, emu.jitter_ms, emu.loss_pct])
	if role == "client" and predictor != null:
		lines.append("Dash mode: %s" % ("CLIENT-SIDE PREDICTION" if predictor.predict_dash else "NO PREDICTION (wait for server)"))
		var s := predictor.state
		lines.append("Stamina: %.0f   Cooldown: %.2f s%s" % [s.stamina, s.cooldown_left / 60.0, "   [DASHING]" if s.dash_left > 0 else ""])
		lines.append("Corrections: %d   last error: %.1f px   pending cmds: %d" % [predictor.corrections, predictor.last_error, predictor.pending.size()])
		var lr := "-" if predictor.confirm_response_ms.is_empty() else "%.0f ms" % predictor.confirm_response_ms.back()
		var ll := "-" if predictor.local_response_ms.is_empty() else "%.0f ms" % predictor.local_response_ms.back()
		lines.append("Last dash response: local %s, server-confirmed %s" % [ll, lr])
		lines.append("Prediction view [F8]: %s   (client ahead of server: %.1f px)" % [VIZ_NAMES[viz_mode], predictor.prediction_lead_px()])
	elif role == "host" and server != null:
		var h: PlayerState = server.players[1]["state"]
		lines.append("Stamina: %.0f   Cooldown: %.2f s   peers: %d" % [h.stamina, h.cooldown_left / 60.0, server.players.size() - 1])
	lines.append("WASD move, Shift dash | client: F1/F2 cheat, F3 off, F4 toggle prediction, F5/F6/F7 net profile none/100ms/175ms+4%, F8 prediction view")
	hud.text = "\n".join(lines)


func _draw() -> void:
	draw_rect(PlayerSim.ARENA, Color(0.10, 0.11, 0.14), true)
	draw_rect(PlayerSim.ARENA, Color(0.35, 0.35, 0.4), false, 2.0)
	for w in PlayerSim.WALLS:
		draw_rect(w, Color(0.45, 0.45, 0.5), true)
	var radius: float = DashRules.default_cfg()["radius"]
	if role == "host" and server != null:
		for id in server.players:
			var s: PlayerState = server.players[id]["state"]
			draw_circle(s.pos, radius, Color(0.3, 0.9, 0.4) if id == 1 else Color(0.4, 0.6, 1.0))
			if s.dash_left > 0:
				draw_arc(s.pos, radius + 5, 0, TAU, 24, Color.WHITE, 2.0)
	elif role == "client" and predictor != null:
		_draw_client_player(radius)
		var now := _now()
		for id in remotes:
			var r: RemoteInterp = remotes[id]
			var rp := r.sample(now)
			draw_circle(rp, radius, Color(0.4, 0.6, 1.0))
			if r.dashing:
				draw_arc(rp, radius + 5, 0, TAU, 24, Color.WHITE, 2.0)


## Свой персонаж на клиенте + визуализация предсказания.
##   зелёный — положение, которое клиент ПРЕДСКАЗАЛ и показывает (применено сразу, сервер ещё не подтвердил);
##   оранжевый — последнее АВТОРИТЕТНОЕ положение от сервера (отстаёт на ≈ RTT/2 + интервал снимка).
## Красное кольцо — клиент только что получил коррекцию и перемотал/переиграл команды.
func _draw_client_player(radius: float) -> void:
	var srv: PlayerState = predictor.last_server_state
	var me := predictor.display_pos()
	var mine := Color(0.3, 0.9, 0.4)
	var srv_col := Color(1.0, 0.75, 0.25)
	var pred_alpha := 1.0
	var srv_alpha := 0.0
	match viz_mode:
		VIZ_GHOST:
			srv_alpha = 0.45
		VIZ_FADED:
			pred_alpha = 0.4
			srv_alpha = 1.0
		VIZ_FULL:
			pred_alpha = 0.5
			srv_alpha = 0.7
	# 1) авторитетное положение сервера (под предсказанным)
	if srv_alpha > 0.0:
		draw_circle(srv.pos, radius, Color(srv_col.r, srv_col.g, srv_col.b, srv_alpha))
		draw_arc(srv.pos, radius, 0, TAU, 28, Color(srv_col.r, srv_col.g, srv_col.b, 1.0), 1.5)
		if srv.dash_left > 0:
			draw_arc(srv.pos, radius + 5, 0, TAU, 24, Color(srv_col.r, srv_col.g, srv_col.b, 1.0), 2.0)
	# 2) путь неподтверждённых команд (только полная визуализация)
	if viz_mode == VIZ_FULL:
		var path := predictor.pending_path()
		if path.size() >= 2:
			draw_polyline(path, Color(mine.r, mine.g, mine.b, 0.6), 2.0)
			for i in range(1, path.size()):
				draw_circle(path[i], 2.5, Color(mine.r, mine.g, mine.b, 0.9))
	# 3) предсказанный персонаж
	draw_circle(me, radius, Color(mine.r, mine.g, mine.b, pred_alpha))
	if predictor.state.dash_left > 0:
		draw_arc(me, radius + 5, 0, TAU, 24, Color(1, 1, 1, maxf(pred_alpha, 0.6)), 2.0)
	# 4) линия «опережение/ошибка» и подписи
	if viz_mode == VIZ_FULL:
		draw_line(srv.pos, me, Color(1, 1, 1, 0.5), 1.0)
		var font := ThemeDB.fallback_font
		draw_string(font, srv.pos + Vector2(radius + 4, -radius - 2), "server", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, srv_col)
		draw_string(font, me + Vector2(radius + 4, radius + 12), "predicted (+%.0f px, %d cmd)" % [predictor.prediction_lead_px(), predictor.pending.size()], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, mine)
	# 5) вспышка коррекции
	if viz_mode != VIZ_OFF and flash_t0_ms >= 0.0:
		var age := _now() - flash_t0_ms
		if age < FLASH_MS:
			var k := 1.0 - age / FLASH_MS
			draw_arc(flash_pos, radius + 6.0 + age * 0.04, 0, TAU, 32, Color(1.0, 0.25, 0.2, k), 3.0)
