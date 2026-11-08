class_name GameUI
extends CanvasLayer
## Все экраны из кода (без редактора): меню, лобби, HUD, отсчёт, победа/поражение, обрыв связи, пауза.
## Логики игры здесь нет: кнопки лишь испускают сигналы для App.

signal host_requested(player_name: String, color: int, port: int)
signal join_requested(player_name: String, color: int, ip: String, port: int)
signal bot_requested(player_name: String, color: int)
signal start_requested
signal leave_requested
signal rematch_requested
signal resume_requested
signal quit_requested
signal net_preset_changed(index: int)
signal vsync_changed(index: int)
signal predict_changed(on: bool)
signal viz_changed(index: int)
signal models_changed(sprites: bool)
signal repl_open_requested(preset: String)      # ПР №5: открыть лабораторию репликации (preset: "baseline" | "optimized")
signal repl_flag_changed(key: String, on: bool) # включить/выключить технику репликации
signal repl_preset_changed(preset: String)
signal repl_overlay_changed(key: String, on: bool)
signal repl_measure_requested

const NET_PRESETS := ["Без эмуляции", "100 мс, без потерь", "175±25 мс, 4% потерь"]
const VSYNC_MODES := ["Выкл (меньше задержка)", "Вкл", "Адаптивная", "Mailbox (меньше задержка, без разрывов)"]

var menu: Control
var lobby: Control
var hud: Control
var result: Control
var disconnected: Control
var lab: Control                    # ПР №5: экран лаборатории репликации (панель настроек справа)
var pause: Control
var countdown_label: Label
var net_graph: NetGraph

var name_edit: LineEdit
var ip_edit: LineEdit
var port_edit: LineEdit
var selected_color := 0
var preset_opt: OptionButton
var _predict_opts: Array[OptionButton] = []    # одинаковые настройки в меню и в паузе
var _viz_opts: Array[OptionButton] = []
var _models_opts: Array[OptionButton] = []     # «Модели персонажей»: спрайты / фигуры
var _swatches: Array[Button] = []
var _repl_checks := {}                          # ключ техники/оверлея -> CheckButton (копии не нужны: панель одна)
var _repl_start_opt: OptionButton               # в меню: с чего стартует лаборатория
var _repl_preset_opt: OptionButton              # в лаборатории: «до» / «после» / свой набор
var _repl_status: Label
var lab_net_opt: OptionButton
var repl_measure_btn: Button
var repl_result: Control
var repl_result_grid: GridContainer
var repl_result_note: Label
var menu_msg: Label
var lobby_list: VBoxContainer
var lobby_info: Label
var lobby_start: Button
var hud_ping: Label
var hud_hp: Control
var hud_runes: VBoxContainer
var hud_feed: VBoxContainer
var hud_banner: Label
var hud_timer: Label
var result_title: Label
var result_sub: Label
var result_stats: VBoxContainer
var result_rematch: Button
var result_wait: Label
var disc_msg: Label
var _hp_value := 100.0
var _hp_on := true


func _ready() -> void:
	layer = 10
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_build_hud(root)
	net_graph = NetGraph.new()
	net_graph.set_anchors_preset(Control.PRESET_FULL_RECT)
	net_graph.visible = false
	root.add_child(net_graph)
	_build_menu(root)
	_build_lobby(root)
	_build_result(root)
	_build_disconnected(root)
	_build_pause(root)
	_build_lab(root)
	root.move_child(net_graph, -1)      # net_graph поверх всех экранов
	show_only("menu")


# ------------------------------------------------------------------ помощники оформления

static func _panel(bg: Color = Color("1a2036ee")) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(12)
	s.set_border_width_all(1)
	s.border_color = Color(1, 1, 1, 0.14)
	s.set_content_margin_all(18)
	return s


