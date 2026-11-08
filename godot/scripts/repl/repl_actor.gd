class_name ReplActor
extends RefCounted
## Реплицируемый актор на сервере. Поля меняются ТОЛЬКО через set_*: изменение помечает поле «грязным»
## (push-модель: репликатору не нужно сравнивать состояние каждого актора с тем, что отправлено клиенту).

var id := 0
var cls := 0
var x := 0.0                # px
var y := 0.0
var vx := 0.0               # px/с
var vy := 0.0
var st := 0                 # u8: флаги (у игрока и бота: бит0 — смотрит вправо, бит1 — движется, бит2 — «вспышка» выстрела)
var hp := 0                 # u8
var dirty := 0              # маска F_* изменённых полей с прошлой раздачи
var can_sleep := false      # статичный класс: кандидат на Net Dormancy
var client_id := -1         # у игрока: номер клиента
var born_tick := 0          # тик мира, когда актор создан

var _sink: Array            # общий список «грязных» id мира (ссылка на массив, не на мир — без циклов ссылок)


func _init(actor_id: int, actor_cls: int, sink: Array) -> void:
	id = actor_id
	cls = actor_cls
	_sink = sink
	can_sleep = ReplDefs.CAN_SLEEP[actor_cls]


func _mark(f: int) -> void:
	if dirty == 0:
		_sink.append(id)
	dirty |= f


func set_pos(nx: float, ny: float) -> void:
	if nx != x:
		x = nx
		_mark(ReplDefs.F_X)
	if ny != y:
		y = ny
		_mark(ReplDefs.F_Y)


func set_vel(nvx: float, nvy: float) -> void:
	if nvx != vx:
		vx = nvx
		_mark(ReplDefs.F_VX)
	if nvy != vy:
		vy = nvy
		_mark(ReplDefs.F_VY)


func set_st(v: int) -> void:
	v &= 0xFF
	if v != st:
		st = v
		_mark(ReplDefs.F_ST)


func set_hp(v: int) -> void:
	v = clampi(v, 0, 255)
	if v != hp:
		hp = v
		_mark(ReplDefs.F_HP)


func clear_dirty() -> void:
	dirty = 0


func facing_right() -> bool:
	return (st & 1) != 0
