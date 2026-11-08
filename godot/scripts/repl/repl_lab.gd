class_name ReplLab
extends Node2D
## Лаборатория репликации (ПР №5) — режим игры «Меню → Репликация (ПР №5)»: Listen Server и 3 клиента в одном окне,
## живое переключение оптимизаций (панель настроек справа, их же можно переключать клавишами).
## Вы управляете клиентом 0 (A/D или стрелки, Пробел — выстрел), клиенты 1 и 2 ходят по сценарию.
## Рисуется ТО, ЧТО ЗНАЕТ клиент 0; серые контуры — акторы, которые есть на сервере, но клиенту не реплицируются.
##   1…7 — включить/выключить технику, B — «до» (baseline), O — «после» (все оптимизации), H — скрыть панель статистики,
##   M — мини-карта, G — серые контуры. Профиль «до/после» одной кнопкой: run_measure() (кнопка «Замер»).
## Эмуляция сети из настроек игры (apply_net_preset) действует на каналы лаборатории — можно смотреть репликацию при задержке и потерях.

signal cfg_changed
signal measure_done(result: Dictionary)

const VSCALE := 0.75
const GROUND_SCREEN := 525.0
const KEYS := [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7]
const MEASURE_LABELS := {"baseline": "«До» (baseline)", "optimized": "«После» (все семь)", "current": "Ваш набор сейчас",
	"relevancy": "Только Replication Graph", "dormancy": "Только Net Dormancy", "push": "Только Push-based",
	"quantize": "Только квантование", "freq": "Только частоты"}

var cfg: ReplCfg
var hub := LoopHub.new()
var world: ReplWorld
var server: ReplServer
var prof := ReplProfiler.new()
var clients: Array = []
var host_link: LoopLink
var _acc := 0.0
var _t := 0
var _kb_hist: Array = []
var _last_bytes := 0
var _kbs := 0.0
var _err := 0.0
var overlays := {"hud": true, "minimap": true, "ghosts": true}
var running := false
var net_preset := 0
var shot_path := ""
var measuring := false
var _key_down := {}
var _font: Font


func start(preset: String, n_clients: int = 3, net_preset_index: int = 0) -> void:
	n_clients = clampi(n_clients, 1, ReplServer.MAX_CLIENTS)
	cfg = ReplCfg.baseline() if preset == "baseline" else ReplCfg.optimized()
	_font = ThemeDB.fallback_font
	world = ReplWorld.new(7)
	world.build_level()
	host_link = LoopLink.new(hub, 1)
	var host_net := NetNode.new(host_link)
	prof.clients = n_clients
	prof.begin("live", 0)
	server = ReplServer.new(host_net, world, cfg, prof)
	for i in n_clients:
		var l := LoopLink.new(hub, 100 + i)
		var nn := NetNode.new(l)
		nn.add_peer(host_link.link_id)
		var c := ReplClient.new(nn, host_link.link_id)
		c.join()
		clients.append(c)
	apply_net_preset(net_preset_index)
	running = true
	if shot_path != "" and is_inside_tree():
		_take_shot()


## Профили сети игры: 0 — без эмуляции, 1 — 100 мс, 2 — 175±25 мс и 4% потерь (как у GameUI.NET_PRESETS).
func apply_net_preset(i: int) -> void:
	net_preset = i
	var lag: float = [0.0, 100.0, 175.0][clampi(i, 0, 2)]
	var jit: float = [0.0, 0.0, 25.0][clampi(i, 0, 2)]
	var loss: float = [0.0, 0.0, 0.04][clampi(i, 0, 2)]
	if host_link != null:
		host_link.set_emulation(lag, jit, loss)
	for c: ReplClient in clients:
		(c.net.link as Link).set_emulation(lag, jit, loss)


func _take_shot() -> void:
	for i in 360:
		_tick()
	await RenderingServer.frame_post_draw
	queue_redraw()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(shot_path)
	print("снимок сохранён: " + shot_path)
	get_tree().quit()


func _process(delta: float) -> void:
	if not running or shot_path != "" or measuring:
		queue_redraw()
		return
	_acc = minf(_acc + delta, 0.1)
	while _acc >= 1.0 / 60.0:
		_acc -= 1.0 / 60.0
		_tick()
	_handle_keys()
	queue_redraw()