static func _btn_style(c: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(8)
	s.set_content_margin_all(10)
	return s


func _button(text: String, color: Color = Color("3b4a7a")) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", _btn_style(color))
	b.add_theme_stylebox_override("hover", _btn_style(color.lightened(0.15)))
	b.add_theme_stylebox_override("pressed", _btn_style(color.darkened(0.15)))
	b.add_theme_stylebox_override("disabled", _btn_style(Color("2a2f40")))
	b.add_theme_font_size_override("font_size", 18)
	return b


func _label(text: String, size: int = 16, color: Color = Color(0.9, 0.92, 0.97)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _centered_panel(parent: Control, width: float) -> VBoxContainer:
	var holder := CenterContainer.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	parent.add_child(holder)
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(width, 0)
	pc.add_theme_stylebox_override("panel", _panel())
	holder.add_child(pc)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	pc.add_child(vb)
	return vb


func _screen(parent: Control, dim: float = 0.0) -> Control:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	if dim > 0.0:
		var cr := ColorRect.new()
		cr.color = Color(0.03, 0.04, 0.08, dim)
		cr.set_anchors_preset(Control.PRESET_FULL_RECT)
		c.add_child(cr)
	parent.add_child(c)
	return c


# ------------------------------------------------------------------ меню

func _build_menu(root: Control) -> void:
	menu = _screen(root, 0.78)
	var vb := _centered_panel(menu, 560)
	vb.add_theme_constant_override("separation", 6)       # меню стало выше (строка ПР №5) — иначе кнопка «Выход» уходит за экран
	var title := _label("BOB ARENA", 46, Color("ffd24a"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var sub := _label("платформер-файтинг на собственном UDP-протоколе", 14, Color(0.7, 0.75, 0.85))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)
	vb.add_child(_label("Имя игрока"))
	name_edit = LineEdit.new()
	name_edit.text = "Игрок"
	name_edit.max_length = 12
	vb.add_child(name_edit)
	vb.add_child(_label("Цвет"))
	var colors := HBoxContainer.new()
	colors.add_theme_constant_override("separation", 10)
	for i in GC.COLORS.size():
		var b := Button.new()
		b.custom_minimum_size = Vector2(56, 34)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func() -> void: _select_color(i))
		colors.add_child(b)
		_swatches.append(b)
	vb.add_child(colors)
	_select_color(0)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var host_btn := _button("Создать игру (хост)", Color("2f7d4f"))
	host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_btn.pressed.connect(func() -> void: host_requested.emit(name_edit.text, selected_color, int(port_edit.text)))
	row.add_child(host_btn)
	var bot_btn := _button("Тренировка с ботом", Color("7a5a2f"))
	bot_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bot_btn.pressed.connect(func() -> void: bot_requested.emit(name_edit.text, selected_color))
	row.add_child(bot_btn)
	vb.add_child(row)
	var jrow := HBoxContainer.new()
	jrow.add_theme_constant_override("separation", 8)
	ip_edit = LineEdit.new()
	ip_edit.text = "127.0.0.1"
	ip_edit.placeholder_text = "IP хоста"
	ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jrow.add_child(ip_edit)
	port_edit = LineEdit.new()
	port_edit.text = "24680"
	port_edit.custom_minimum_size = Vector2(90, 0)
	jrow.add_child(port_edit)
	var join_btn := _button("Подключиться", Color("3b5ea8"))
	join_btn.pressed.connect(func() -> void: join_requested.emit(name_edit.text, selected_color, ip_edit.text.strip_edges(), int(port_edit.text)))
	jrow.add_child(join_btn)
	vb.add_child(jrow)
	vb.add_child(HSeparator.new())
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 8)
	srow.add_child(_label("Сеть (эмуляция):", 14))
	var preset := OptionButton.new()
	preset_opt = preset
	for p in NET_PRESETS:
		preset.add_item(p)
	preset.focus_mode = Control.FOCUS_NONE
	preset.item_selected.connect(func(i: int) -> void: net_preset_changed.emit(i))
	srow.add_child(preset)
	srow.add_child(_label("VSync:", 14))
	var vs := OptionButton.new()
	for m in VSYNC_MODES:
		vs.add_item(m)
	vs.select(3)
	vs.focus_mode = Control.FOCUS_NONE
	vs.item_selected.connect(func(i: int) -> void: vsync_changed.emit(i))
	srow.add_child(vs)
	vb.add_child(srow)
	vb.add_child(_pred_settings_row(14))
	var rrow := HBoxContainer.new()
	rrow.add_theme_constant_override("separation", 8)
	rrow.add_child(_label("Репликация (ПР №5):", 14))
	_repl_start_opt = OptionButton.new()
	_repl_start_opt.add_item("старт «после» (все оптимизации)")
	_repl_start_opt.add_item("старт «до» (наивная)")
	_repl_start_opt.focus_mode = Control.FOCUS_NONE
	rrow.add_child(_repl_start_opt)
	var lab_btn := _button("Лаборатория репликации", Color("6a4aa8"))
	lab_btn.add_theme_font_size_override("font_size", 14)
	lab_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab_btn.pressed.connect(func() -> void: repl_open_requested.emit("optimized" if _repl_start_opt.selected == 0 else "baseline"))
	rrow.add_child(lab_btn)
	vb.add_child(rrow)
	menu_msg = _label("", 14, Color("ff8a80"))
	menu_msg.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(menu_msg)
	var help := _label("A/D или ←/→ — бег   W/Пробел — прыжок (S + прыжок — вниз)   Shift — рывок\nЛКМ — лёгкий удар, ПКМ — тяжёлый   H — здоровье   F3 — net_graph   Esc — пауза\nF4 — предсказание рывка   F8 — визуализация   F6 — спрайты/фигуры   «Лаборатория репликации» — настройки и замеры ПР №5", 13, Color(0.65, 0.7, 0.8))
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(help)
	var quit := _button("Выход", Color("5a2f3a"))
	quit.pressed.connect(func() -> void: quit_requested.emit())
	vb.add_child(quit)


## Две настройки ПР №4: предсказание рывка (вкл/выкл) и режим визуализации предсказания. Строка встраивается в меню и в паузу;
## значения синхронизируются между копиями (sync_pred_settings), логики здесь нет — только сигналы.
func _pred_settings_row(font_size: int) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 8)
	row1.add_child(_label("Предсказание рывка:", font_size))
	var po := OptionButton.new()
	po.add_item("Вкл (сразу)")
	po.add_item("Выкл (ждать сервер)")
	po.focus_mode = Control.FOCUS_NONE
	po.item_selected.connect(func(i: int) -> void: predict_changed.emit(i == 0))
	row1.add_child(po)
	box.add_child(row1)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	row2.add_child(_label("Визуализация предсказания:", font_size))
	var vo := OptionButton.new()
	for n in PredViz.NAMES:
		vo.add_item(n)
	vo.focus_mode = Control.FOCUS_NONE
	vo.item_selected.connect(func(i: int) -> void: viz_changed.emit(i))
	row2.add_child(vo)
	box.add_child(row2)
	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 8)
	row3.add_child(_label("Модели персонажей:", font_size))
	var mo := OptionButton.new()
	mo.add_item("Спрайты")
	mo.add_item("Фигуры (без картинок)")
	mo.focus_mode = Control.FOCUS_NONE
	mo.item_selected.connect(func(i: int) -> void: models_changed.emit(i == 0))
	row3.add_child(mo)
	box.add_child(row3)
	_predict_opts.append(po)
	_viz_opts.append(vo)
	_models_opts.append(mo)
	return box


