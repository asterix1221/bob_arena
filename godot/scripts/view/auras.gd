class_name Auras
extends RefCounted
## Ауры вокруг персонажа по типам рун (форма и движение у каждой свои). Несколько активных рун накладываются.
## center — центр тела (px), mask — биты 0..10 руны, 11 замедление, 12 инверсия (из buff_mask()).


static func draw(ci: CanvasItem, center: Vector2, feet: Vector2, facing: int, mask: int, t: float, font: Font) -> void:
	for r in GC.NUM_RUNES:
		if mask & (1 << r) == 0:
			continue
		match r:
			GC.R_SPEED: _speed(ci, center, facing, t)
			GC.R_JUMP: _jump(ci, center, feet, t)
			GC.R_DAMAGE: _damage(ci, center, t)
			GC.R_KNOCKBACK: _knockback(ci, center, t)
			GC.R_VAMPIRE: _vampire(ci, center, t)
			GC.R_ARMOR: _armor(ci, center, t)
			GC.R_STEADY: _steady(ci, center, feet, t)
			GC.R_SLOWHIT: _snow(ci, center, t, GC.RUNE_COLORS[GC.R_SLOWHIT])
			GC.R_INVERTHIT: _arrows(ci, center, t, GC.RUNE_COLORS[GC.R_INVERTHIT], 30.0)
			GC.R_CHAOS: _chaos(ci, center, t, font)
	# дебаффы жертвы: меньшие, «налипшие» эффекты над головой
	if mask & (1 << 11):
		_snow(ci, center, t * 1.3, GC.DEBUFF_SLOW_COLOR.darkened(0.15), 0.7)
		ci.draw_arc(center, 26.0, 0.0, TAU, 24, Color(GC.DEBUFF_SLOW_COLOR, 0.55), 2.0)
	if mask & (1 << 12):
		_arrows(ci, center + Vector2(0, -22), t * 1.6, GC.DEBUFF_INVERT_COLOR, 16.0)


static func _speed(ci: CanvasItem, c: Vector2, facing: int, t: float) -> void:
	var col: Color = GC.RUNE_COLORS[GC.R_SPEED]
	for i in 4:
		var y := -18.0 + i * 12.0
		var len := 22.0 + 10.0 * sin(t * 12.0 + i)
		var x0 := -facing * 14.0
		ci.draw_line(c + Vector2(x0, y), c + Vector2(x0 - facing * len, y), Color(col, 0.55), 2.5)
	for i in 3:
		var a := t * 5.0 + TAU * i / 3.0
		ci.draw_circle(c + Vector2(cos(a), sin(a) * 0.6) * 30.0, 2.5, col)


static func _jump(ci: CanvasItem, c: Vector2, feet: Vector2, t: float) -> void:
	var col: Color = GC.RUNE_COLORS[GC.R_JUMP]
	var k := fmod(t * 1.4, 1.0)
	ci.draw_arc(feet + Vector2(0, -2), 14.0 + 22.0 * k, 0.0, TAU, 28, Color(col, 0.7 * (1.0 - k)), 3.0)
	for i in 5:
		var ph := fmod(t * 0.9 + i * 0.2, 1.0)
		var px := -22.0 + i * 11.0
		ci.draw_circle(feet + Vector2(px, -ph * 60.0), 2.5 * (1.0 - ph) + 1.0, Color(col, 0.8 * (1.0 - ph)))


static func _damage(ci: CanvasItem, c: Vector2, t: float) -> void:
	var col: Color = GC.RUNE_COLORS[GC.R_DAMAGE]
	for i in 7:
		var a := TAU * i / 7.0 + t * 0.7
		var flick := 0.6 + 0.4 * sin(t * 14.0 + i * 1.7)
		var base := c + Vector2(cos(a), sin(a)) * 24.0
		var tip := c + Vector2(cos(a), sin(a)) * (34.0 + 12.0 * flick)
		var side := Vector2(-sin(a), cos(a)) * 4.0
		ci.draw_colored_polygon(PackedVector2Array([base + side, tip, base - side]), Color(col, 0.75))
	ci.draw_arc(c, 24.0, 0.0, TAU, 28, Color(col, 0.35 + 0.2 * sin(t * 9.0)), 2.0)


static func _knockback(ci: CanvasItem, c: Vector2, t: float) -> void:
	var col: Color = GC.RUNE_COLORS[GC.R_KNOCKBACK]
	for i in 2:
		var k := fmod(t * 1.2 + i * 0.5, 1.0)
		ci.draw_arc(c, 18.0 + 28.0 * k, 0.0, TAU, 32, Color(col, 0.8 * (1.0 - k)), 3.5 * (1.0 - k) + 1.0)


