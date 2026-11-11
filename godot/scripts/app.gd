class_name App
extends Node2D
## Приложение: меню -> лобби -> матч -> итоги. Склеивает транспорт (NetNode/UdpLink), серверную часть (GameHost) или клиентскую
## (GameClient), ввод, отрисовку и интерфейс. Игровой логики здесь нет — она в scripts/game/.
## Один и тот же код: хост играет сам (Listen Server), остальные подключаются по UDP; «Тренировка с ботом» запускает хост
## и бота-клиента в этом же процессе (по реальному UDP на localhost).
##
## Параметры запуска (после --): --debug (читы F9-F11), --shots=<каталог> (автоскриншоты экранов),
## --lag-test (замер инпутлага), --host / --join=<ip> --port=<порт> --name=<имя> (прямой запуск),
## --predict=0|1 (предсказание рывка у клиента, F4), --viz=0..3 (визуализация предсказания, F8), --sprites=0|1 (спрайты/фигуры, F6),
## --scenario=T1..T5 [--out=<лог>] (автоматический сценарий ПР №4: хост + бот-клиент, лог и итоги),
## --encrypt=1 (ПР №6: шифрование трафика X25519 + HKDF + AES-256-GCM; включать и на хосте, и на клиенте).

const DEFAULT_PORT := 24680

var ui: GameUI
var view: ArenaView
var screen := "menu"
var mode := ""                      # "", "host", "client"
var link: UdpLink
var vhub: LoopHub = null            # виртуальный сеанс (start_virtual): хаб, хост и ссылки
var vhost: GameHost = null
var vhost_link: LoopLink = null
var vhost_id := -1
var net: NetNode
var host: GameHost
var client: GameClient
var lab: ReplLab = null              # ПР №5: лаборатория репликации (экран "lab")
var bots: Array = []                # [{link, net, client, brain}]
var my_id := -1
var input := InputLatch.new()
var lag_meter := InputLagMeter.new()
var show_hp := true
var show_graph := false
var debug := false
var preset := 0
var vsync_index := 3
var acc := 0.0
var render_offset := Vector2.ZERO   # сглаживание коррекций своего персонажа (только вид)
var results := {}                   # id -> {kills, damage, secs, died}
var winner := GC.NO_PLAYER
var cheat_no_rules := false
var encryption := false              # ПР №6: шифровать трафик (X25519 + HKDF + AES-256-GCM); флаг --encrypt=1 или меню
var predict_dash := true            # ПР №4: рывок предсказывается клиентом сразу (false — ждёт ответа сервера); F4
var viz_mode := PredViz.GHOST       # визуализация предсказания (PredViz.*); F8
var viz_flash_t0_ms := -1.0         # момент последней коррекции своего персонажа (красное кольцо)
var viz_flash_pos := Vector2.ZERO
var autoplay: ScenarioBrain = null   # сценарий ПР №4: вместо клавиатуры клиентом управляет скрипт
var ticks_last_frame := 0
var fps_smooth := 0.0
var frame_ms := 0.0
var session_started_ms := 0
var round_started_ms := 0

var _players_cache: Array = []
var _own_shown := Vector2.ZERO
var _hist := {"rtt": [], "loss": [], "corr": [], "snap": []}
var _hist_timer := 0.0
var _report := {}
var _result_deadline := -1
var _join_deadline := -1
var _countdown_hide_at := 0
var _args := {}
var _shots: Node = null


func _ready() -> void:
	_parse_args()
	debug = _args.has("debug")
	Input.use_accumulated_input = false        # событие -> тик без накопления за кадр (ниже задержка)
	ui = GameUI.new()
	add_child(ui)
	view = ArenaView.new()
	view.app = self
	add_child(view)
	move_child(view, 0)
	ui.host_requested.connect(func(n: String, c: int, p: int) -> void: start_host(n, c, p, false))
	ui.bot_requested.connect(func(n: String, c: int) -> void: start_host(n, c, _free_port(), true))
	ui.join_requested.connect(start_join)
	ui.start_requested.connect(_on_start_pressed)
	ui.leave_requested.connect(leave_to_menu)
	ui.rematch_requested.connect(_on_rematch_pressed)
	ui.resume_requested.connect(func() -> void: set_pause(false))
	ui.quit_requested.connect(func() -> void: get_tree().quit())
	ui.net_preset_changed.connect(set_net_preset)
	ui.encryption_changed.connect(func(on: bool) -> void: encryption = on)
	ui.predict_changed.connect(set_predict_dash)
	ui.viz_changed.connect(set_viz_mode)
	ui.models_changed.connect(set_sprites)
	ui.vsync_changed.connect(set_vsync)
	ui.repl_open_requested.connect(start_lab)
	ui.repl_flag_changed.connect(func(k: String, on: bool) -> void:
		if lab != null:
			lab.set_flag(k, on))
	ui.repl_preset_changed.connect(func(p: String) -> void:
		if lab != null:
			lab.apply_preset_name(p))
	ui.repl_overlay_changed.connect(func(k: String, on: bool) -> void:
		if lab != null:
			lab.set_overlay(k, on))
	ui.repl_measure_requested.connect(func() -> void:
		if lab != null:
			lab.run_measure(10))
	RenderingServer.frame_post_draw.connect(func() -> void: lag_meter.on_frame_drawn(Time.get_ticks_usec()))
	set_vsync(3)
	if _args.has("preset"):
		set_net_preset(int(_args["preset"]))
		ui.preset_opt.select(clampi(int(_args["preset"]), 0, 2))
	if _args.has("encrypt"):
		encryption = String(_args["encrypt"]) != "0"
		ui.enc_opt.select(1 if encryption else 0)
	if _args.has("predict"):
		predict_dash = String(_args["predict"]) != "0"
	if _args.has("viz"):
		viz_mode = clampi(int(_args["viz"]), 0, PredViz.NAMES.size() - 1)
	if _args.has("sprites"):
		Sprites.enabled = String(_args["sprites"]) != "0"
	ui.sync_pred_settings(predict_dash, viz_mode, Sprites.enabled)
	ui.show_only("menu")
	if _args.has("shots"):
		_shots = Shots.new()
		_shots.app = self
		add_child(_shots)
		_shots.run(String(_args["shots"]))
	elif _args.has("scenario"):
		var scn := Scenario.new()
		scn.app = self
		add_child(scn)
		scn.run(String(_args["scenario"]))
	elif _args.has("lab"):
		start_lab(String(_args.get("repl", "optimized")), String(_args.get("repl-shot", "")))
	elif _args.has("host"):
		start_host(String(_args.get("name", "Игрок")), int(_args.get("color", 0)), int(_args.get("port", DEFAULT_PORT)), _args.has("bot"))
	elif _args.has("join"):
		start_join(String(_args.get("name", "Игрок")), int(_args.get("color", 1)), String(_args["join"]), int(_args.get("port", DEFAULT_PORT)))


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"


