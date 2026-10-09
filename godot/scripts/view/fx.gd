class_name Fx
extends RefCounted
## Частицы и всплывающие числа: искры попаданий, всплески подбора рун, смерть. Рисуются кодом.

const KIND_DOT := 0
const KIND_PLUS := 1
const KIND_RING := 2
const KIND_STAR := 3

var parts: Array = []      # {p, v, life, max, color, size, kind, grav}
var texts: Array = []      # {p, text, life, color}


func _add(p: Vector2, v: Vector2, life: float, color: Color, size: float, kind: int, grav: float = 0.0) -> void:
	parts.append({"p": p, "v": v, "life": life, "max": life, "color": color, "size": size, "kind": kind, "grav": grav})
	if parts.size() > 600:
		parts.pop_front()


func hit(pos: Vector2, dir: int, damage: int) -> void:
	for i in 10:
		var a := randf_range(-0.9, 0.9)
		var sp := randf_range(120.0, 320.0)
		_add(pos, Vector2(dir * cos(a) * sp, sin(a) * sp - 40.0), randf_range(0.15, 0.35), Color(1, 0.9, 0.5), randf_range(2.0, 4.0), KIND_DOT, 600.0)
	_add(pos, Vector2.ZERO, 0.22, Color(1, 1, 1, 0.9), 26.0, KIND_RING)
	texts.append({"p": pos + Vector2(0, -20), "text": "-%d" % damage, "life": 0.8, "color": Color(1, 0.35, 0.3)})


func pickup(pos: Vector2, color: Color, health: bool) -> void:
	for i in 18:
		var a := TAU * i / 18.0
		var sp := randf_range(80.0, 220.0)
		_add(pos, Vector2(cos(a), sin(a)) * sp, randf_range(0.35, 0.7), color, randf_range(2.5, 5.0), KIND_PLUS if health else KIND_STAR, -80.0)
	_add(pos, Vector2.ZERO, 0.45, color, 40.0, KIND_RING)
	_add(pos, Vector2.ZERO, 0.30, Color(1, 1, 1, 0.8), 22.0, KIND_RING)


func death(pos: Vector2, color: Color) -> void:
	for i in 30:
		var a := randf() * TAU
		var sp := randf_range(100.0, 480.0)
		_add(pos, Vector2(cos(a), sin(a)) * sp, randf_range(0.5, 1.1), color, randf_range(3.0, 7.0), KIND_DOT, 500.0)
	_add(pos, Vector2.ZERO, 0.6, color, 70.0, KIND_RING)


func update(dt: float) -> void:
	var keep: Array = []
	for q in parts:
		q["life"] -= dt
		if q["life"] > 0.0:
			q["v"].y += q["grav"] * dt
			q["p"] += q["v"] * dt
			keep.append(q)
	parts = keep
	var keep_t: Array = []
	for tx in texts:
		tx["life"] -= dt
		tx["p"].y -= 40.0 * dt
		if tx["life"] > 0.0:
			keep_t.append(tx)
	texts = keep_t


func draw(ci: CanvasItem, font: Font) -> void:
	for q in parts:
		var k: float = q["life"] / q["max"]
		var c: Color = q["color"]
		c.a *= k
		var p: Vector2 = q["p"]
		match int(q["kind"]):
			KIND_DOT:
				ci.draw_circle(p, q["size"] * (0.4 + 0.6 * k), c)
			KIND_RING:
				ci.draw_arc(p, q["size"] * (1.6 - k), 0.0, TAU, 28, c, 3.0 * k + 1.0)
			KIND_PLUS:
				var s: float = q["size"]
				ci.draw_line(p + Vector2(-s, 0), p + Vector2(s, 0), c, 2.5)
				ci.draw_line(p + Vector2(0, -s), p + Vector2(0, s), c, 2.5)
			KIND_STAR:
				var s2: float = q["size"]
				ci.draw_line(p + Vector2(-s2, -s2), p + Vector2(s2, s2), c, 2.0)
				ci.draw_line(p + Vector2(-s2, s2), p + Vector2(s2, -s2), c, 2.0)
	for tx in texts:
		var col: Color = tx["color"]
		col.a = clampf(tx["life"] * 2.0, 0.0, 1.0)
		ci.draw_string(font, tx["p"], tx["text"], HORIZONTAL_ALIGNMENT_CENTER, -1, 20, col)
