class_name PlayerDraw
extends RefCounted
## Модель игрока. Если загружены спрайты (Sprites, настройка «Модели» / F6) — рисуются они (персонаж 6x13 px и бита из листа),
## иначе минимальная модель без ассетов: тело-капсула цвета игрока, голова с глазами по направлению взгляда,
## ноги с циклом бега, «палка»-оружие со взмахом при ударе, растяжение/сжатие в прыжке и при приземлении,
## вспышка при попадании, остаточные силуэты при рывке, звёздочки при оглушении.
## p — словарь отрисовки: x, y (ноги, px), facing, vx (px/тик), vy, flags (бит0 жив, 2 земля, 3 рывок, 4/5 удары, 6 оглушение),
## anim — словарь анимаций (run_phase, squash, flash, atk_t, trail[]), color, local.


## alpha < 1 — полупрозрачный персонаж (визуализация предсказания: «предсказанный» игрок рисуется бледнее серверного).
static func draw(ci: CanvasItem, p: Dictionary, anim: Dictionary, color: Color, is_local: bool, t: float, alpha: float = 1.0) -> void:
	var x: float = p["x"]
	var y: float = p["y"]
	var f: int = p["facing"]
	var flags: int = p["flags"]
	var grounded: bool = flags & 4 != 0
	var dashing: bool = flags & 8 != 0
	# остаточные силуэты рывка
	if dashing:
		var trail: Array = anim.get("trail", [])
		for i in trail.size():
			var a := (0.12 + 0.28 * float(i) / maxf(trail.size(), 1)) * alpha
			if Sprites.active():
				Sprites.draw_char(ci, Sprites.texture(), Sprites.color_index(color), trail[i], f, 1.0, 1.0, 0.0, Color(1, 1, 1, a))
			else:
				_body(ci, trail[i], f, Color(color.r, color.g, color.b, a), 0.0, 1.0, 1.0, false)
	var squash: float = anim.get("squash", 0.0)
	var vy: float = p.get("vy", 0.0)
	var sy := 1.0 + clampf(-vy * 0.05, -0.12, 0.14) + squash * -0.22
	var sx := 1.0 / sy
	var run := absf(float(p.get("vx", 0.0))) > 0.8 and grounded
	var swing := sin(float(anim.get("run_phase", 0.0))) * (7.0 if run else 0.0)
	var flash: float = anim.get("flash", 0.0)
	var body_color := color.lerp(Color.WHITE, flash)
	if flags & 128 != 0:
		body_color = body_color.lerp(Color(0.6, 0.8, 1.0), 0.18)
	body_color.a = alpha
	if Sprites.active():
		# спрайт: вспышка попадания — яркая подсветка, оглушение/замедление — приглушённый или голубоватый оттенок, бег — лёгкий наклон и подскок
		var mod := Color(1, 1, 1, alpha)
		if flash > 0.0:
			mod = Color(1.0 + flash * 1.5, 1.0 + flash * 1.5, 1.0 + flash * 1.5, alpha)
		if flags & 128 != 0:
			mod = Color(mod.r * 0.78, mod.g * 0.9, mod.b, alpha)
		if flags & 64 != 0:
			mod = Color(mod.r * 0.7, mod.g * 0.7, mod.b * 0.7, alpha)
		var bob := -absf(sin(float(anim.get("run_phase", 0.0)))) * 2.0 if run else 0.0
		var tilt := sin(float(anim.get("run_phase", 0.0))) * 0.07 * float(f) if run else 0.0
		Sprites.draw_char(ci, Sprites.texture(), Sprites.color_index(color), Vector2(x, y + bob), f, sx, sy, tilt, mod)
	else:
		_body(ci, Vector2(x, y), f, body_color, swing, sx, sy, true)
		_eyes(ci, Vector2(x, y), f, sx, sy, flags & 64 != 0, alpha)
	_stick(ci, Vector2(x, y), f, flags, float(anim.get("atk_t", 0.0)), sx, sy, alpha)
	if flags & 64 != 0:
		for i in 3:
			var a := t * 6.0 + TAU * i / 3.0
			ci.draw_circle(Vector2(x, y - 62.0 * sy) + Vector2(cos(a) * 12.0, sin(a) * 4.0), 2.5, Color(1, 0.9, 0.3))


static func _body(ci: CanvasItem, pos: Vector2, f: int, col: Color, swing: float, sx: float, sy: float, outline: bool) -> void:
	var dark := col.darkened(0.45)
	# ноги
	var hip_y := pos.y - 14.0 * sy
	ci.draw_line(Vector2(pos.x - 5.0 * sx, hip_y), Vector2(pos.x - 5.0 * sx + swing, pos.y), dark, 4.5)
	ci.draw_line(Vector2(pos.x + 5.0 * sx, hip_y), Vector2(pos.x + 5.0 * sx - swing, pos.y), dark, 4.5)
	# тело (капсула = прямоугольник + два круга)
	var bw := 13.0 * sx
	var top := pos.y - 36.0 * sy
	var bot := pos.y - 14.0 * sy
	ci.draw_rect(Rect2(pos.x - bw, top, bw * 2.0, bot - top), col)
	ci.draw_circle(Vector2(pos.x, top), bw, col)
	ci.draw_circle(Vector2(pos.x, bot), bw, col)
	# голова
	var head := Vector2(pos.x, pos.y - 44.0 * sy)
	ci.draw_circle(head, 10.5 * sx, col.lightened(0.12))
	if outline:
		ci.draw_arc(head, 10.5 * sx, 0.0, TAU, 20, dark, 2.0)
		ci.draw_arc(Vector2(pos.x, top), bw, PI, TAU, 14, dark, 2.0)