func sync_pred_settings(predict: bool, viz: int, sprites: bool = true) -> void:
	for o in _models_opts:
		o.select(0 if sprites else 1)
	for o in _predict_opts:
		o.select(0 if predict else 1)
	for o in _viz_opts:
		o.select(clampi(viz, 0, PredViz.NAMES.size() - 1))


func _select_color(i: int) -> void:
	selected_color = i
	for k in _swatches.size():
		var s := _btn_style(GC.COLORS[k])
		if k == i:
			s.set_border_width_all(3)
			s.border_color = Color.WHITE
		_swatches[k].add_theme_stylebox_override("normal", s)
		_swatches[k].add_theme_stylebox_override("hover", s)
		_swatches[k].add_theme_stylebox_override("pressed", s)


func set_menu_message(text: String) -> void:
	menu_msg.text = text


# ------------------------------------------------------------------ лобби

func _build_lobby(root: Control) -> void:
	lobby = _screen(root, 0.78)
	var vb := _centered_panel(lobby, 520)
	var t := _label("Лобби", 32, Color("ffd24a"))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)
	lobby_info = _label("", 14, Color(0.7, 0.8, 0.95))
	lobby_info.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(lobby_info)
	lobby_list = VBoxContainer.new()
	lobby_list.add_theme_constant_override("separation", 6)
	vb.add_child(lobby_list)
	lobby_start = _button("Старт", Color("2f7d4f"))
	lobby_start.pressed.connect(func() -> void: start_requested.emit())
	vb.add_child(lobby_start)
	var leave := _button("Выйти в меню", Color("5a2f3a"))
	leave.pressed.connect(func() -> void: leave_requested.emit())
	vb.add_child(leave)