# ------------------------------------------------------------------ сессия: хост / клиент / бот

func _free_port() -> int:
	return DEFAULT_PORT + 1 + randi() % 300


func start_host(player_name: String, color: int, port: int, with_bot: bool) -> void:
	_close_session()
	link = UdpLink.new(1)
	var err := link.listen(port)
	if err != OK:
		ui.set_menu_message("Не удалось открыть порт %d (ошибка %d). Он занят?" % [port, err])
		link = null
		return
	_apply_emulation(link)
	net = NetNode.new(link)
	net.encryption = encryption
	host = GameHost.new(net, randi())
	host.event.connect(_on_game_event)
	host.roster_changed.connect(_refresh_lobby)
	host.phase_changed.connect(_on_phase)
	host.dash_rejected.connect(func(id: int, r: String) -> void: if id == my_id: ui.add_feed("Рывок отклонён сервером: %s" % r, Color("ffb86b")))
	my_id = host.add_local_player(_clean_name(player_name), color)
	mode = "host"
	if with_bot:
		_spawn_bot(port, (color + 1) % GC.COLORS.size())
	_enter_lobby()


func _spawn_bot(port: int, color: int) -> void:
	var bl := UdpLink.new(2)
	bl.connect_to("127.0.0.1", port)
	_apply_emulation(bl)
	var bn := NetNode.new(bl)
	bn.encryption = encryption
	bn.add_peer(1)
	var bc := GameClient.new(bn, 1)
	bc.join("Бот", color)
	bots.append({"link": bl, "net": bn, "client": bc, "brain": BotBrain.new()})


func start_join(player_name: String, color: int, ip: String, port: int) -> void:
	_close_session()
	link = UdpLink.new(1)
	var err := link.connect_to(ip, port)
	if err != OK:
		ui.set_menu_message("Не удалось создать сокет (ошибка %d)." % err)
		link = null
		return
	_apply_emulation(link)
	net = NetNode.new(link)
	net.encryption = encryption
	net.add_peer(1)
	client = GameClient.new(net, 1)
	_attach_client()
	mode = "client"
	client.join(_clean_name(player_name), color)
	_join_deadline = Time.get_ticks_msec() + 5000
	ui.set_menu_message("Подключение к %s:%d …" % [ip, port])


## Общая настройка клиента (обычного и виртуального): настройки ПР №4 и подписка на сигналы.
func _attach_client() -> void:
	client.predict_dash = predict_dash
	client.dash_resolved.connect(_on_dash_resolved)
	client.connected.connect(func(id: int) -> void:
		my_id = id
		_join_deadline = -1
		_enter_lobby())
	client.rejected.connect(_on_rejected)
	client.disconnected.connect(_on_disconnected)
	client.event.connect(_on_game_event)
	client.roster_changed.connect(_refresh_lobby)
	client.phase_changed.connect(_on_phase)
	client.correction.connect(_on_correction)


## ВИРТУАЛЬНЫЙ сеанс для воспроизводимой записи видео/скриншотов (ПР №4): хост-игрок (стоит) и клиент в одном процессе поверх
## LoopHub — виртуальное время, без сокетов, поэтому результат не зависит от скорости рендеринга и загрузки процессора.
## Та же серверная и клиентская логика (GameHost/GameClient), что и по UDP; эмуляция сети — на датаграммах обеих сторон.
func start_virtual(preset_index: int) -> void:
	_close_session()
	preset = preset_index
	vhub = LoopHub.new()
	vhost_link = LoopLink.new(vhub, 1)
	var cl := LoopLink.new(vhub, 2)
	_apply_emulation(vhost_link)
	_apply_emulation(cl)
	vhost = GameHost.new(NetNode.new(vhost_link), 7)
	vhost_id = vhost.add_local_player("Хост", 0)
	net = NetNode.new(cl)
	net.add_peer(vhost_link.link_id)
	client = GameClient.new(net, vhost_link.link_id)
	_attach_client()
	mode = "client"
	client.join("Клиент", 1)


