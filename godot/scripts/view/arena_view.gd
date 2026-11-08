class_name ArenaView
extends Node2D
## Отрисовка мира: фон, платформы, руны, игроки (модели, ауры, HP), частицы. Данные берёт у App:
##   app.world_players() -> [{id,name,color(Color),x,y,facing,vx,vy,flags,hp,buffs,alive,local,state(PState|null)}]
##   app.world_runes()   -> [{id,type,x,y}] (px)
##   app.local_chaos()   -> bool ("Случайность" у локального игрока: руны на карте скрыты)
## Анимационные состояния игроков (фаза бега, вспышка, сжатие при приземлении, замах) считаются здесь, только для вида.

var app: Node
var fx := Fx.new()
var anim := {}               # id -> {run_phase, squash, flash, atk_t, trail[], prev_hp, prev_grounded, prev_atk}
var time := 0.0
var show_hp := true
var font: Font = ThemeDB.fallback_font

const BG_TOP := Color("141a2e")
const BG_BOTTOM := Color("2a1a3a")


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST      # пиксель-арт спрайтов без сглаживания


func _process(delta: float) -> void:
	time += delta
	fx.update(delta)
	if app != null:
		_update_anims(delta, app.world_players())
	queue_redraw()


func _update_anims(dt: float, players: Array) -> void:
	for p in players:
		var id: int = p["id"]
		if not anim.has(id):
			anim[id] = {"run_phase": 0.0, "squash": 0.0, "flash": 0.0, "atk_t": 0.0, "trail": [], "prev_hp": p["hp"], "prev_grounded": true, "prev_atk": 0}
		var a: Dictionary = anim[id]
		var flags: int = p["flags"]
		if absf(float(p["vx"])) > 0.8:
			a["run_phase"] += dt * 16.0
		a["squash"] = maxf(a["squash"] - dt * 6.0, 0.0)
		var grounded: bool = flags & 4 != 0
		if grounded and not a["prev_grounded"]:
			a["squash"] = 1.0
		a["prev_grounded"] = grounded
		if p["hp"] < a["prev_hp"]:
			a["flash"] = 1.0
		a["prev_hp"] = p["hp"]
		a["flash"] = maxf(a["flash"] - dt * 7.0, 0.0)
		var atk := (1 if flags & 16 != 0 else 0) | (2 if flags & 32 != 0 else 0)
		if atk != 0 and a["prev_atk"] == 0:
			a["atk_t"] = 0.0
		elif atk != 0:
			a["atk_t"] += dt
		a["prev_atk"] = atk
		var trail: Array = a["trail"]
		if flags & 8 != 0:
			trail.append(Vector2(p["x"], p["y"]))
			if trail.size() > 6:
				trail.pop_front()
		elif not trail.is_empty():
			trail.pop_front()


func _draw() -> void:
	_draw_background()
	_draw_platforms()
	if app == null:
		return
	var chaos: bool = app.local_chaos()
	for r in app.world_runes():
		RuneArt.draw_rune(self, Vector2(r["x"], r["y"]), int(r["type"]), time, font, chaos)
	var players: Array = app.world_players()
	var viz: int = app.viz_mode if app.mode == "client" else PredViz.OFF       # визуализация предсказания — только у клиента
	PredViz.draw_under(self, app.client, viz)
	var local_feet := Vector2.ZERO
	for p in players:
		if not p["alive"]:
			continue
		var a: Dictionary = anim.get(p["id"], {})
		var col: Color = p["color"]
		var center := Vector2(p["x"], p["y"] - 24.0)
		Auras.draw(self, center, Vector2(p["x"], p["y"]), p["facing"], int(p["buffs"]), time, font)
		var alpha := PredViz.local_alpha(viz) if p["local"] else 1.0
		PlayerDraw.draw(self, p, a, col, p["local"], time, alpha)
		if p["local"]:
			local_feet = Vector2(p["x"], p["y"])
		if p["local"] and p["state"] != null:
			Auras.draw_timers(self, center, p["state"])
	for p in players:
		if p["alive"]:
			_draw_overhead(p)
	fx.draw(self, font)
	PredViz.draw_over(self, app.client, viz, font, local_feet, float(Time.get_ticks_msec()), app.viz_flash_t0_ms, app.viz_flash_pos)


func _draw_background() -> void:
	var steps := 18
	for i in steps:
		var k := float(i) / float(steps - 1)
		draw_rect(Rect2(0, i * 720.0 / steps, 1280, 720.0 / steps + 1.0), BG_TOP.lerp(BG_BOTTOM, k))
	for i in 40:                                 # «звёзды»: детерминированная россыпь
		var sx := fmod(float(i) * 197.3, 1280.0)
		var sy := fmod(float(i) * 83.7, 420.0)
		draw_circle(Vector2(sx, sy), 1.2 + float(i % 3) * 0.5, Color(1, 1, 1, 0.25 + 0.2 * sin(time * 1.5 + i)))
	# пропасть: тёмное свечение снизу
	for i in 8:
		draw_rect(Rect2(0, 720 - i * 14, 1280, 14), Color(0.55, 0.1, 0.2, 0.05 + 0.025 * i))


func _draw_platforms() -> void:
	for pl in GC.PLATFORMS_PX:
		var x1: float = pl[0]
		var x2: float = pl[1]
		var y: float = pl[2]
		draw_rect(Rect2(x1, y, x2 - x1, 26), Color("2b3350"))
		draw_rect(Rect2(x1, y, x2 - x1, 6), Color("5a6bb0"))
		draw_rect(Rect2(x1, y + 26, x2 - x1, 6), Color("1a2036"))
		draw_circle(Vector2(x1, y + 13), 13.0, Color("2b3350"))
		draw_circle(Vector2(x2, y + 13), 13.0, Color("2b3350"))
		for k in range(int(x1) + 20, int(x2) - 10, 46):
			draw_rect(Rect2(k, y + 12, 24, 3), Color(1, 1, 1, 0.06))


func _draw_overhead(p: Dictionary) -> void:
	var x: float = p["x"]
	var y: float = p["y"]
	var col: Color = p["color"]
	var name_y := y - 86.0
	if show_hp:
		var w := 54.0
		var hp := clampf(float(p["hp"]) / float(GC.HP_MAX), 0.0, 1.0)
		var bar := Rect2(x - w / 2.0, y - 74.0, w, 7.0)
		draw_rect(bar.grow(1.5), Color(0, 0, 0, 0.75))
		var hc := Color("4cd964") if hp > 0.5 else (Color("ffcc00") if hp > 0.25 else Color("ff453a"))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * hp, bar.size.y)), hc)
		draw_string(font, Vector2(x - 20, y - 78.0), "%d" % int(p["hp"]), HORIZONTAL_ALIGNMENT_CENTER, 40, 12, Color(1, 1, 1, 0.9))
		name_y -= 6.0
	draw_string(font, Vector2(x - 60, name_y), String(p["name"]), HORIZONTAL_ALIGNMENT_CENTER, 120, 14, Color(col.lightened(0.35), 0.95))
	if p["local"]:
		var tip := Vector2(x, name_y - 14.0 + sin(time * 4.0) * 2.0)
		draw_colored_polygon(PackedVector2Array([tip + Vector2(-5, -7), tip + Vector2(5, -7), tip]), Color(1, 1, 1, 0.9))