func update_lobby(entries: Array, is_host: bool, info: String, can_start: bool) -> void:
	for c in lobby_list.get_children():
		c.queue_free()
	for e in entries:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var sw := ColorRect.new()
		sw.color = GC.COLORS[int(e["color"]) % GC.COLORS.size()]
		sw.custom_minimum_size = Vector2(22, 22)
		row.add_child(sw)
		row.add_child(_label(String(e["name"]), 20))
		if e["host"]:
			row.add_child(_label("(хост)", 14, Color(0.7, 0.75, 0.85)))
		if e["me"]:
			row.add_child(_label("← вы", 14, Color("ffd24a")))
		lobby_list.add_child(row)
	lobby_info.text = info
	lobby_start.visible = is_host
	lobby_start.disabled = not can_start


# ------------------------------------------------------------------ HUD

func _build_hud(root: Control) -> void:
	hud = _screen(root)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_ping = _label("", 14, Color(0.8, 0.85, 0.95))
	hud_ping.position = Vector2(14, 8)
	hud.add_child(hud_ping)
	hud_timer = _label("", 22, Color(1, 1, 1, 0.9))
	hud_timer.position = Vector2(600, 8)
	hud.add_child(hud_timer)
	hud_hp = Control.new()
	hud_hp.position = Vector2(20, 660)
	hud_hp.custom_minimum_size = Vector2(260, 40)
	hud_hp.draw.connect(_draw_hp)
	hud.add_child(hud_hp)
	hud_runes = VBoxContainer.new()
	hud_runes.position = Vector2(20, 560)
	hud_runes.add_theme_constant_override("separation", 3)
	hud.add_child(hud_runes)
	hud_feed = VBoxContainer.new()
	hud_feed.position = Vector2(1000, 34)
	hud_feed.custom_minimum_size = Vector2(260, 0)
	hud.add_child(hud_feed)
	countdown_label = _label("", 120, Color("ffd24a"))
	countdown_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	countdown_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	countdown_label.add_theme_constant_override("outline_size", 10)
	hud.add_child(countdown_label)
	hud_banner = _label("", 24, Color("ff8a80"))
	hud_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	hud_banner.position = Vector2(440, 70)
	hud.add_child(hud_banner)