func _clean_name(n: String) -> String:
	var s := n.strip_edges()
	return s if not s.is_empty() else "Игрок"


func _close_session() -> void:
	if mode == "client" and client != null:
		client.leave()
		net.process()
	elif mode == "host" and host != null:
		net.broadcast(func(q: int) -> PackedByteArray: return Proto.leave(q, 1), true)
	for b in bots:
		b["link"].close()
	bots.clear()
	if link != null:
		link.close()
	link = null
	net = null
	host = null
	client = null
	vhub = null
	vhost = null
	vhost_link = null
	mode = ""
	my_id = -1
	results.clear()
	winner = GC.NO_PLAYER
	render_offset = Vector2.ZERO
	_result_deadline = -1
	_join_deadline = -1
	_players_cache = []
	input.reset()
	view.anim.clear()
	view.fx = Fx.new()
	ui.clear_feed()
	ui.countdown_label.text = ""


func leave_to_menu() -> void:
	_close_session()
	_close_lab()
	screen = "menu"
	ui.set_menu_message("")
	ui.show_only("menu")


func _enter_lobby() -> void:
	screen = "lobby"
	ui.set_menu_message("")
	ui.show_only("lobby")
	_refresh_lobby()


func _on_rejected(status: int) -> void:
	var msg := "Хост отказал во входе."
	if status == Proto.WELCOME_FULL:
		msg = "Нет мест или матч уже идёт."
	elif status == Proto.WELCOME_BAD_VERSION:
		msg = "Другая версия игрового протокола."
	_close_session()
	screen = "menu"
	ui.show_only("menu")
	ui.set_menu_message(msg)


func _on_disconnected(reason: String) -> void:
	var text := "Связь с хостом потеряна (нет пакетов 3 секунды)."
	if reason == "no_welcome":
		text = "Хост не отвечает."
	elif reason == "host_left":
		text = "Хост завершил игру."
	elif reason != "timeout":
		text = "Соединение закрыто: %s" % reason
	if screen == "menu":
		_close_session()
		ui.set_menu_message(text)
		return
	_close_session()
	screen = "disconnected"
	ui.disc_msg.text = text
	ui.show_only("disconnected")


func _on_correction(err_px: float, _replayed: int) -> void:
	if client == null:
		return
	viz_flash_t0_ms = float(Time.get_ticks_msec())     # красное кольцо визуализации предсказания
	viz_flash_pos = _own_shown
	if err_px < 120.0:
		# физика уже исправлена; визуально плавно «подтягиваем» персонажа из того места, где он был нарисован
		var new_pos := Vector2(client.state.x, client.state.y) / float(GC.SUB)
		render_offset = (_own_shown - new_pos).limit_length(120.0)
	else:
		render_offset = Vector2.ZERO


## Сервер разрешил нажатие рывка. local_ms — через сколько после нажатия рывок появился на экране (с предсказанием ≈ 0,
## без — ≈ RTT), confirm_ms — когда пришло подтверждение сервера.
func _on_dash_resolved(accepted: bool, local_ms: float, confirm_ms: float, _hint: String) -> void:
	if accepted:
		ui.add_feed("Рывок: экран %.0f мс, сервер %.0f мс" % [local_ms, confirm_ms], Color("9fe870"))
	else:
		ui.add_feed("Рывок ОТКЛОНЁН сервером (%.0f мс)" % confirm_ms, Color("ffb86b"))


## Предсказание рывка вкл/выкл (F4 или настройка). Без предсказания рывок на экране появляется только после ответа сервера.
func set_predict_dash(on: bool) -> void:
	predict_dash = on
	if client != null:
		client.predict_dash = on
	if _args.has("sprites"):
		Sprites.enabled = String(_args["sprites"]) != "0"
	ui.sync_pred_settings(predict_dash, viz_mode, Sprites.enabled)


## Спрайты (пиксель-арт из assets/sprites) или прежние нарисованные фигуры (F6 или настройка «Модели персонажей»).
func set_sprites(on: bool) -> void:
	Sprites.enabled = on
	ui.sync_pred_settings(predict_dash, viz_mode, Sprites.enabled)


func set_viz_mode(i: int) -> void:
	viz_mode = clampi(i, 0, PredViz.NAMES.size() - 1)
	ui.sync_pred_settings(predict_dash, viz_mode, Sprites.enabled)


# ------------------------------------------------------------------ кнопки лобби / итогов

func _on_start_pressed() -> void:
	if host != null:
		host.start_match()


func _on_rematch_pressed() -> void:
	if host != null:
		host.rematch()


## ПР №5: открыть лабораторию репликации (меню «Репликация (ПР №5)»). Профиль сети из настроек применяется к её каналам.
func start_lab(preset_name: String, shot_path: String = "") -> void:
	_close_session()
	_close_lab()
	view.visible = false
	lab = ReplLab.new()
	lab.shot_path = shot_path
	add_child(lab)
	lab.cfg_changed.connect(func() -> void: ui.sync_repl(lab.cfg, lab.overlays))
	lab.measure_done.connect(ui.show_repl_measure)
	lab.start(preset_name, 3, preset)
	screen = "lab"
	ui.show_only("lab")
	ui.sync_repl(lab.cfg, lab.overlays)
	ui.sync_net_preset(preset)