# ------------------------------------------------------------------ управление настройками (из меню и клавиш)

func set_flag(key: String, on: bool) -> void:
	if key == "custom_relevance" and on and not cfg.relevancy:
		cfg.set_flag("relevancy", true)
	cfg.set_flag(key, on)
	if key == "relevancy" and not on:
		cfg.set_flag("custom_relevance", false)
	cfg.name = "custom"
	server.apply_cfg()
	cfg_changed.emit()


func apply_preset_name(preset: String) -> void:
	_apply_preset(ReplCfg.baseline() if preset == "baseline" else ReplCfg.optimized())


func set_overlay(key: String, on: bool) -> void:
	overlays[key] = on
	cfg_changed.emit()


## Профиль «до/после» одной кнопкой: тот же воспроизводимый сценарий, что и в docs/Replication_*.md, но короче (seconds с игры).
## Строки: «до», «после», ваш текущий набор и пять техник по отдельности. Результат — сигнал measure_done.
func run_measure(seconds: int = 10) -> void:
	if measuring:
		return
	measuring = true
	var items: Array = [["baseline", ReplCfg.baseline()], ["optimized", ReplCfg.optimized()], ["current", cfg.duplicate_cfg()]]
	for k in ["relevancy", "dormancy", "push", "quantize", "freq"]:
		items.append([k, ReplCfg.only([k], k)])
	var rows: Array = []
	var checksum := -1
	var same := true
	var base_kb := 0.0
	for it in items:
		if is_inside_tree():
			await get_tree().process_frame
		var c: ReplCfg = it[1]
		var r := ReplScenario.run(c, {"seconds": seconds, "clients": 3, "seed": 7})
		var st: Dictionary = r["steady"]
		if rows.is_empty():
			base_kb = st["kb_s_total"]
			checksum = int(r["checksum"])
		elif int(r["checksum"]) != checksum:
			same = false
		rows.append({"key": it[0], "label": MEASURE_LABELS[it[0]], "kb_s": st["kb_s_total"], "kb_s_client": st["kb_s_per_client"],
			"less_pct": (1.0 - float(st["kb_s_total"]) / base_kb) * 100.0, "known": st["known_avg"], "err": r["quality"]["err_avg_px"],
			"missing": r["quality"]["missing"], "active": c.active().size()})
	measuring = false
	measure_done.emit({"rows": rows, "same_checksum": same, "checksum": checksum, "seconds": seconds, "actors": world.count()})


func _handle_keys() -> void:
	for i in KEYS.size():
		_edge(KEYS[i], func() -> void: set_flag(ReplCfg.TECH_KEYS[i], not cfg.get_flag(ReplCfg.TECH_KEYS[i])))
	_edge(KEY_B, func() -> void: _apply_preset(ReplCfg.baseline()))
	_edge(KEY_O, func() -> void: _apply_preset(ReplCfg.optimized()))
	_edge(KEY_H, func() -> void: set_overlay("hud", not overlays["hud"]))
	_edge(KEY_M, func() -> void: set_overlay("minimap", not overlays["minimap"]))
	_edge(KEY_G, func() -> void: set_overlay("ghosts", not overlays["ghosts"]))


func _apply_preset(p: ReplCfg) -> void:
	for k in ReplCfg.TECH_KEYS:
		cfg.set_flag(k, p.get_flag(k))
	cfg.budget_bytes = p.budget_bytes
	cfg.name = p.name
	server.apply_cfg()
	cfg_changed.emit()


func _edge(key: Key, fn: Callable) -> void:
	var down := Input.is_key_pressed(key)
	if down and not _key_down.get(key, false):
		fn.call()
	_key_down[key] = down


func _tick() -> void:
	_t += 1
	hub.advance_us(ReplScenario.TICK_US)
	for i in clients.size():
		var c: ReplClient = clients[i]
		c.process()
		if c.client_id < 0:
			continue
		var inp: Array
		if i == 0 and shot_path == "" and not measuring:
			var ax := 0
			if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
				ax += 127
			if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
				ax -= 127
			inp = [ax, ReplWorld.BTN_SHOOT if Input.is_key_pressed(KEY_SPACE) else 0]
		else:
			inp = ReplScenario.script_input(i, _t)
		c.send_input(int(inp[0]), int(inp[1]))
	server.step()
	if _t % 60 == 0:
		var b := prof.cur.wire_bytes
		_kbs = float(b - _last_bytes) / 1024.0
		_last_bytes = b
		_kb_hist.append(_kbs)
		if _kb_hist.size() > 40:
			_kb_hist.pop_front()
	if _t % 6 == 0 and not clients.is_empty():
		_err = lerpf(_err, _visible_error(), 0.2)


