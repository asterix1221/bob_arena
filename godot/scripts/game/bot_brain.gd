class_name BotBrain
extends RefCounted
## Простой бот-тренер: бежит к ближайшему живому противнику на том же уровне, бьёт в упор, не сходит с края платформы.
## Пользуется только тем, что видит обычный клиент (свои состояние и публичные состояния соперников из снимка).

var n := 0
var enabled := true         # false — бот стоит (для скриншотов/отладки)
var aggression := 14        # раз в сколько тиков пробует ударить (меньше — агрессивнее)


## Возвращает [axis, buttons] на текущий тик.
func think(c: GameClient) -> Array:
	n += 1
	if not enabled:
		return [0, 0]
	var me := c.state
	if not me.alive or c.phase != GC.PHASE_PLAYING:
		return [0, 0]
	var my_x := me.x / float(GC.SUB)
	var my_y := me.y / float(GC.SUB)
	var best := {}
	var best_d := 1e9
	for id in c.pub.keys():
		if id == c.my_id:
			continue
		var e: Dictionary = c.pub[id]
		if int(e["flags"]) & 1 == 0:
			continue
		var d := absf(e["x"] - my_x) + absf(e["y"] - my_y) * 2.0
		if d < best_d:
			best_d = d
			best = e
	if best.is_empty():
		return [0, 0]
	var dx: float = best["x"] - my_x
	var dy: float = best["y"] - my_y
	var axis := 0
	if absf(dy) < 70.0:
		if dx > 28.0: axis = 127
		elif dx < -28.0: axis = -127
	var buttons := 0
	# не сходить с края платформы
	var edge_pad := 22.0
	var ahead := my_x + (1.0 if axis > 0 else -1.0) * edge_pad
	if axis != 0 and me.on_ground:
		var on_platform := false
		for p in GC.PLATFORMS_PX:
			if absf(my_y - p[2]) < 2.0 and ahead >= p[0] and ahead <= p[1]:
				on_platform = true
		if not on_platform:
			axis = 0
	if absf(dx) < 72.0 and absf(dy) < 50.0 and n % aggression == 0:
		buttons |= Proto.BTN_HEAVY if n % (aggression * 4) == 0 else Proto.BTN_LIGHT
	if dy < -60.0 and me.on_ground and n % 90 == 0:
		buttons |= Proto.BTN_JUMP
	if absf(dx) > 200.0 and n % 200 == 0:
		buttons |= Proto.BTN_DASH
	if buttons & Proto.BTN_JUMP:
		buttons |= Proto.BTN_JUMP_HELD
	return [axis, buttons]