func _close_lab() -> void:
	if lab != null:
		lab.queue_free()
		lab = null
	view.visible = true
	if ui != null and ui.repl_result != null:
		ui.repl_result.visible = false


func set_pause(on: bool) -> void:
	if screen not in ["game", "pause"]:
		return
	screen = "pause" if on else "game"
	ui.show_only("pause" if on else "game")
	input.reset()


func set_net_preset(i: int) -> void:
	preset = i
	if lab != null:
		lab.apply_net_preset(i)
	if ui != null and ui.lab_net_opt != null:
		ui.sync_net_preset(i)
	_apply_emulation(link)
	for b in bots:
		_apply_emulation(b["link"])


func _apply_emulation(l: Link) -> void:
	if l == null:
		return
	match preset:
		1: l.set_emulation(100.0, 0.0, 0.0)
		2: l.set_emulation(175.0, 25.0, 0.04)
		_: l.set_emulation(0.0, 0.0, 0.0)


func set_vsync(i: int) -> void:
	vsync_index = i
	var modes := [DisplayServer.VSYNC_DISABLED, DisplayServer.VSYNC_ENABLED, DisplayServer.VSYNC_ADAPTIVE, DisplayServer.VSYNC_MAILBOX]
	DisplayServer.window_set_vsync_mode(modes[clampi(i, 0, 3)])


# ------------------------------------------------------------------ события игры

func name_of(id: int) -> String:
	if host != null and host.slots.has(id):
		return (host.slots[id].name as PackedByteArray).get_string_from_utf8()
	if client != null and client.roster.has(id):
		return client.roster[id]["name"]
	return "Игрок %d" % (id + 1)


func color_of(id: int) -> Color:
	var idx := 0
	if host != null and host.slots.has(id):
		idx = host.slots[id].color
	elif client != null and client.roster.has(id):
		idx = client.roster[id]["color"]
	return GC.COLORS[idx % GC.COLORS.size()]


func _on_game_event(kind: int, a: int, b: int, x: int, y: int, v: int) -> void:
	match kind:
		GC.EV_HIT:
			view.fx.hit(Vector2(x, y), 1 if a < b else -1, v)
		GC.EV_PICKUP:
			view.fx.pickup(Vector2(x, y - 16), GC.RUNE_COLORS[b], b == GC.R_HEALTH)
			ui.add_feed("%s: %s" % [name_of(a), GC.RUNE_NAMES[b]], GC.RUNE_COLORS[b].lightened(0.2))
			if a == my_id:
				ui.add_feed(GC.RUNE_HINTS[b], Color(0.85, 0.9, 1))
		GC.EV_DEATH:
			view.fx.death(Vector2(x, clampf(y - 24, 0, 700)), color_of(a))
			var by := "— падение с арены" if v == 1 and b == GC.NO_PLAYER else ("— за ареной после удара (%s)" % name_of(b) if v == 1 else "— побеждён (%s)" % name_of(b))
			ui.add_feed("%s %s" % [name_of(a), by], Color("ff8a80"))
		GC.EV_COUNTDOWN:
			if screen in ["lobby", "result", "menu"]:
				screen = "game"
				ui.show_only("game")
				ui.clear_feed()
				results.clear()
			ui.countdown_label.text = str(v)
			ui.countdown_label.modulate.a = 1.0
			round_started_ms = 0
		GC.EV_ROUND_START:
			ui.countdown_label.text = "БОЙ!"
			_countdown_hide_at = Time.get_ticks_msec() + 900
			round_started_ms = Time.get_ticks_msec()
			results.clear()
		GC.EV_ROUND_END:
			winner = a
			_result_deadline = Time.get_ticks_msec() + 1400
		GC.EV_STATS:
			results[a] = {"kills": b, "damage": v, "secs": x, "died": y == 1}
		GC.EV_LOBBY:
			if screen != "menu":
				screen = "lobby"
				ui.show_only("lobby")
				_refresh_lobby()
		GC.EV_JOINED, GC.EV_LEFT:
			if kind == GC.EV_LEFT:
				ui.add_feed("%s вышел" % name_of(a), Color(0.75, 0.78, 0.85))
			_refresh_lobby()


func _on_phase(p: int) -> void:
	if p == GC.PHASE_PLAYING or p == GC.PHASE_COUNTDOWN:
		if screen in ["lobby", "result"]:
			screen = "game"
			ui.show_only("game")
	elif p == GC.PHASE_LOBBY and screen in ["result", "game", "pause"]:
		screen = "lobby"
		ui.show_only("lobby")
		_refresh_lobby()