static func _vampire(ci: CanvasItem, c: Vector2, t: float) -> void:
	var col: Color = GC.RUNE_COLORS[GC.R_VAMPIRE]
	for i in 7:
		var ph := fmod(t * 0.8 + i / 7.0, 1.0)
		var a := TAU * i / 7.0 + ph * 2.0
		var r := 44.0 * (1.0 - ph)
		var p := c + Vector2(cos(a), sin(a)) * r
		ci.draw_circle(p, 3.0 * (0.4 + ph), Color(col, 0.9))
		ci.draw_line(p, p + Vector2(cos(a), sin(a)) * 6.0, Color(col, 0.5), 2.0)


static func _armor(ci: CanvasItem, c: Vector2, t: float) -> void:
	var col: Color = GC.RUNE_COLORS[GC.R_ARMOR]
	var pts := PackedVector2Array()
	for i in 6:
		var a := TAU * i / 6.0 + t * 0.6
		pts.append(c + Vector2(cos(a), sin(a)) * 33.0)
	ci.draw_colored_polygon(pts, Color(col, 0.13))
	for i in 6:
		ci.draw_line(pts[i], pts[(i + 1) % 6], Color(col, 0.85), 2.5)
	ci.draw_arc(c, 33.0 * (0.9 + 0.05 * sin(t * 6.0)), 0.0, TAU, 24, Color(1, 1, 1, 0.15), 1.5)


static func _steady(ci: CanvasItem, c: Vector2, feet: Vector2, t: float) -> void:
	var col: Color = GC.RUNE_COLORS[GC.R_STEADY].lightened(0.2)
	ci.draw_line(feet + Vector2(-26, 1), feet + Vector2(26, 1), Color(col, 0.8), 4.0)
	for i in 4:
		var a := t * 1.5 + TAU * i / 4.0
		var p := feet + Vector2(cos(a) * 24.0, -6.0 + sin(a) * 4.0)
		ci.draw_colored_polygon(PackedVector2Array([p + Vector2(0, -6), p + Vector2(5, 0), p + Vector2(0, 6), p + Vector2(-5, 0)]), Color(col, 0.9))


static func _snow(ci: CanvasItem, c: Vector2, t: float, col: Color, scale: float = 1.0) -> void:
	for i in 6:
		var ph := fmod(t * 0.5 + i * 0.17, 1.0)
		var p := c + Vector2(sin(t * 2.0 + i * 2.0) * 22.0 * scale, -36.0 * scale + ph * 70.0 * scale)
		for k in 3:
			var a := PI * k / 3.0 + t
			ci.draw_line(p - Vector2(cos(a), sin(a)) * 4.0 * scale, p + Vector2(cos(a), sin(a)) * 4.0 * scale, Color(col, 0.9 * (1.0 - ph * 0.6)), 1.5)


static func _arrows(ci: CanvasItem, c: Vector2, t: float, col: Color, radius: float) -> void:
	for i in 3:
		var a := t * 3.0 + TAU * i / 3.0
		var p := c + Vector2(cos(a), sin(a)) * radius
		var tang := Vector2(-sin(a), cos(a))
		ci.draw_line(p - tang * 6.0, p + tang * 6.0, col, 2.5)
		ci.draw_line(p + tang * 6.0, p + tang * 1.0 + Vector2(cos(a), sin(a)) * 4.0, col, 2.5)
		ci.draw_line(p + tang * 6.0, p + tang * 1.0 - Vector2(cos(a), sin(a)) * 4.0, col, 2.5)


static func _chaos(ci: CanvasItem, c: Vector2, t: float, font: Font) -> void:
	var col: Color = GC.RUNE_COLORS[GC.R_CHAOS]
	for i in 3:
		var a := t * 1.8 + TAU * i / 3.0
		var p := c + Vector2(cos(a) * 34.0, sin(a) * 22.0 - 6.0)
		ci.draw_string(font, p + Vector2(-5, 7), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(col, 0.65 + 0.3 * sin(t * 5.0 + i)))


## Дуги оставшегося времени вокруг персонажа (только для своего, где точные таймеры известны): снаружи внутрь.
static func draw_timers(ci: CanvasItem, center: Vector2, st: PState) -> void:
	var ring := 0
	for r in GC.NUM_RUNES:
		if st.buffs[r] <= 0:
			continue
		var total := GC.CHAOS_TICKS if r == GC.R_CHAOS else GC.BUFF_TICKS
		var frac := clampf(float(st.buffs[r]) / float(total), 0.0, 1.0)
		var rad := 42.0 + ring * 4.0
		ci.draw_arc(center, rad, -PI / 2, -PI / 2 + TAU * frac, 40, GC.RUNE_COLORS[r], 2.5)
		ring += 1
