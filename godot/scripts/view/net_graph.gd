class_name NetGraph
extends Control
## Оверлей net_graph (клавиша F3): полная сетевая статистика, влияющая на игру, и мини-графики за ~10 секунд.
## Данные готовит App.net_report(): {title, rows:[[метка, значение, серьёзность 0/1/2] | ["#", заголовок раздела]], graphs:[...]}.

const SEV_COLORS := [Color("9fe870"), Color("ffd24a"), Color("ff5d5d")]

var report := {}
var font: Font = ThemeDB.fallback_font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_report(r: Dictionary) -> void:
	report = r
	queue_redraw()


func _draw() -> void:
	if report.is_empty():
		return
	var rows: Array = report["rows"]
	var graphs: Array = report["graphs"]
	# две колонки: слева мини-графики, справа таблица значений (вся панель помещается в 720 px по высоте)
	var gw := 214.0
	var tw := 392.0
	var line := 14.5
	var h := maxf(34.0 + rows.size() * line + 8.0, 34.0 + graphs.size() * 112.0)
	var origin := Vector2(size.x - gw - tw - 10.0, 8.0)
	draw_rect(Rect2(origin, Vector2(gw + tw, h)), Color(0.04, 0.05, 0.08, 0.88))
	draw_rect(Rect2(origin, Vector2(gw + tw, h)), Color(1, 1, 1, 0.15), false, 1.0)
	draw_string(font, origin + Vector2(10, 20), String(report["title"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color.WHITE)
	var gy := origin.y + 52.0
	for g in graphs:
		_draw_graph(Rect2(origin.x + 10, gy, gw - 20, 74.0), g)
		gy += 112.0
	var x0 := origin.x + gw
	draw_line(Vector2(x0, origin.y + 28), Vector2(x0, origin.y + h - 8), Color(1, 1, 1, 0.1), 1.0)
	var y := origin.y + 36.0
	for r in rows:
		if r[0] == "#":
			draw_string(font, Vector2(x0 + 10, y), String(r[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("7aa2ff"))
			draw_line(Vector2(x0 + 10, y + 3), Vector2(x0 + tw - 10, y + 3), Color(1, 1, 1, 0.1), 1.0)
		else:
			draw_string(font, Vector2(x0 + 14, y), String(r[0]), HORIZONTAL_ALIGNMENT_LEFT, 205, 11, Color(0.8, 0.82, 0.88))
			draw_string(font, Vector2(x0 + 222, y), String(r[1]), HORIZONTAL_ALIGNMENT_LEFT, tw - 232, 11, SEV_COLORS[int(r[2])])
		y += line


func _draw_graph(rect: Rect2, g: Dictionary) -> void:
	draw_rect(rect, Color(1, 1, 1, 0.05))
	draw_string(font, rect.position + Vector2(4, -3), "%s  (сейчас %s)" % [g["title"], g["now"]], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.75, 0.78, 0.85))
	var values: Array = g["values"]
	var vmax := maxf(float(g["max"]), 0.001)
	for t in [g["warn"], g["bad"]]:
		var ty := rect.end.y - rect.size.y * clampf(float(t) / vmax, 0.0, 1.0)
		draw_line(Vector2(rect.position.x, ty), Vector2(rect.end.x, ty), Color(1, 1, 1, 0.12), 1.0)
	if values.size() < 2:
		return
	var step := rect.size.x / float(g["window"] - 1)
	var pts := PackedVector2Array()
	for i in values.size():
		var v := clampf(float(values[i]) / vmax, 0.0, 1.0)
		pts.append(Vector2(rect.end.x - (values.size() - 1 - i) * step, rect.end.y - rect.size.y * v))
	var last: float = float(values.back())
	var col: Color = SEV_COLORS[2] if last >= float(g["bad"]) else (SEV_COLORS[1] if last >= float(g["warn"]) else SEV_COLORS[0])
	draw_polyline(pts, col, 1.6)