func _draw_hp() -> void:
	if not _hp_on:
		return
	var f := ThemeDB.fallback_font
	hud_hp.draw_rect(Rect2(0, 8, 260, 26), Color(0, 0, 0, 0.6))
	var k := clampf(_hp_value / float(GC.HP_MAX), 0.0, 1.0)
	var c := Color("4cd964") if k > 0.5 else (Color("ffcc00") if k > 0.25 else Color("ff453a"))
	hud_hp.draw_rect(Rect2(3, 11, 254.0 * k, 20), c)
	hud_hp.draw_string(f, Vector2(10, 28), "HP %d" % int(_hp_value), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)


func update_hud(ping_text: String, hp: float, show_hp: bool, my_state: PState, timer_text: String, banner: String) -> void:
	hud_ping.text = ping_text
	_hp_value = hp
	_hp_on = show_hp
	hud_hp.queue_redraw()
	hud_timer.text = timer_text
	hud_banner.text = banner
	for c in hud_runes.get_children():
		c.queue_free()
	if my_state != null:
		for r in GC.NUM_RUNES:
			if my_state.buffs[r] > 0:
				var total := GC.CHAOS_TICKS if r == GC.R_CHAOS else GC.BUFF_TICKS
				var row := HBoxContainer.new()
				row.add_theme_constant_override("separation", 8)
				var sw := ColorRect.new()
				sw.color = GC.RUNE_COLORS[r]
				sw.custom_minimum_size = Vector2(14, 14)
				row.add_child(sw)
				row.add_child(_label("%s  %.0f c" % [GC.RUNE_NAMES[r], float(my_state.buffs[r]) / GC.TICK_HZ], 14))
				var pb := ProgressBar.new()
				pb.custom_minimum_size = Vector2(80, 10)
				pb.max_value = total
				pb.value = my_state.buffs[r]
				pb.show_percentage = false
				var fill := _btn_style(GC.RUNE_COLORS[r])
				fill.set_content_margin_all(0)
				pb.add_theme_stylebox_override("fill", fill)
				var bgs := _btn_style(Color(0, 0, 0, 0.5))
				bgs.set_content_margin_all(0)
				pb.add_theme_stylebox_override("background", bgs)
				row.add_child(pb)
				hud_runes.add_child(row)


func add_feed(text: String, color: Color) -> void:
	var l := _label(text, 14, color)
	hud_feed.add_child(l)
	if hud_feed.get_child_count() > 5:
		hud_feed.get_child(0).queue_free()
	var tw := create_tween()
	tw.tween_interval(5.0)
	tw.tween_property(l, "modulate:a", 0.0, 1.0)
	tw.tween_callback(l.queue_free)


func clear_feed() -> void:
	for c in hud_feed.get_children():
		c.queue_free()


# ------------------------------------------------------------------ итоги, обрыв, пауза

func _build_result(root: Control) -> void:
	result = _screen(root, 0.82)
	var vb := _centered_panel(result, 560)
	result_title = _label("", 54, Color("ffd24a"))
	result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(result_title)
	result_sub = _label("", 20)
	result_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(result_sub)
	result_stats = VBoxContainer.new()
	result_stats.add_theme_constant_override("separation", 6)
	vb.add_child(result_stats)
	result_wait = _label("Ждём хоста для реванша…", 14, Color(0.7, 0.75, 0.85))
	result_wait.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(result_wait)
	result_rematch = _button("Реванш", Color("2f7d4f"))
	result_rematch.pressed.connect(func() -> void: rematch_requested.emit())
	vb.add_child(result_rematch)
	var menu_btn := _button("В меню", Color("5a2f3a"))
	menu_btn.pressed.connect(func() -> void: leave_requested.emit())
	vb.add_child(menu_btn)