func _show_result() -> void:
	_result_deadline = -1
	if mode == "":
		return
	var outcome := "draw"
	if winner != GC.NO_PLAYER:
		outcome = "win" if winner == my_id else "lose"
	var rows := []
	var ids: Array = results.keys()
	ids.sort()
	for id in ids:
		var r: Dictionary = results[id]
		var cidx := 0
		if host != null and host.slots.has(id):
			cidx = host.slots[id].color
		elif client != null and client.roster.has(id):
			cidx = client.roster[id]["color"]
		rows.append({"name": name_of(id), "color": cidx, "kills": r["kills"], "damage": r["damage"], "secs": r["secs"], "winner": id == winner})
	screen = "result"
	ui.show_result(outcome, name_of(winner) if winner != GC.NO_PLAYER else "", rows, mode == "host")
	ui.show_only("result")


func _refresh_lobby() -> void:
	if mode == "":
		return
	var entries := []
	if host != null:
		for e in host.roster_entries():
			entries.append({"name": (e[3] as PackedByteArray).get_string_from_utf8(), "color": e[1], "host": e[2] & 1 != 0, "me": e[0] == my_id})
	elif client != null:
		var ids: Array = client.roster.keys()
		ids.sort()
		for id in ids:
			var r: Dictionary = client.roster[id]
			entries.append({"name": r["name"], "color": r["color"], "host": int(r["flags"]) & 1 != 0, "me": id == my_id})
	var info := ""
	if mode == "host":
		info = "Адрес для друзей: %s, порт %d.\nДля старта нужно минимум 2 игрока (до 4)." % [_local_ips(), link.local_port() if link != null else 0]
	else:
		info = "Ждём, пока хост начнёт игру…"
	ui.update_lobby(entries, mode == "host", info, host != null and host.slots.size() >= 2)


func _local_ips() -> String:
	var out: Array[String] = []
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	return ", ".join(out) if not out.is_empty() else "127.0.0.1"


# ------------------------------------------------------------------ ввод

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var focus := get_viewport().gui_get_focus_owner()
		var typing := focus is LineEdit
		match event.physical_keycode:
			KEY_ESCAPE:
				if screen == "game":
					set_pause(true)
				elif screen == "pause":
					set_pause(false)
				elif screen == "lab":
					leave_to_menu()
			KEY_H:
				if not typing:
					show_hp = not show_hp
					view.show_hp = show_hp
			KEY_F3:
				show_graph = not show_graph
				ui.net_graph.visible = show_graph
			KEY_F4:
				if not typing:
					set_predict_dash(not predict_dash)
					ui.add_feed("Предсказание рывка: %s" % ("ВКЛ" if predict_dash else "ВЫКЛ (ждём ответа сервера)"), Color("7aa2ff"))
			KEY_F6:
				if not typing:
					set_sprites(not Sprites.enabled)
					ui.add_feed("Модели персонажей: %s" % ("спрайты" if Sprites.enabled else "фигуры"), Color("7aa2ff"))
			KEY_F8:
				if not typing:
					set_viz_mode((viz_mode + 1) % PredViz.NAMES.size())
					ui.add_feed("Визуализация предсказания: %s" % PredViz.NAMES[viz_mode], Color("7aa2ff"))
			KEY_F9:
				if debug and client != null and client.state.alive:
					client.state.x += 300 * GC.SUB      # «читер» телепортирует себя: сервер вернёт на место
					ui.add_feed("[debug] локальный телепорт +300 px", Color("ffb86b"))
			KEY_F10:
				if debug:
					cheat_no_rules = not cheat_no_rules
					ui.add_feed("[debug] читерский рывок без кулдауна: %s" % ("ВКЛ" if cheat_no_rules else "выкл"), Color("ffb86b"))
			KEY_F11:
				if debug:
					set_net_preset((preset + 1) % 3)
					ui.add_feed("[debug] сеть: %s" % GameUI.NET_PRESETS[preset], Color("ffb86b"))
	if screen == "game":
		input.handle(event, Time.get_ticks_usec())


# ------------------------------------------------------------------ главный цикл

func _process(dt: float) -> void:
	frame_ms = dt * 1000.0
	fps_smooth = lerpf(fps_smooth, 1.0 / maxf(dt, 0.0001), 0.05)
	var now_ms := Time.get_ticks_msec()
	if net != null:
		net.process()                     # приём в начале кадра: ниже задержка, чем ждать тика
	for b in bots:
		b["client"].process_net()
	var step := 1.0 / GC.TICK_HZ
	acc = minf(acc + dt, 0.1)
	ticks_last_frame = 0
	while acc >= step and ticks_last_frame < 8:
		acc -= step
		ticks_last_frame += 1
		_sim_tick()
	_decay_offset(dt)
	_players_cache = _build_players()
	_update_ui(now_ms)
	_hist_timer += dt
	if _hist_timer >= 0.1:
		_hist_timer = 0.0
		_report = _net_report()
		ui.net_graph.set_report(_report if show_graph else {})
	if _result_deadline > 0 and now_ms >= _result_deadline:
		_show_result()
	if _join_deadline > 0 and now_ms >= _join_deadline and my_id < 0:
		_join_deadline = -1
		_on_disconnected("no_welcome")
	if _countdown_hide_at > 0 and now_ms >= _countdown_hide_at:
		_countdown_hide_at = 0
		ui.countdown_label.text = ""


