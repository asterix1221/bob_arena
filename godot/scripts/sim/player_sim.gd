class_name PlayerSim
extends RefCounted
## Детерминированный шаг симуляции игрока: step(state, cmd) -> событие рывка.
## Это аналог CharacterMovementComponent: клиент вызывает step для предсказания,
## сервер — для авторитетного результата, клиент — снова при повторе команд после коррекции.
##
## Команда (cmd) — это ВВОД, а не результат:
##   { "seq": int, "mx": int, "my": int, "dash": bool }   (mx/my — квантованные оси -127..127)
## Позиции в команде нет и быть не может.

const DT := 1.0 / 60.0
const ARENA := Rect2(0, 0, 1280, 720)
## Статичные препятствия (одинаковы у сервера и клиента). Стена по центру — для «рывка в препятствие».
const WALLS: Array[Rect2] = [
	Rect2(620, 160, 40, 400),
	Rect2(200, 560, 160, 40),
]

const AXIS_MAX := 127


## Квантование ввода: и клиент, и сервер используют ровно одно и то же значение.
static func make_cmd(seq: int, move: Vector2, dash: bool) -> Dictionary:
	var m := move.limit_length(1.0)
	return {"seq": seq, "mx": int(roundf(m.x * AXIS_MAX)), "my": int(roundf(m.y * AXIS_MAX)), "dash": dash}


## Серверная санитизация чужого ввода: ограничить величину, привести к допустимому виду.
static func sanitize_move(cmd: Dictionary) -> Vector2:
	var mx := clampi(int(cmd.get("mx", 0)), -AXIS_MAX, AXIS_MAX)
	var my := clampi(int(cmd.get("my", 0)), -AXIS_MAX, AXIS_MAX)
	return Vector2(mx, my) / float(AXIS_MAX)


## Один тик. dash_allowed_override: если не пусто — клиент в чит-режиме использует свои cfg.
## Возвращает {"started": bool, "rejected": String}.
static func step(state: PlayerState, cmd: Dictionary, cfg: Dictionary) -> Dictionary:
	var result := {"started": false, "rejected": ""}
	var move := sanitize_move(cmd).limit_length(1.0)
	if move.length() > 0.001:
		state.facing = move.normalized()

	# 1. Рывок: намерение приходит флагом, а допустимость и направление решает тот, кто симулирует.
	if bool(cmd.get("dash", false)):
		var why := DashRules.validate(state, cfg)
		if why == DashRules.REASON_NONE:
			var dir := move.normalized() if move.length() > 0.001 else state.facing
			DashRules.begin(state, cfg, dir)
			result["started"] = true
		else:
			result["rejected"] = why

	# 2. Скорость: во время рывка ввод игнорируется.
	var was_dashing := state.dash_left > 0
	var vel: Vector2 = state.dash_dir * cfg["dash_speed"] if was_dashing else move * cfg["walk_speed"]

	# 3. Движение с коллизиями.
	state.pos = _move_and_collide(state.pos + vel * DT, cfg["radius"])

	# 4. Таймеры.
	DashRules.tick_timers(state, cfg, was_dashing)
	return result


static func _move_and_collide(p: Vector2, radius: float) -> Vector2:
	for _i in 2:
		for wall in WALLS:
			var closest := Vector2(clampf(p.x, wall.position.x, wall.end.x), clampf(p.y, wall.position.y, wall.end.y))
			var delta := p - closest
			var dist := delta.length()
			if dist < radius:
				if dist > 0.0001:
					p = closest + delta / dist * radius
				else:
					# центр внутри стены — выталкиваем по наименьшему проникновению
					var left := p.x - wall.position.x
					var right := wall.end.x - p.x
					var up := p.y - wall.position.y
					var down := wall.end.y - p.y
					var m := minf(minf(left, right), minf(up, down))
					if m == left: p.x = wall.position.x - radius
					elif m == right: p.x = wall.end.x + radius
					elif m == up: p.y = wall.position.y - radius
					else: p.y = wall.end.y + radius
	p.x = clampf(p.x, ARENA.position.x + radius, ARENA.end.x - radius)
	p.y = clampf(p.y, ARENA.position.y + radius, ARENA.end.y - radius)
	return p