## outcome: "win" | "lose" | "draw"
func show_result(outcome: String, winner_name: String, rows: Array, is_host: bool) -> void:
	match outcome:
		"win":
			result_title.text = "ПОБЕДА"
			result_title.add_theme_color_override("font_color", Color("ffd24a"))
			result_sub.text = "Вы последний на арене!"
		"lose":
			result_title.text = "ПОРАЖЕНИЕ"
			result_title.add_theme_color_override("font_color", Color("ff5d5d"))
			result_sub.text = "Победитель: %s" % winner_name
		_:
			result_title.text = "НИЧЬЯ"
			result_title.add_theme_color_override("font_color", Color("b0b8c8"))
			result_sub.text = "Победителя нет"
	for c in result_stats.get_children():
		c.queue_free()
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 8)
	result_stats.add_child(grid)
	for h in ["", "Игрок", "Убийства", "Урон", "Время, с"]:
		var hl := _label(h, 14, Color(0.7, 0.75, 0.85))
		hl.custom_minimum_size = Vector2(60 if h not in ["Игрок", ""] else (170 if h == "Игрок" else 18), 0)
		hl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if h not in ["", "Игрок"] else HORIZONTAL_ALIGNMENT_LEFT
		grid.add_child(hl)
	for r in rows:
		var sw := ColorRect.new()
		sw.color = GC.COLORS[int(r["color"]) % GC.COLORS.size()]
		sw.custom_minimum_size = Vector2(18, 18)
		sw.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		grid.add_child(sw)
		var nm := _label(("%s  ★" if r["winner"] else "%s") % r["name"], 17, Color("ffd24a") if r["winner"] else Color(0.9, 0.92, 0.97))
		nm.custom_minimum_size = Vector2(170, 0)
		grid.add_child(nm)
		for v in [r["kills"], r["damage"], r["secs"]]:
			var vl := _label(str(v), 17)
			vl.custom_minimum_size = Vector2(60, 0)
			vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			grid.add_child(vl)
	result_rematch.visible = is_host
	result_wait.visible = not is_host


func _build_disconnected(root: Control) -> void:
	disconnected = _screen(root, 0.85)
	var vb := _centered_panel(disconnected, 460)
	var t := _label("Соединение потеряно", 32, Color("ff8a80"))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)
	disc_msg = _label("", 16)
	disc_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	disc_msg.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(disc_msg)
	var b := _button("В меню", Color("3b4a7a"))
	b.pressed.connect(func() -> void: leave_requested.emit())
	vb.add_child(b)


func _build_pause(root: Control) -> void:
	pause = _screen(root, 0.6)
	var vb := _centered_panel(pause, 360)
	var t := _label("Пауза", 32)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)
	var note := _label("В сетевой игре мир не останавливается", 13, Color(0.7, 0.75, 0.85))
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(note)
	var r := _button("Продолжить", Color("2f7d4f"))
	r.pressed.connect(func() -> void: resume_requested.emit())
	vb.add_child(r)
	vb.add_child(HSeparator.new())
	vb.add_child(_label("Настройки предсказания (клиент)", 14, Color(0.75, 0.8, 0.9)))
	vb.add_child(_pred_settings_row(13))
	vb.add_child(_label("F4 — предсказание рывка, F8 — визуализация, F6 — модели", 12, Color(0.6, 0.65, 0.75)))
	var l := _button("Выйти в меню", Color("5a2f3a"))
	l.pressed.connect(func() -> void: leave_requested.emit())
	vb.add_child(l)


## Показывает ровно один «большой» экран; "game" — только HUD.
func show_only(which: String) -> void:
	menu.visible = which == "menu"
	lobby.visible = which == "lobby"
	result.visible = which == "result"
	disconnected.visible = which == "disconnected"
	pause.visible = which == "pause"
	lab.visible = which == "lab"
	hud.visible = which in ["game", "pause", "result"]


# ------------------------------------------------------------------ ПР №5: лаборатория репликации (настройки и замер)