func _sim_tick() -> void:
	var cmd: Array = [0, 0, []]
	if screen == "game":
		cmd = input.take()
	else:
		input.take()
	if mode == "host" and host != null:
		host.host_input(my_id, cmd[0], cmd[1])
		for b in bots:
			var bc: Array = b["brain"].think(b["client"])
			b["client"].local_tick(bc[0], bc[1])
		host.tick_once()
	elif mode == "client" and client != null:
		if vhub != null:
			vhub.advance_us(8333)                      # один тик виртуального времени (1/120 с)
			net.process()
		if autoplay != null:
			var ab: Array = autoplay.think(client)      # скрипт сценария ПР №4 вместо клавиатуры (он же включает чит у клиента)
			cmd = [ab[0], ab[1], []]
		else:
			client.cheat_no_rules = cheat_no_rules        # чит применяется внутри клиента перед каждым локальным шагом
		var press_us := 0
		if (int(cmd[1]) & Proto.BTN_DASH) != 0 and not (cmd[2] as Array).is_empty():
			press_us = int(cmd[2][0])                  # момент нажатия клавиши (для замера отклика)
		client.local_tick(cmd[0], cmd[1], press_us)
		if vhub != null:
			vhost.host_input(vhost_id, 0, 0)
			vhost.tick_once()
	lag_meter.on_tick(cmd[2], Time.get_ticks_usec())


func _decay_offset(dt: float) -> void:
	render_offset *= exp(-dt * 12.0)
	if render_offset.length() < 0.05:
		render_offset = Vector2.ZERO


# ------------------------------------------------------------------ данные для отрисовки

func _pdict(id: int, st: PState, local: bool, off: Vector2) -> Dictionary:
	return {"id": id, "name": name_of(id), "color": color_of(id), "x": st.x / float(GC.SUB) + off.x, "y": st.y / float(GC.SUB) + off.y,
		"facing": st.facing, "vx": st.vx / float(GC.SUB), "vy": st.vy / float(GC.SUB), "flags": st.flag_byte(), "hp": st.hp,
		"buffs": st.buff_mask(), "alive": st.alive, "local": local, "state": st if local else null}


func _build_players() -> Array:
	var out := []
	if mode == "host" and host != null:
		var ids: Array = host.slots.keys()
		ids.sort()
		for id in ids:
			out.append(_pdict(id, host.slots[id].state, id == my_id, Vector2.ZERO))
	elif mode == "client" and client != null and my_id >= 0:
		var ids2: Array = client.roster.keys()
		ids2.sort()
		for id in ids2:
			if id == my_id:
				var pd := _pdict(id, client.state, true, render_offset)
				_own_shown = Vector2(pd["x"], pd["y"])
				out.append(pd)
			else:
				var v := client.view_of(id)
				if v.is_empty():
					continue
				var fl := int(v["flags"])
				out.append({"id": id, "name": name_of(id), "color": color_of(id), "x": v["x"], "y": v["y"], "facing": 1 if fl & 2 != 0 else -1,
					"vx": v["vx"], "vy": v["vy"], "flags": fl, "hp": v["hp"], "buffs": v["buffs"], "alive": fl & 1 != 0, "local": false, "state": null})
	return out


func world_players() -> Array:
	return _players_cache


func world_runes() -> Array:
	var out := []
	if host != null:
		for r in host.runes:
			out.append({"id": r["id"], "type": r["type"], "x": r["x"] / float(GC.SUB), "y": r["y"] / float(GC.SUB)})
	elif client != null:
		return client.runes
	return out


func local_state() -> PState:
	if host != null and host.slots.has(my_id):
		return host.slots[my_id].state
	if client != null:
		return client.state
	return null


func local_chaos() -> bool:
	var s := local_state()
	return s != null and s.buffs[GC.R_CHAOS] > 0


# ------------------------------------------------------------------ интерфейс и net_graph

## Строка net_graph про шифрование (ПР №6): состояние сессии и счётчики отброшенных пакетов.
func _enc_row(s: Dictionary) -> Array:
	if bool(s.get("enc", false)):
		var bad := int(s.get("auth_fail", 0)) + int(s.get("replay_drops", 0))
		return ["Шифрование", "AES-256-GCM, отброшено: подделок %d / повторов %d" % [s.get("auth_fail", 0), s.get("replay_drops", 0)], _sev(bad, 1, 10)]
	if bool(s.get("enc_pending", false)):
		return ["Шифрование", "обмен ключами…", 1]
	return ["Шифрование", "выкл (открытый текст)", 0]


func _update_ui(now_ms: int) -> void:
	if screen not in ["game", "pause", "result"]:
		return
	var st := local_state()
	var phase := host.phase if host != null else (client.phase if client != null else GC.PHASE_LOBBY)
	var ping := "Хост (локальный игрок)"
	if client != null:
		var s := client.net.stats(client.peer)
		ping = "Пинг: %d мс" % int(s.get("rtt_last", 0.0)) if not s.is_empty() else "Пинг: —"
	elif host != null and not host.net.peers.is_empty():
		var worst := 0.0
		for pid in host.net.peers.keys():
			worst = maxf(worst, host.net.stats(pid).get("rtt_last", 0.0))
		ping = "Хост · пинг клиентов до %d мс" % int(worst)
	var timer := ""
	if round_started_ms > 0 and phase == GC.PHASE_PLAYING:
		var secs := (now_ms - round_started_ms) / 1000
		timer = "%d:%02d" % [secs / 60, secs % 60]
	var banner := ""
	if st != null and not st.alive and phase == GC.PHASE_PLAYING:
		banner = "Вы выбыли — наблюдаем до конца раунда"
	ui.update_hud(ping, float(st.hp) if st != null else 0.0, show_hp, st, timer, banner)


