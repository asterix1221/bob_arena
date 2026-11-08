class_name Scenario
extends Node
## Автоматические сценарии ПР №4 (T1–T5) по реальному UDP, два процесса: хост (Listen Server) и клиент, которым управляет
## ScenarioBrain вместо клавиатуры. Клиент рисует обычную игру (с визуализацией предсказания), поэтому тот же прогон
## можно записать на видео; без окна (--headless) он даёт только лог. Параметры (после --):
##   --scenario=T1..T5 --role=host|client [--port=P] [--join=ip] [--out=файл.log] [--quit-after=секунд]
##   --scenario=T1..T5 --role=sim   виртуальное время, один процесс (для записи видео/скриншотов: не зависит от скорости рендеринга)
##   --shots-dir=<каталог>          серия скриншотов вокруг рывка (нужно окно)
##   --viz=0..3  режим визуализации клиента (по умолчанию — как в игре)
## Эмуляция сети и режим предсказания задаются сценарием (см. CASES); профили: 0 нет, 1 — 100 мс, 2 — 175±25 мс и 4% потерь
## (задержка в ОДНУ сторону на исходящем трафике каждой стороны, поэтому RTT ≈ 2×lag).

const CASES := {
	"T1": {"preset": 0, "predict": true, "brain": "walk", "title": "без эмуляции, движение и рывки", "shot_dash": 1},
	"T2": {"preset": 1, "predict": false, "brain": "dash_latency", "title": "100 мс, рывок БЕЗ предсказания", "shot_dash": 2},
	"T3": {"preset": 1, "predict": true, "brain": "dash_latency", "title": "100 мс, рывок С предсказанием", "shot_dash": 2},
	"T4": {"preset": 2, "predict": true, "brain": "loss_mix", "title": "175±25 мс, 4% потерь, движение и рывки", "shot_dash": 2},
	"T5": {"preset": 2, "predict": true, "brain": "cheat", "title": "175±25 мс, 4% потерь, чит клиента (расхождение)", "shot_dash": 3},
}
const LAG := [[0, 0, 0.0], [100, 0, 0.0], [175, 25, 4.0]]

var app: App
var case_id := "T3"
var cfg := {}
var out: FileAccess = null
var t0_ms := 0
var _last_seq := -1
var _last_snap := -1
var _role := "client"
var shots_dir := ""
var _dash_no := 0
var _resolved_no := 0
var _host_stats := {}            # последняя статистика слота удалённого игрока (слот исчезает при его выходе)


func _log(line: String) -> void:
	print(line)
	if out != null and out.is_open():
		out.store_line(line)
		out.flush()


