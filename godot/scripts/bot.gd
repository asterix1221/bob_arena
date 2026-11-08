class_name Bot
extends RefCounted
## Скриптованный «игрок» для автоматических прогонов (--bot=<сценарий>): по номеру тика отдаёт
## ввод и командами включает/выключает клиентский чит. Нужен, чтобы T1–T5 воспроизводились
## без ручного управления и давали сравнимые числа.

var scenario := "walk"
var _phases: Array = []      # [from_tick, to_tick, Vector2]
var _dashes: Array = []      # тики нажатия рывка
var _cheats: Array = []      # [tick, ignore_rules, speed_scale]
var duration_ticks := 600


func _init(name: String = "walk") -> void:
	scenario = name
	match name:
		"walk":              # T1: только перемещение (+ один рывок)
			_phases = [[60, 150, Vector2.RIGHT], [150, 210, Vector2.DOWN], [210, 300, Vector2.LEFT], [300, 360, Vector2.UP]]
			_dashes = [200]
			duration_ticks = 420
		"dash_latency":      # T2/T3: три одиночных рывка с большими паузами — чистое измерение отклика
			_phases = [[40, 100, Vector2.RIGHT], [100, 200, Vector2.LEFT], [290, 350, Vector2.RIGHT], [350, 520, Vector2.LEFT], [560, 640, Vector2.DOWN]]
			_dashes = [60, 300, 600]
			duration_ticks = 800
		"loss_mix":          # T4: движение + рывки, в том числе «до кулдауна» (сервер должен отказать)
			_phases = [[30, 120, Vector2(1, 1)], [120, 260, Vector2(-1, 0)], [260, 400, Vector2(0, -1)], [400, 540, Vector2(1, 0.3)], [540, 700, Vector2(-1, 0.5)], [700, 840, Vector2(0, -1)]]
			_dashes = [60, 90, 300, 320, 520, 700, 730, 800]
			duration_ticks = 960
		"cheat":             # T5: намеренное расхождение
			_phases = [[30, 400, Vector2(1, 0.15)], [400, 800, Vector2(-1, 0.1)]]
			_dashes = [60, 90, 220, 420, 600]
			_cheats = [[55, true, 1.0], [200, true, 3.0], [400, false, 1.0]]
			duration_ticks = 800
		"wall":              # рывок у препятствия (расхождения быть не должно)
			_phases = [[30, 220, Vector2.RIGHT]]
			_dashes = [110, 200]
			duration_ticks = 300
		_:
			push_warning("unknown bot scenario: %s" % name)


func sample(tick: int) -> Dictionary:
	var move := Vector2.ZERO
	for ph in _phases:
		if tick >= ph[0] and tick < ph[1]:
			move = ph[2]
	var cheat = null
	for c in _cheats:
		if c[0] == tick:
			cheat = {"ignore": c[1], "speed": c[2]}
	return {"move": move, "dash": tick in _dashes, "cheat": cheat, "done": tick >= duration_ticks}
