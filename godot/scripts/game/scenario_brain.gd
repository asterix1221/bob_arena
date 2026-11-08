class_name ScenarioBrain
extends RefCounted
## Скриптованный «игрок» для воспроизводимых сценариев ПР №4 (T1–T5). Заменяет клавиатуру клиента: бегает по главной
## платформе туда-сюда и жмёт рывок в заранее заданные моменты. Время считается в тиках (120 Гц) от начала раунда.
## Рывок всегда направлен к центру платформы, чтобы не упасть (дальность рывка ≈ 165 px, платформа 340..940 px).
## Чит (scenario "cheat") включается/выключается прямо у клиента: cheat_no_rules — локальный игнор кулдауна и выносливости.

const SECOND := GC.TICK_HZ
const X_LEFT := 540.0
const X_RIGHT := 880.0
const X_CENTER := 640.0

var kind := "dash_latency"
var n := 0                      # тиков раунда у этого бота
var duration_ticks := 0
var done := false
var dash_ticks: Array[int] = [] # когда жать рывок (тики раунда)
var cheat_on_at := -1
var cheat_off_at := -1
var jumps := false
var _dir := 1
var _jump_hold := 0


func _init(scenario_kind: String = "dash_latency") -> void:
	kind = scenario_kind
	match kind:
		"walk":                                    # T1: движение + два рывка, без эмуляции
			duration_ticks = 14 * SECOND
			dash_ticks = [4 * SECOND, 9 * SECOND]
			jumps = true
		"loss_mix":                                # T4: рывки через 3 с, двойной «до кулдауна», прыжки
			duration_ticks = 18 * SECOND
			dash_ticks = [2 * SECOND, 5 * SECOND, 8 * SECOND, 11 * SECOND, 11 * SECOND + 48, 14 * SECOND]
			jumps = true
		"cheat":                                   # T5: честный рывок, затем чит (сервер отклоняет), затем снова честно
			duration_ticks = 16 * SECOND
			dash_ticks = [2 * SECOND, 5 * SECOND, 5 * SECOND + 48, 5 * SECOND + 96, 5 * SECOND + 144, 5 * SECOND + 192, 10 * SECOND, 13 * SECOND]
			cheat_on_at = 5 * SECOND - 10
			cheat_off_at = 7 * SECOND
		_:                                         # T2/T3: пять рывков через 3 с (кулдаун 1.2 с успевает пройти)
			kind = "dash_latency"
			duration_ticks = 17 * SECOND
			dash_ticks = [2 * SECOND, 5 * SECOND, 8 * SECOND, 11 * SECOND, 14 * SECOND]


## [axis, buttons] на текущий тик. Считает тики только пока идёт раунд и персонаж жив.
func think(c: GameClient) -> Array:
	if c.phase != GC.PHASE_PLAYING or not c.state.alive:
		return [0, 0]
	n += 1
	if n >= duration_ticks:
		done = true
		c.cheat_no_rules = false
		return [0, 0]
	if cheat_on_at >= 0 and n == cheat_on_at:
		c.cheat_no_rules = true
	if cheat_off_at >= 0 and n == cheat_off_at:
		c.cheat_no_rules = false
	var x := float(c.state.x) / float(GC.SUB)
	if x > X_RIGHT:
		_dir = -1
	elif x < X_LEFT:
		_dir = 1
	var buttons := 0
	var axis := 127 * _dir
	if dash_ticks.has(n):
		_dir = 1 if x < X_CENTER else -1       # рывок — к центру платформы
		axis = 127 * _dir
		buttons |= Proto.BTN_DASH
	if jumps and n % 150 == 0 and c.state.on_ground:
		buttons |= Proto.BTN_JUMP
		_jump_hold = 24
	if _jump_hold > 0:
		_jump_hold -= 1
		buttons |= Proto.BTN_JUMP_HELD
	return [axis, buttons]
