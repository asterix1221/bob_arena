class_name RuneArt
extends RefCounted
## Значки рун на земле: цветной диск со свечением и символом по типу (без ассетов, чистые примитивы).


static func _poly(ci: CanvasItem, pts: Array, color: Color, width: float = 2.5) -> void:
	for i in pts.size():
		ci.draw_line(pts[i], pts[(i + 1) % pts.size()], color, width)


## hidden=true — эффект «Случайность»: вместо символа знак «?», цвет приглушён.
static func draw_rune(ci: CanvasItem, pos: Vector2, rune_type: int, t: float, font: Font, hidden: bool = false) -> void:
	var col: Color = GC.RUNE_COLORS[rune_type] if not hidden else Color("c9c9c9")
	var bob := sin(t * 3.0 + pos.x * 0.05) * 3.0
	var c := pos + Vector2(0, -16 + bob)
	ci.draw_circle(c, 22.0 + sin(t * 4.0) * 1.5, Color(col.r, col.g, col.b, 0.18))
	ci.draw_circle(c, 15.0, Color(0.06, 0.07, 0.1, 0.92))
	ci.draw_arc(c, 15.0, 0.0, TAU, 32, col, 2.5)
	if hidden:
		ci.draw_string(font, c + Vector2(-6, 8), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, col)
		return
	match rune_type:
		GC.R_SPEED:
			for k in 2:
				var o := Vector2(-3 + k * 7, 0)
				_poly(ci, [c + o + Vector2(-4, -7), c + o + Vector2(3, 0), c + o + Vector2(-4, 7)], col, 2.5)
		GC.R_JUMP:
			ci.draw_line(c + Vector2(0, 8), c + Vector2(0, -7), col, 3.0)
			ci.draw_line(c + Vector2(0, -8), c + Vector2(-6, -1), col, 3.0)
			ci.draw_line(c + Vector2(0, -8), c + Vector2(6, -1), col, 3.0)
		GC.R_DAMAGE:
			var pts := []
			for i in 8:
				var r := 9.0 if i % 2 == 0 else 4.0
				pts.append(c + Vector2(cos(TAU * i / 8.0 - PI / 2), sin(TAU * i / 8.0 - PI / 2)) * r)
			_poly(ci, pts, col, 2.5)
		GC.R_KNOCKBACK:
			for i in 6:
				var a := TAU * i / 6.0
				ci.draw_line(c + Vector2(cos(a), sin(a)) * 3.0, c + Vector2(cos(a), sin(a)) * 10.0, col, 2.5)
		GC.R_VAMPIRE:
			ci.draw_circle(c + Vector2(0, 2), 5.0, col)
			_poly(ci, [c + Vector2(-5, 0), c + Vector2(0, -9), c + Vector2(5, 0)], col, 2.5)
		GC.R_ARMOR:
			_poly(ci, [c + Vector2(-8, -8), c + Vector2(8, -8), c + Vector2(8, 1), c + Vector2(0, 10), c + Vector2(-8, 1)], col, 2.5)
		GC.R_STEADY:
			_poly(ci, [c + Vector2(-9, 6), c + Vector2(-5, -6), c + Vector2(5, -6), c + Vector2(9, 6)], col, 2.5)
			ci.draw_line(c + Vector2(-9, 6), c + Vector2(9, 6), col, 3.0)
		GC.R_SLOWHIT:
			for i in 3:
				var a2 := TAU * i / 6.0
				ci.draw_line(c + Vector2(cos(a2), sin(a2)) * 10.0, c - Vector2(cos(a2), sin(a2)) * 10.0, col, 2.0)
		GC.R_INVERTHIT:
			ci.draw_line(c + Vector2(-8, -3), c + Vector2(8, -3), col, 2.5)
			ci.draw_line(c + Vector2(8, -3), c + Vector2(4, -7), col, 2.5)
			ci.draw_line(c + Vector2(8, 3), c + Vector2(-8, 3), col, 2.5)
			ci.draw_line(c + Vector2(-8, 3), c + Vector2(-4, 7), col, 2.5)
		GC.R_HEALTH:
			ci.draw_line(c + Vector2(-8, 0), c + Vector2(8, 0), col, 4.0)
			ci.draw_line(c + Vector2(0, -8), c + Vector2(0, 8), col, 4.0)
		GC.R_CHAOS:
			ci.draw_string(font, c + Vector2(-6, 8), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, col)