static func _sev(v: float, warn: float, bad: float) -> int:
	return 2 if v >= bad else (1 if v >= warn else 0)


func _push_hist(key: String, v: float) -> void:
	var arr: Array = _hist[key]
	arr.append(v)
	if arr.size() > 100:
		arr.pop_front()


func _graph(title: String, key: String, now: String, vmax: float, warn: float, bad: float) -> Dictionary:
	return {"title": title, "values": _hist[key], "now": now, "max": vmax, "warn": warn, "bad": bad, "window": 100}


func _net_report() -> Dictionary:
	if mode == "":
		return {}
	var rows: Array = []
	var lag := lag_meter.stats()
	var emu: String = GameUI.NET_PRESETS[preset]
	if mode == "client" and client != null:
		var s := client.net.stats(client.peer)
		if s.is_empty():
			return {}
		var rates := client.rates()
		var snap_age := (float(client.now_us() - client.snap_recv_us) / 1000.0) if client.snap_tick_unwrapped >= 0 else 0.0
		var unacked := client.cmd_seq - client.last_ack
		_push_hist("rtt", s["rtt_last"])
		_push_hist("loss", maxf(s["ping_loss_pct"], s["rx_loss_pct"]))
		_push_hist("corr", client.last_error_px if rates["corrections_s"] > 0 else 0.0)
		_push_hist("snap", client.snap_interval_ms)
		rows = [
			["#", "Соединение"],
			["Режим / мой id", "клиент / %d" % my_id, 0],
			_enc_row(s),
			["Тик сервера (оценка)", "%d" % int(client.server_tick_estimate()), 0],
			["#", "Задержка (RTT)"],
			["Сейчас", "%.1f мс" % s["rtt_last"], _sev(s["rtt_last"], 80, 150)],
			["Сглаженная / RTO", "%.1f / %.0f мс" % [s["srtt"], s["rto"]], _sev(s["srtt"], 80, 150)],
			["Мин / сред / макс (10 с)", "%.0f / %.0f / %.0f мс" % [s["rtt_min"], s["rtt_avg"], s["rtt_max"]], _sev(s["rtt_max"], 120, 250)],
			["Джиттер", "%.1f мс" % s["jitter"], _sev(s["jitter"], 8, 20)],
			["#", "Потери"],
			["Пинги без ответа", "%.1f %%" % s["ping_loss_pct"], _sev(s["ping_loss_pct"], 2, 8)],
			["Входящие (по разрывам seq)", "%.1f %%" % s["rx_loss_pct"], _sev(s["rx_loss_pct"], 2, 8)],
			["#", "Трафик"],
			["Пакеты вх / исх в с", "%d / %d" % [s["pkts_in_s"], s["pkts_out_s"]], 0],
			["Скорость вх / исх", "%.1f / %.1f КБ/с" % [s["bytes_in_s"] / 1024.0, s["bytes_out_s"] / 1024.0], 0],
			["#", "Надёжные пакеты (ACK)"],
			["В очереди / повторов / провалов", "%d / %d / %d" % [s["reliable_pending"], s["retransmits"], s["reliable_failed"]], _sev(s["reliable_pending"], 3, 8)],
			["Среднее время до ACK", "%.1f мс" % s["ack_avg_ms"], _sev(s["ack_avg_ms"], 120, 250)],
			["Дубликатов отброшено", "%d" % s["dup_dropped"], 0],
			["#", "Снимки сервера"],
			["Частота (ожид. 60)", "%d Гц" % rates["snapshots_s"], _sev(60 - rates["snapshots_s"], 6, 20)],
			["Интервал ± джиттер", "%.1f ± %.1f мс" % [client.snap_interval_ms, client.snap_jitter_ms], _sev(client.snap_jitter_ms, 5, 12)],
			["Возраст последнего", "%.0f мс" % snap_age, _sev(snap_age, 60, 120)],
			["Пропусков снимков", "%d" % client.snap_gaps, 0],
			["Задержка интерполяции", "%.0f мс" % (client.remote.delay_ticks * 1000.0 / GC.TICK_HZ), 0],
			["Экстраполяций (нехватка данных)", "%d" % client.remote.underruns, _sev(client.remote.underruns, 5, 30)],
			["#", "Предсказание и сверка"],
			["Неподтверждённых команд", "%d (%.0f мс)" % [unacked, unacked * 1000.0 / GC.TICK_HZ], _sev(unacked, 30, 60)],
			["Коррекций в с / всего", "%d / %d" % [rates["corrections_s"], client.corrections], _sev(rates["corrections_s"], 1, 4)],
			["Ошибка: последняя / макс", "%.1f / %.1f px" % [client.last_error_px, client.max_error_px], _sev(client.last_error_px, 4, 30)],
			["Рывков отклонено локально", "%d" % client.local_dash_rejects, 0],
			["Предсказание рывка (F4)", "ВКЛ" if client.predict_dash else "ВЫКЛ — ждём сервер", 0],
			["Рывок: на экране (последний/сред)", _ms_pair(client.local_response_ms), 0],
			["Рывок: подтверждение сервера", _ms_pair(client.confirm_response_ms), 0],
			["Рывков принято / отклонено сервером", "%d / %d" % [client.dash_accepted, client.dash_denied], 0],
			["#", "Ввод и кадр (программная часть)"],
			["Нажатие → тик (сред/макс)", "%.1f / %.1f мс" % [lag["tick_avg"], lag["tick_max"]], _sev(lag["tick_avg"], 8, 17)],
			["Нажатие → кадр (сред/макс)", "%.1f / %.1f мс" % [lag["draw_avg"], lag["draw_max"]], _sev(lag["draw_avg"], 20, 40)],
			["FPS / кадр / тиков за кадр", "%d / %.1f мс / %d" % [int(fps_smooth), frame_ms, ticks_last_frame], _sev(60 - fps_smooth, 5, 20)],
			["Эмуляция сети", emu, 1 if preset != 0 else 0],
		]
		return {"title": "NET GRAPH · клиент", "rows": rows, "graphs": [
			_graph("RTT, мс", "rtt", "%.0f" % s["rtt_last"], 300.0, 100.0, 200.0),
			_graph("Потери, %", "loss", "%.1f" % maxf(s["ping_loss_pct"], s["rx_loss_pct"]), 20.0, 2.0, 8.0),
			_graph("Ошибка коррекции, px", "corr", "%.1f" % client.last_error_px, 100.0, 4.0, 30.0),
			_graph("Интервал снимков, мс", "snap", "%.1f" % client.snap_interval_ms, 60.0, 25.0, 40.0),
		]}
	if mode == "host" and host != null:
		var worst_rtt := 0.0
		var worst_loss := 0.0
		rows.append(["#", "Хост (Listen Server)"])
		rows.append(["Тик / фаза / игроков", "%d / %d / %d" % [host.tick, host.phase, host.slots.size()], 0])
		rows.append(["Рун на земле", "%d" % host.runes.size(), 0])
		var ids: Array = host.slots.keys()
		ids.sort()
		for id in ids:
			var sl: GameHost.Slot = host.slots[id]
			if sl.peer < 0:
				continue
			var s2 := host.net.stats(sl.peer)
			if s2.is_empty():
				continue
			worst_rtt = maxf(worst_rtt, s2["rtt_last"])
			worst_loss = maxf(worst_loss, maxf(s2["ping_loss_pct"], s2["rx_loss_pct"]))
			rows.append(["#", "Клиент %s (id %d)" % [name_of(id), id]])
			rows.append(_enc_row(s2))
			rows.append(["RTT / сглаж. / джиттер", "%.0f / %.0f / %.1f мс" % [s2["rtt_last"], s2["srtt"], s2["jitter"]], _sev(s2["rtt_last"], 80, 150)])
			rows.append(["Потери пинг / входящие", "%.1f / %.1f %%" % [s2["ping_loss_pct"], s2["rx_loss_pct"]], _sev(maxf(s2["ping_loss_pct"], s2["rx_loss_pct"]), 2, 8)])
			rows.append(["Пакеты вх / исх, КБ/с", "%d / %d, %.1f / %.1f" % [s2["pkts_in_s"], s2["pkts_out_s"], s2["bytes_in_s"] / 1024.0, s2["bytes_out_s"] / 1024.0], 0])
			rows.append(["Reliable: очер./повт./провалы", "%d / %d / %d" % [s2["reliable_pending"], s2["retransmits"], s2["reliable_failed"]], _sev(s2["reliable_pending"], 3, 8)])
			rows.append(["Команды: дыры / повторы", "%d / %d" % [sl.gap_fills, sl.dups], _sev(sl.gap_fills, 10, 60)])
			rows.append(["Отброшено: поздн./плох./рывки", "%d / %d / %d" % [sl.late, sl.bad_inputs, sl.dash_rejects], 0])
		_push_hist("rtt", worst_rtt)
		_push_hist("loss", worst_loss)
		_push_hist("corr", 0.0)
		_push_hist("snap", 1000.0 / 60.0)
		rows.append(["#", "Ввод и кадр (хост)"])
		rows.append(["Нажатие → тик (сред/макс)", "%.1f / %.1f мс" % [lag["tick_avg"], lag["tick_max"]], _sev(lag["tick_avg"], 8, 17)])
		rows.append(["Нажатие → кадр (сред/макс)", "%.1f / %.1f мс" % [lag["draw_avg"], lag["draw_max"]], _sev(lag["draw_avg"], 20, 40)])
		rows.append(["FPS / кадр / тиков за кадр", "%d / %.1f мс / %d" % [int(fps_smooth), frame_ms, ticks_last_frame], _sev(60 - fps_smooth, 5, 20)])
		rows.append(["Эмуляция сети", emu, 1 if preset != 0 else 0])
		return {"title": "NET GRAPH · хост", "rows": rows, "graphs": [
			_graph("Худший RTT клиента, мс", "rtt", "%.0f" % worst_rtt, 300.0, 100.0, 200.0),
			_graph("Худшие потери, %", "loss", "%.1f" % worst_loss, 20.0, 2.0, 8.0),
		]}
	return {}


func _ms_pair(a: Array) -> String:
	if a.is_empty():
		return "—"
	var sum := 0.0
	for v in a:
		sum += float(v)
	return "%.0f / %.0f мс" % [float(a.back()), sum / float(a.size())]