func _visible_error() -> float:
	var c: ReplClient = clients[0]
	var me: ReplActor = world.actors.get(ReplWorld.PLAYER_BASE + maxi(c.client_id, 0))
	if me == null:
		return 0.0
	var sum := 0.0
	var n := 0
	for a: ReplActor in world.actors.values():
		if absf(a.x - me.x) > ReplDefs.VIEW_HALF_W:
			continue
		n += 1
		if c.actors.has(a.id):
			sum += c.pos_at(a.id, hub.now_us).distance_to(Vector2(a.x, a.y))
		else:
			sum += 200.0       # пропавший видимый актор — штраф
	return sum / float(maxi(n, 1))


# ------------------------------------------------------------------ рисование

func _sx(x: float, cam: float) -> float:
	return x - cam + 640.0


func _sy(y: float) -> float:
	return GROUND_SCREEN - (ReplDefs.GROUND_Y_PX - y) * VSCALE if y >= 300.0 else y * VSCALE + 20.0


func _draw() -> void:
	draw_rect(Rect2(0, 0, 1280, 720), Color("1b2438"))
	if clients.is_empty():
		return
	var c0: ReplClient = clients[0]
	var cam := 400.0
	var av := c0.avatar()
	if av != null:
		cam = c0.pos_at(av.id, hub.now_us).x
	draw_rect(Rect2(0, GROUND_SCREEN, 1280, 200), Color("2b3a2b"))
	draw_line(Vector2(0, GROUND_SCREEN), Vector2(1280, GROUND_SCREEN), Color("4c8f4c"), 3.0)
	# серые контуры: на сервере есть, клиенту не реплицируется (в пределах ±1500 px)
	for a: ReplActor in world.actors.values():
		if not overlays["ghosts"] or c0.actors.has(a.id) or absf(a.x - cam) > 1500.0 + 640.0:
			continue
		var p := Vector2(_sx(a.x, cam), _sy(a.y))
		draw_arc(p, 9.0, 0.0, TAU, 14, Color(0.7, 0.7, 0.75, 0.35), 1.0)
	for id in c0.actors.keys():
		var a2: ReplClient.CActor = c0.actors[id]
		var pos := c0.pos_at(id, hub.now_us)
		var p2 := Vector2(_sx(pos.x, cam), _sy(pos.y))
		_draw_actor(a2, p2)
	if overlays["minimap"]:
		_draw_minimap(cam)
	if overlays["hud"]:
		_draw_hud(c0)


func _draw_actor(a: ReplClient.CActor, p: Vector2) -> void:
	match a.cls:
		ReplDefs.C_TREE:
			draw_rect(Rect2(p.x - 4, p.y - 36, 8, 36), Color("6b4a2b"))
			draw_circle(p + Vector2(0, -44), 20.0 - (100 - a.hp) * 0.06, Color("2f8f4e"))
		ReplDefs.C_PICKUP:
			if a.st == 0:
				draw_circle(p, 8.0, Color("f5c518"))
				draw_arc(p, 11.0, 0.0, TAU, 16, Color("fff3b0"), 1.5)
		ReplDefs.C_BOT:
			draw_rect(Rect2(p.x - 11, p.y - 28, 22, 28), Color("e5484d") if (a.st & 4) == 0 else Color("ffd1d1"))
			draw_rect(Rect2(p.x - 11, p.y - 36, 22.0 * float(a.hp) / 50.0, 4), Color("ff9f1c"))
		ReplDefs.C_PROJ:
			draw_circle(p, 5.0, Color("ffe14d") if (a.st & 1) != 0 else Color("ff6b9a"))
		ReplDefs.C_CLOUD:
			for k in 3:
				draw_circle(p + Vector2(k * 16 - 16, -(k % 2) * 6), 14.0, Color(0.85, 0.9, 1.0, 0.55))
		ReplDefs.C_PLAYER:
			var col: Color = GC.COLORS[(a.id - ReplWorld.PLAYER_BASE) % GC.COLORS.size()]
			draw_rect(Rect2(p.x - 12, p.y - 34, 24, 34), col)
			draw_rect(Rect2(p.x + (4 if (a.st & 1) != 0 else -10), p.y - 28, 6, 6), Color.WHITE)
			draw_string(_font, Vector2(p.x - 10, p.y - 40), "К%d" % (a.id - ReplWorld.PLAYER_BASE), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)