## Правая панель: все семь техник репликации — переключатели, наборы «до»/«после», оверлеи, профиль сети, кнопка «Замер».
## Логики репликации здесь нет: виджеты лишь испускают сигналы (App передаёт их в ReplLab), а sync_repl() выставляет их по состоянию лаборатории.
func _build_lab(root: Control) -> void:
	lab = Control.new()
	lab.set_anchors_preset(Control.PRESET_FULL_RECT)
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(lab)
	var pc := PanelContainer.new()
	pc.anchor_left = 1.0
	pc.anchor_right = 1.0
	pc.offset_left = -372.0
	pc.offset_right = -8.0
	pc.offset_top = 8.0
	pc.add_theme_stylebox_override("panel", _panel("141a2eea"))
	lab.add_child(pc)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	pc.add_child(vb)
	vb.add_child(_label("Настройки репликации (ПР №5)", 16, Color("ffd24a")))
	var prow := HBoxContainer.new()
	prow.add_theme_constant_override("separation", 6)
	prow.add_child(_label("Набор:", 13))
	_repl_preset_opt = OptionButton.new()
	_repl_preset_opt.add_item("«До» — наивная (B)")
	_repl_preset_opt.add_item("«После» — все семь (O)")
	_repl_preset_opt.add_item("Свой набор")
	_repl_preset_opt.focus_mode = Control.FOCUS_NONE
	_repl_preset_opt.item_selected.connect(func(i: int) -> void:
		if i == 0:
			repl_preset_changed.emit("baseline")
		elif i == 1:
			repl_preset_changed.emit("optimized"))
	prow.add_child(_repl_preset_opt)
	vb.add_child(prow)
	var hints := {
		"relevancy": "Replication Graph: сетка + релевантность (1)",
		"custom_relevance": "IsNetRelevantFor: направление, гистерезис (2)",
		"dormancy": "Net Dormancy: статика спит (3)",
		"push": "Push-based: только изменённые поля (4)",
		"quantize": "Квантование позиций и скоростей (5)",
		"freq": "NetUpdateFrequency по классам (6)",
		"priority": "NetPriority + бюджет канала (7)",
	}
	for k in ReplCfg.TECH_KEYS:
		var cb := CheckButton.new()
		cb.text = hints[k]
		cb.focus_mode = Control.FOCUS_NONE
		cb.add_theme_font_size_override("font_size", 13)
		cb.toggled.connect(func(on: bool) -> void: repl_flag_changed.emit(k, on))
		vb.add_child(cb)
		_repl_checks[k] = cb
	vb.add_child(HSeparator.new())
	vb.add_child(_label("Показывать", 13, Color(0.75, 0.8, 0.9)))
	var ov := {"hud": "Панель статистики (H)", "minimap": "Мини-карта уровня (M)", "ghosts": "Серые контуры нереплицируемых (G)"}
	for k in ov.keys():
		var cb2 := CheckButton.new()
		cb2.text = ov[k]
		cb2.focus_mode = Control.FOCUS_NONE
		cb2.add_theme_font_size_override("font_size", 13)
		cb2.button_pressed = true
		cb2.toggled.connect(func(on: bool) -> void: repl_overlay_changed.emit(k, on))
		vb.add_child(cb2)
		_repl_checks["ov_" + k] = cb2
	var nrow := HBoxContainer.new()
	nrow.add_theme_constant_override("separation", 6)
	nrow.add_child(_label("Сеть:", 13))
	lab_net_opt = OptionButton.new()
	for p in NET_PRESETS:
		lab_net_opt.add_item(p)
	lab_net_opt.focus_mode = Control.FOCUS_NONE
	lab_net_opt.item_selected.connect(func(i: int) -> void: net_preset_changed.emit(i))
	nrow.add_child(lab_net_opt)
	vb.add_child(nrow)
	_repl_status = _label("", 12, Color(0.65, 0.7, 0.8))
	_repl_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(_repl_status)
	repl_measure_btn = _button("Замер «до/после» (≈ 10 с)", Color("2f7d4f"))
	repl_measure_btn.add_theme_font_size_override("font_size", 14)
	repl_measure_btn.pressed.connect(func() -> void:
		repl_measure_btn.disabled = true
		repl_measure_btn.text = "Идёт замер…"
		repl_measure_requested.emit())
	vb.add_child(repl_measure_btn)
	var back := _button("Выйти в меню (Esc)", Color("5a2f3a"))
	back.add_theme_font_size_override("font_size", 14)
	back.pressed.connect(func() -> void: leave_requested.emit())
	vb.add_child(back)
	_build_repl_result(lab)


