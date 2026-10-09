class_name InputLatch
extends RefCounted
## Ввод по СОБЫТИЯМ, а не по опросу: нажатие запоминается с меткой времени и «защёлкивается» до ближайшего тика
## симуляции. Короткий тап (нажал и отпустил между тиками) не теряется, а задержка «событие → тик» измеряется.
## Физические клавиши (physical_keycode) — раскладка не важна (русская тоже работает).

var left := false
var right := false
var down := false
var jump_held := false
var _edges := 0
var _edge_times: Array[int] = []        # метки времени нажатий, ещё не попавших в тик (мкс)


func handle(event: InputEvent, now_us: int) -> void:
	if event is InputEventKey and not event.echo:
		var pressed: bool = event.pressed
		match event.physical_keycode:
			KEY_A, KEY_LEFT: left = pressed
			KEY_D, KEY_RIGHT: right = pressed
			KEY_S, KEY_DOWN: down = pressed
			KEY_W, KEY_UP, KEY_SPACE:
				jump_held = pressed
				if pressed: _press(Proto.BTN_JUMP, now_us)
			KEY_SHIFT, KEY_K:
				if pressed: _press(Proto.BTN_DASH, now_us)
			KEY_J:
				if pressed: _press(Proto.BTN_LIGHT, now_us)
			KEY_L:
				if pressed: _press(Proto.BTN_HEAVY, now_us)
	elif event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_press(Proto.BTN_LIGHT, now_us)
		elif event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			_press(Proto.BTN_HEAVY, now_us)


func _press(bit: int, now_us: int) -> void:
	_edges |= bit
	_edge_times.append(now_us)


## Команда на текущий тик: [axis, buttons, [метки времени нажатий]]. Одноразовые нажатия очищаются.
func take() -> Array:
	var axis := (127 if right else 0) - (127 if left else 0)
	var buttons := _edges
	if down:
		buttons |= Proto.BTN_DOWN
	if jump_held or (_edges & Proto.BTN_JUMP):
		buttons |= Proto.BTN_JUMP_HELD
	var times := _edge_times
	_edges = 0
	_edge_times = []
	return [axis, buttons, times]


func reset() -> void:
	left = false
	right = false
	down = false
	jump_held = false
	_edges = 0
	_edge_times = []