func _draw_minimap(cam: float) -> void:
	var c0: ReplClient = clients[0]
	var x0 := 40.0
	var w := 1200.0
	var y0 := 650.0
	var k := w / ReplDefs.WORLD_W_PX
	draw_rect(Rect2(x0 - 4, y0 - 24, w + 8, 52), Color(0, 0, 0, 0.45))
	for a: ReplActor in world.actors.values():
		var known := c0.actors.has(a.id)
		var col: Color = [Color("e5484d"), Color("2f8f4e"), Color("f5c518"), Color("ff6b3d"), Color("ffe14d"), Color("cfd8ff")][a.cls]
		if a.cls == ReplDefs.C_PLAYER:
			col = GC.COLORS[(a.id - ReplWorld.PLAYER_BASE) % GC.COLORS.size()]
		if not known:
			col = Color(col.r * 0.35, col.g * 0.35, col.b * 0.35, 0.9)
		var yy := y0 - 6.0 + (a.y / 1000.0) * 22.0
		draw_rect(Rect2(x0 + a.x * k - 2.0, yy - 2.0, 4, 4), col)
	draw_rect(Rect2(x0 + (cam - 640.0) * k, y0 - 22, 1280.0 * k, 48), Color(1, 1, 1, 0.9), false, 1.5)
	draw_string(_font, Vector2(x0, y0 + 40), "весь уровень 16000 px · яркие точки — реплицируются клиенту 0, тёмные — нет · рамка — камера", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.7))


func _draw_hud(c0: ReplClient) -> void:
	draw_rect(Rect2(10, 10, 470, 292), Color(0, 0, 0, 0.62))
	var y := 32.0
	draw_string(_font, Vector2(20, y), "Лаборатория репликации · %s" % ("«до»: наивная" if cfg.active().is_empty() else "оптимизации: %d из 7" % cfg.active().size()), HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color.WHITE)
	y += 24.0
	for i in ReplCfg.TECH_KEYS.size():
		var k: String = ReplCfg.TECH_KEYS[i]
		var on := cfg.get_flag(k)
		var col := Color("7be08d") if on else Color(1, 1, 1, 0.6)
		draw_string(_font, Vector2(20, y), "[%d] %s" % [i + 1, ReplCfg.TECH_NAMES[k]], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
		draw_string(_font, Vector2(420, y), "ВКЛ" if on else "—", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
		y += 19.0
	y += 6.0
	var n := clients.size()
	draw_string(_font, Vector2(20, y), "исходящий трафик: %.1f КБ/с всего · %.1f КБ/с на клиента" % [_kbs, _kbs / float(n)], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("ffd479"))
	y += 20.0
	draw_string(_font, Vector2(20, y), "клиенту 0 реплицируется %d из %d акторов · ошибка вида %.1f px" % [c0.actors.size(), world.count(), _err], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
	y += 18.0
	draw_string(_font, Vector2(20, y), "B «до» · O «после» · H панель · M карта · G контуры · A/D идти · Пробел выстрел", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.65))
	# график КБ/с за 40 с
	var gx := 20.0
	var gy := y + 12.0
	var gw := 440.0
	var gh := 34.0
	draw_rect(Rect2(gx, gy, gw, gh), Color(1, 1, 1, 0.08))
	var mx := 20.0
	for v in _kb_hist:
		mx = maxf(mx, float(v))
	for i in _kb_hist.size():
		var hgt := gh * float(_kb_hist[i]) / mx
		draw_rect(Rect2(gx + float(i) * (gw / 40.0), gy + gh - hgt, gw / 40.0 - 1.0, hgt), Color("ffd479"))