func _t() -> int:
	if app != null and app.vhub != null:
		return int(app.vhub.now_us / 1000)          # виртуальное время сеанса
	return Time.get_ticks_msec() - t0_ms


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _wait_until(cond: Callable, timeout_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func run(id: String) -> void:
	t0_ms = Time.get_ticks_msec()
	case_id = id
	if not CASES.has(id):
		print("[SCN] unknown scenario %s (T1..T5)" % id)
		get_tree().quit(2)
		return
	cfg = CASES[id]
	if app._args.has("out"):
		out = FileAccess.open(String(app._args["out"]), FileAccess.WRITE)
	var role := String(app._args.get("role", "client"))
	_role = role
	if app._args.has("shots-dir"):
		shots_dir = String(app._args["shots-dir"])
		DirAccess.make_dir_recursive_absolute(shots_dir)
	var l: Array = LAG[int(cfg["preset"])]
	_log("[SCN] %s (%s) role=%s preset=%d predict_dash=%d lag=%d jitter=%d loss=%.1f" % [id, cfg["title"], role, int(cfg["preset"]), 1 if cfg["predict"] else 0, l[0], l[1], l[2]])
	app.set_net_preset(int(cfg["preset"]))
	app.ui.preset_opt.select(int(cfg["preset"]))
	if app._args.has("quit-after"):
		get_tree().create_timer(float(app._args["quit-after"])).timeout.connect(func() -> void: _finish(3, "timeout"))
	if role == "host":
		await _run_host()
	elif role == "sim":
		await _run_sim()
	else:
		await _run_client()


# ------------------------------------------------------------------ хост (Listen Server)

func _run_host() -> void:
	var port := int(app._args.get("port", App.DEFAULT_PORT))
	app.start_host("Хост", 0, port, false)
	if app.host == null:
		_finish(2, "cannot listen")
		return
	app.host.dash_rejected.connect(func(pid: int, reason: String) -> void: _log("[DASH] SERVER REJECTED t=%d player=%d reason=%s" % [_t(), pid, reason]))
	_log("[NET] LISTEN SERVER started on port %d (host plays as player %d)" % [port, app.my_id])
	if not await _wait_until(func() -> bool: return app.host.slots.size() >= 2, 60.0):
		_finish(3, "no client")
		return
	_log("[NET] client joined t=%d" % _t())
	await _wait(0.6)
	app._on_start_pressed()
	await _wait_until(func() -> bool: return app.host.phase == GC.PHASE_PLAYING, 15.0)
	_log("[MATCH] playing t=%d" % _t())
	await _wait_until(func() -> bool: return app.host.slots.size() < 2, 120.0)
	_log("[RESULT] role=host case=%s remote_player_stats=%s tick=%d" % [case_id, str(_host_stats), app.host.tick])
	_finish(0, "done")


# ------------------------------------------------------------------ клиент (управляется скриптом)

func _run_client() -> void:
	app.predict_dash = bool(cfg["predict"])
	var ip := String(app._args.get("join", "127.0.0.1"))
	var port := int(app._args.get("port", App.DEFAULT_PORT))
	app.start_join("Клиент", 1, ip, port)
	if app.client == null:
		_finish(2, "cannot connect")
		return
	var c: GameClient = app.client
	var brain := ScenarioBrain.new(String(cfg["brain"]))
	app.autoplay = brain
	_hook_client(c)
	_log("[NET] CLIENT connecting to %s:%d" % [ip, port])
	if not await _wait_until(func() -> bool: return c.my_id >= 0, 15.0):
		_finish(3, "no welcome")
		return
	_log("[NET] welcome id=%d t=%d" % [c.my_id, _t()])
	if not await _wait_until(func() -> bool: return c.phase == GC.PHASE_PLAYING, 60.0):
		_finish(3, "match did not start")
		return
	_log("[MATCH] playing t=%d" % _t())
	set_process(true)
	await _wait_until(func() -> bool: return brain.done, 60.0)
	_log("[SCN] script finished t=%d, waiting for last snapshots" % _t())
	await _wait(2.5)
	_report(c)
	app.leave_to_menu()
	await _wait(0.3)
	_finish(0, "done")


## Серия скриншотов вокруг одного рывка (номер задан в CASES[..].shot_dash): сразу после нажатия, через 120 мс, в момент ответа
## сервера и через 250 мс после него. Работает только с окном (не --headless) и с --shots-dir=<каталог>.
func _on_dash_pressed(_seq: int) -> void:
	_dash_no += 1
	if shots_dir != "" and _dash_no == int(cfg.get("shot_dash", 2)):
		_shot_series(_dash_no)


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/%s_%s.png" % [shots_dir, case_id, label])
	_log("[SHOT] %s_%s t=%d" % [case_id, label, _t()])


func _shot_series(n: int) -> void:
	await _shot("1_press")
	await _wait(0.12)
	await _shot("2_waiting")
	await _wait_until(func() -> bool: return _resolved_no >= n, 2.0)
	await _shot("3_server_response")
	await _wait(0.25)
	await _shot("4_after")


## Виртуальный сеанс: кадр = несколько тиков виртуального времени, поэтому ожидания считаем в кадрах.
func _wait_frames_until(cond: Callable, max_frames: int) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _run_sim() -> void:
	app.predict_dash = bool(cfg["predict"])
	app.start_virtual(int(cfg["preset"]))
	var c: GameClient = app.client
	var brain := ScenarioBrain.new(String(cfg["brain"]))
	app.autoplay = brain
	_hook_client(c)
	_log("[NET] VIRTUAL session (LoopHub, virtual time), client connecting")
	if not await _wait_frames_until(func() -> bool: return c.my_id >= 0 and app.vhost.slots.size() >= 2, 600):
		_finish(3, "no welcome")
		return
	await _wait_frames_until(func() -> bool: return false, 20)
	app.vhost.start_match()
	if not await _wait_frames_until(func() -> bool: return c.phase == GC.PHASE_PLAYING, 1200):
		_finish(3, "match did not start")
		return
	_log("[MATCH] playing t=%d" % _t())
	set_process(true)
	await _wait_frames_until(func() -> bool: return brain.done, 20000)
	_log("[SCN] script finished t=%d" % _t())
	await _wait_frames_until(func() -> bool: return false, 90)       # досылка последних снимков (≈3 с при 30 к/с)
	_report_sim(c)
	_finish(0, "done")


func _report_sim(c: GameClient) -> void:
	var l: Array = LAG[int(cfg["preset"])]
	_log("[RESULT] role=sim case=%s predict_dash=%d preset=%d lag=%d jitter=%d loss=%.1f" % [case_id, 1 if c.predict_dash else 0, int(cfg["preset"]), l[0], l[1], l[2]])
	_log("[RESULT] corrections=%d max_error_px=%.2f dash_accepted=%d dash_denied=%d" % [c.corrections, c.max_error_px, c.dash_accepted, c.dash_denied])
	_log("[RESULT] local_response_ms=%s" % str(_round(c.local_response_ms)))
	_log("[RESULT] confirm_response_ms=%s" % str(_round(c.confirm_response_ms)))


func _hook_client(c: GameClient) -> void:
	c.dash_pressed.connect(_on_dash_pressed)
	c.correction.connect(func(err: float, replayed: int) -> void: _log("[CORRECTION] t=%d err_px=%.2f replayed=%d" % [_t(), err, replayed]))
	c.dash_resolved.connect(func(ok: bool, local_ms: float, confirm_ms: float, _h: String) -> void:
		_resolved_no += 1
		_log("[DASH] %s t=%d on_screen_ms=%.1f confirmed_ms=%.1f" % ["ACCEPTED" if ok else "REJECTED_BY_SERVER", _t(), maxf(local_ms, 0.0), confirm_ms]))


func _process(_dt: float) -> void:
	if _role == "host":
		if app != null and app.host != null:
			for sid in app.host.slots.keys():
				var sl: GameHost.Slot = app.host.slots[sid]
				if sl.peer != -1:
					_host_stats = {"dash_rejects": sl.dash_rejects, "gap_fills": sl.gap_fills, "dups": sl.dups, "late": sl.late, "bad_inputs": sl.bad_inputs}
		return
	var c: GameClient = app.client if app != null else null
	if c == null or c.phase != GC.PHASE_PLAYING:
		return
	if c.cmd_seq != _last_seq:                 # раз в тик: положение предсказанного персонажа
		_last_seq = c.cmd_seq
		_log("POS,%d,%d,%.2f,%.2f,%d" % [_t(), c.cmd_seq, float(c.state.x) / GC.SUB, float(c.state.y) / GC.SUB, c.state.dash_left])
	if c.snapshots_in != _last_snap and c.last_server_state != null:   # раз в снимок: авторитетное vs предсказанное
		_last_snap = c.snapshots_in
		var s := c.last_server_state
		_log("TRACE,%d,%d,%.2f,%.2f,%.2f,%.2f,%d" % [_t(), c.last_ack, float(s.x) / GC.SUB, float(s.y) / GC.SUB, float(c.state.x) / GC.SUB, float(c.state.y) / GC.SUB, c.corrections])


func _report(c: GameClient) -> void:
	var l: Array = LAG[int(cfg["preset"])]
	_log("[RESULT] role=client case=%s predict_dash=%d preset=%d lag=%d jitter=%d loss=%.1f" % [case_id, 1 if c.predict_dash else 0, int(cfg["preset"]), l[0], l[1], l[2]])
	_log("[RESULT] corrections=%d max_error_px=%.2f last_error_px=%.2f snapshots_in=%d dash_accepted=%d dash_denied=%d" % [c.corrections, c.max_error_px, c.last_error_px, c.snapshots_in, c.dash_accepted, c.dash_denied])
	_log("[RESULT] local_response_ms=%s" % str(_round(c.local_response_ms)))
	_log("[RESULT] confirm_response_ms=%s" % str(_round(c.confirm_response_ms)))
	_log("[RESULT] net_sent=%d net_dropped=%d final_pred_vs_server_px=%.3f" % [app.link.sent_packets, app.link.dropped_by_emu, c.prediction_lead_px()])
	_log("[RESULT] client_fps=%.0f snapshot_gaps=%d" % [app.fps_smooth, c.snap_gaps])


func _round(a: Array) -> Array:
	var r: Array = []
	for v in a:
		r.append(snappedf(float(v), 0.1))
	return r


func _finish(code: int, why: String) -> void:
	_log("[SCN] exit %s (%d)" % [why, code])
	if out != null and out.is_open():
		out.close()
	get_tree().quit(code)