static func _eyes(ci: CanvasItem, pos: Vector2, f: int, sx: float, sy: float, stunned: bool, alpha: float = 1.0) -> void:
	var head := Vector2(pos.x, pos.y - 44.0 * sy)
	for k in 2:
		var e := Vector2(head.x + f * (1.0 + k * 6.0) - 1.0 * f, head.y - 1.5)
		if stunned:
			ci.draw_line(e + Vector2(-2.5, -2.5), e + Vector2(2.5, 2.5), Color(0, 0, 0, alpha), 1.8)
			ci.draw_line(e + Vector2(-2.5, 2.5), e + Vector2(2.5, -2.5), Color(0, 0, 0, alpha), 1.8)
		else:
			ci.draw_circle(e, 3.2, Color(1, 1, 1, alpha))
			ci.draw_circle(e + Vector2(f * 1.2, 0), 1.6, Color(0, 0, 0, alpha))


static func _stick(ci: CanvasItem, pos: Vector2, f: int, flags: int, atk_t: float, sx: float, sy: float, alpha: float = 1.0) -> void:
	var hand := Vector2(pos.x + f * 12.0, pos.y - 26.0 * sy)
	var ang := -1.1                         # покой: палка поднята назад-вверх
	var light := flags & 16 != 0
	var heavy := flags & 32 != 0
	if light:
		ang = lerpf(-1.3, 0.35, clampf(atk_t / 0.05, 0.0, 1.0))
	elif heavy:
		ang = lerpf(-2.4, 0.6, clampf((atk_t - 0.14) / 0.04, 0.0, 1.0))
	var dir := Vector2(f * cos(ang), sin(ang))
	var tip := hand + dir * 30.0
	if Sprites.active():
		Sprites.draw_bat(ci, hand, dir, Color(1, 1, 1, alpha))
	else:
		ci.draw_line(hand, tip, Color(0.776, 0.545, 0.29, alpha), 4.5)
		ci.draw_circle(tip, 3.2, Color(0.541, 0.353, 0.169, alpha))
	if light or heavy:
		var arc_col := Color(1, 1, 1, 0.45 * alpha)
		if f > 0:
			ci.draw_arc(hand, 30.0, -1.3, 0.35, 12, arc_col, 3.0)
		else:
			ci.draw_arc(hand, 30.0, PI - 0.35, PI + 1.3, 12, arc_col, 3.0)


## «Призрак» авторитетного положения сервера: однотонный силуэт (тело + голова) цвета col с прозрачностью и обводкой.
## pos — ноги (px). dashing — рисуем ореол рывка, как у обычного игрока.
static func draw_silhouette(ci: CanvasItem, pos: Vector2, f: int, col: Color, dashing: bool) -> void:
	if Sprites.active():
		# силуэт спрайта (белая копия формы) красится в цвет призрака; контур — те же пиксели чуть крупнее и ярче
		var edge_c := Color(col.r, col.g, col.b, minf(col.a + 0.45, 1.0))
		Sprites.draw_char(ci, Sprites.silhouette(), 0, pos, f, 1.09, 1.045, 0.0, edge_c)
		Sprites.draw_char(ci, Sprites.silhouette(), 0, pos, f, 1.0, 1.0, 0.0, col)
		if dashing:
			ci.draw_arc(Vector2(pos.x, pos.y - 24.0), 34.0, 0.0, TAU, 28, Color(edge_c.r, edge_c.g, edge_c.b, 0.7), 2.0)
		return
	_body(ci, pos, f, col, 0.0, 1.0, 1.0, false)
	var edge := Color(col.r, col.g, col.b, minf(col.a + 0.45, 1.0))
	ci.draw_arc(Vector2(pos.x, pos.y - 44.0), 10.5, 0.0, TAU, 20, edge, 1.5)
	ci.draw_arc(Vector2(pos.x, pos.y - 36.0), 13.0, PI, TAU, 14, edge, 1.5)
	ci.draw_line(Vector2(pos.x - 13.0, pos.y - 36.0), Vector2(pos.x - 13.0, pos.y - 14.0), edge, 1.5)
	ci.draw_line(Vector2(pos.x + 13.0, pos.y - 36.0), Vector2(pos.x + 13.0, pos.y - 14.0), edge, 1.5)
	ci.draw_arc(Vector2(pos.x, pos.y - 14.0), 13.0, 0.0, PI, 14, edge, 1.5)
	if dashing:
		ci.draw_arc(Vector2(pos.x, pos.y - 24.0), 34.0, 0.0, TAU, 28, Color(edge.r, edge.g, edge.b, 0.7), 2.0)