func _build_repl_result(parent: Control) -> void:
	repl_result = _screen(parent, 0.55)
	repl_result.visible = false
	var vb := _centered_panel(repl_result, 760)
	vb.add_child(_label("Результат замера: исходящий трафик сервера", 20, Color("ffd24a")))
	repl_result_grid = GridContainer.new()
	repl_result_grid.columns = 5
	repl_result_grid.add_theme_constant_override("h_separation", 18)
	repl_result_grid.add_theme_constant_override("v_separation", 4)
	vb.add_child(repl_result_grid)
	repl_result_note = _label("", 13, Color(0.75, 0.8, 0.9))
	repl_result_note.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(repl_result_note)
	var close := _button("Закрыть", Color("3b4a7a"))
	close.pressed.connect(func() -> void: repl_result.visible = false)
	vb.add_child(close)


## Показывает таблицу замера (ReplLab.measure_done). rows: [{label,kb_s,less_pct,known,err,missing,key,active}]
func show_repl_measure(res: Dictionary) -> void:
	repl_measure_btn.disabled = false
	repl_measure_btn.text = "Замер «до/после» (≈ 10 с)"
	for c in repl_result_grid.get_children():
		c.queue_free()
	for h in ["Набор", "КБ/с (3 клиента)", "Снижение", "Акторов у клиента", "Ошибка вида, px"]:
		repl_result_grid.add_child(_label(h, 13, Color(0.7, 0.78, 0.95)))
	for r in res["rows"]:
		var hi: bool = r["key"] in ["baseline", "optimized", "current"]
		var col := Color("ffd479") if r["key"] == "optimized" else (Color(0.95, 0.95, 1.0) if hi else Color(0.8, 0.84, 0.92))
		var less := "—" if r["key"] == "baseline" else "−%.1f%%" % r["less_pct"]
		var vals := [r["label"], "%.1f" % r["kb_s"], less, "%.1f из %d" % [r["known"], res["actors"]], "%.2f" % r["err"]]
		for v in vals:
			repl_result_grid.add_child(_label(str(v), 14, col))
	var same: bool = res["same_checksum"]
	repl_result_note.text = "Один и тот же сценарий (%d с игры, seed 7, 3 клиента, виртуальное время): контрольная сумма состояния мира %s — разница только от сетевых настроек. Полный профиль на 30 с, вклад каждой техники и графики — docs/Replication_Optimization.md." % [res["seconds"], "совпала во всех прогонах (%d)" % res["checksum"] if same else "РАЗОШЛАСЬ (ошибка!)"]
	repl_result.visible = true


## Выставляет виджеты по состоянию лаборатории (без повторных сигналов).
func sync_repl(cfg: ReplCfg, overlays: Dictionary) -> void:
	for k in ReplCfg.TECH_KEYS:
		(_repl_checks[k] as CheckButton).set_pressed_no_signal(cfg.get_flag(k))
	for k in overlays.keys():
		if _repl_checks.has("ov_" + k):
			(_repl_checks["ov_" + k] as CheckButton).set_pressed_no_signal(overlays[k])
	var n := cfg.active().size()
	_repl_preset_opt.select(0 if n == 0 else (1 if n == ReplCfg.TECH_KEYS.size() else 2))
	_repl_status.text = "Включено техник: %d из 7. Пакеты WorldUpdate/WorldReliable, формат — docs/Protocol_Specification.md." % n


func sync_net_preset(i: int) -> void:
	preset_opt.select(clampi(i, 0, 2))
	lab_net_opt.select(clampi(i, 0, 2))
