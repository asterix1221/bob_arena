class_name ReplWorld
extends RefCounted
## Сервер-авторитетный мир-нагрузка для ПР №5: длинный уровень платформера (16000 px) с большим числом акторов.
## Симуляция (60 Гц) НЕ зависит от репликации — поэтому до/после оптимизации мир проходит ровно один и тот же путь
## (проверяется контрольной суммой), а разница в трафике — результат только сетевых настроек.
##   деревья 40 (декор, статика), предметы 12 (статика до подбора), боты 8 (патруль, стреляют), облака 8 (фон, плывут),
##   снаряды (появляются и исчезают), игроки (аватары клиентов) — итого ≥ 68 акторов на старте.

signal actor_spawned(a: ReplActor)
signal actor_removed(a: ReplActor)

const PLAYER_BASE := 1          # id игрока = 1 + номер клиента
const TREE_BASE := 100
const PICKUP_BASE := 200
const BOT_BASE := 300
const CLOUD_BASE := 400
const PROJ_BASE := 1000
const PROJ_MAX := 60000

const N_TREES := 40
const N_PICKUPS := 12
const N_BOTS := 8
const N_CLOUDS := 8

const DT := 1.0 / 60.0
const PLAYER_SPEED := 260.0
const SHOT_COOLDOWN := 20
const PROJ_SPEED := 320.0
const PROJ_LIFE := 90
const PROJ_Y_OFFSET := 30.0
const BOT_RANGE := 150.0
const BOT_SIGHT := 700.0
const BOT_FIRE_EVERY := 150
const BOT_FLASH := 10
const PICKUP_RESPAWN := 900
const PICKUP_REACH := 28.0
const TREE_HIT_REACH := 16.0
const BOT_HIT_REACH := 20.0

const BTN_SHOOT := 4            # та же кнопка «лёгкий удар», что и в игре (Proto.BTN_LIGHT)

var actors := {}                # id -> ReplActor
var dirty_ids: Array = []       # id актёров с ненулевой маской dirty (заполняют сами акторы)
var tick := 0
var seed_value := 1
var shots := 0
var tree_hits := 0
var bot_hits := 0
var pickups_taken := 0

var _rng := RandomNumberGenerator.new()
var _tree_ids: Array = []
var _pickup_ids: Array = []
var _bot_ids: Array = []
var _cloud_ids: Array = []
var _proj_ids: Array = []
var _players := {}              # client_id -> actor id
var _inputs := {}               # client_id -> [axis, buttons]
var _shot_cd := {}              # client_id -> тиков до следующего выстрела
var _bot_anchor := {}
var _bot_speed := {}
var _bot_fire_at := {}
var _bot_flash_until := {}
var _pickup_back := {}
var _proj_die := {}
var _proj_owner := {}           # id снаряда -> класс стрелка
var _next_proj := PROJ_BASE


func _init(seed_val: int = 1) -> void:
	seed_value = seed_val
	_rng.seed = seed_val


# ------------------------------------------------------------------ создание уровня

func build_level() -> void:
	var W := ReplDefs.WORLD_W_PX
	var G := ReplDefs.GROUND_Y_PX
	for i in N_TREES:
		var a := _spawn(TREE_BASE + i, ReplDefs.C_TREE, (float(i) + 0.5) * W / N_TREES + _rng.randf_range(-80.0, 80.0), G)
		a.st = _rng.randi() % 4         # вид дерева
		a.hp = 100
		_tree_ids.append(a.id)
	for i in N_PICKUPS:
		var a := _spawn(PICKUP_BASE + i, ReplDefs.C_PICKUP, (float(i) + 0.5) * W / N_PICKUPS, G - 40.0)
		a.st = 0                        # 0 — лежит, 1 — подобран
		_pickup_ids.append(a.id)
	for i in N_BOTS:
		var a := _spawn(BOT_BASE + i, ReplDefs.C_BOT, (float(i) + 0.5) * W / N_BOTS, G)
		var sp := 70.0 + 10.0 * float(i % 4)
		a.vx = sp
		a.st = 1 | 2
		a.hp = 50
		_bot_anchor[a.id] = a.x
		_bot_speed[a.id] = sp
		_bot_fire_at[a.id] = 60 + 17 * i
		_bot_ids.append(a.id)
	for i in N_CLOUDS:
		var a := _spawn(CLOUD_BASE + i, ReplDefs.C_CLOUD, (float(i) + 0.5) * W / N_CLOUDS, 80.0 + 30.0 * float(i % 5))
		a.vx = 5.0 + 1.0 * float(i % 4)
		a.st = i % 3
		_cloud_ids.append(a.id)


func _spawn(id: int, cls: int, x: float, y: float) -> ReplActor:
	var a := ReplActor.new(id, cls, dirty_ids)
	a.x = x
	a.y = y
	a.born_tick = tick
	actors[id] = a
	actor_spawned.emit(a)
	return a


func remove_actor(id: int) -> void:
	if not actors.has(id):
		return
	var a: ReplActor = actors[id]
	actors.erase(id)
	actor_removed.emit(a)


# ------------------------------------------------------------------ игроки

func add_player(client_id: int, spawn_x: float) -> ReplActor:
	var a := _spawn(PLAYER_BASE + client_id, ReplDefs.C_PLAYER, spawn_x, ReplDefs.GROUND_Y_PX)
	a.client_id = client_id
	a.hp = 100
	a.st = 1
	_players[client_id] = a.id
	_inputs[client_id] = [0, 0]
	_shot_cd[client_id] = 0
	return a


func remove_player(client_id: int) -> void:
	if _players.has(client_id):
		var id: int = _players[client_id]
		_players.erase(client_id)
		_inputs.erase(client_id)
		_shot_cd.erase(client_id)
		remove_actor(id)


func set_input(client_id: int, axis: int, buttons: int) -> void:
	if _players.has(client_id):
		_inputs[client_id] = [clampi(axis, -127, 127), buttons]


func player_actor_ids() -> Array:
	var ids: Array = _players.values()
	ids.sort()
	return ids


func player_ids() -> Array:
	var ids: Array = _players.keys()
	ids.sort()
	return ids


## Всего акторов, из них «уровень» (без игроков и снарядов).
func count() -> int:
	return actors.size()


# ------------------------------------------------------------------ шаг симуляции (60 Гц)

func step() -> void:
	tick += 1
	_step_players()
	_step_bots()
	_step_clouds()
	_step_projectiles()
	_step_pickups()


func _step_players() -> void:
	for cid in player_ids():
		var a: ReplActor = actors[_players[cid]]
		var inp: Array = _inputs[cid]
		var axis: int = inp[0]
		var vx := float(axis) / 127.0 * PLAYER_SPEED
		var nx := clampf(a.x + vx * DT, 0.0, ReplDefs.WORLD_W_PX)
		a.set_pos(nx, a.y)
		a.set_vel(vx, 0.0)
		var right := a.facing_right()
		if axis > 0:
			right = true
		elif axis < 0:
			right = false
		a.set_st((1 if right else 0) | (2 if axis != 0 else 0))
		var cd: int = _shot_cd[cid]
		if cd > 0:
			_shot_cd[cid] = cd - 1
		elif (int(inp[1]) & BTN_SHOOT) != 0:
			_spawn_projectile(a.x, a.y - PROJ_Y_OFFSET, 1.0 if right else -1.0, ReplDefs.C_PLAYER)
			_shot_cd[cid] = SHOT_COOLDOWN


func _step_bots() -> void:
	for id in _bot_ids:
		var a: ReplActor = actors[id]
		var anchor: float = _bot_anchor[id]
		var nx := a.x + a.vx * DT
		if nx > anchor + BOT_RANGE or nx < anchor - BOT_RANGE:
			nx = clampf(nx, anchor - BOT_RANGE, anchor + BOT_RANGE)
			a.set_vel(-a.vx, 0.0)
			a.set_st((a.st & 4) | 2 | (1 if a.vx > 0.0 else 0))
		a.set_pos(nx, a.y)
		if _bot_flash_until.has(id) and tick >= int(_bot_flash_until[id]):
			_bot_flash_until.erase(id)
			a.set_st(a.st & ~4)
		if tick >= int(_bot_fire_at[id]):
			var target := _nearest_player_x(a.x, BOT_SIGHT)
			if target < -1.0:
				_bot_fire_at[id] = tick + 30
			else:
				_spawn_projectile(a.x, a.y - PROJ_Y_OFFSET, 1.0 if target >= a.x else -1.0, ReplDefs.C_BOT)
				a.set_st(a.st | 4)
				_bot_flash_until[id] = tick + BOT_FLASH
				_bot_fire_at[id] = tick + BOT_FIRE_EVERY


## x ближайшего игрока в радиусе sight (по X) или -2 — если никого.
func _nearest_player_x(x: float, sight: float) -> float:
	var best := -2.0
	var best_d := sight + 1.0
	for pid in player_actor_ids():
		var p: ReplActor = actors[pid]
		var d := absf(p.x - x)
		if d <= sight and d < best_d:
			best_d = d
			best = p.x
	return best


func _step_clouds() -> void:
	for id in _cloud_ids:
		var a: ReplActor = actors[id]
		var nx := a.x + a.vx * DT
		if nx > ReplDefs.WORLD_W_PX:
			nx = 0.0
		a.set_pos(nx, a.y)


func _spawn_projectile(x: float, y: float, dir: float, owner_cls: int) -> void:
	var id := _next_proj
	var guard := 0
	while actors.has(id) and guard < 100:
		id += 1
		guard += 1
	_next_proj = id + 1 if id + 1 < PROJ_MAX else PROJ_BASE
	var a := _spawn(id, ReplDefs.C_PROJ, x, y)
	a.vx = PROJ_SPEED * dir
	a.st = 0 if owner_cls == ReplDefs.C_BOT else 1
	_proj_die[id] = tick + PROJ_LIFE
	_proj_owner[id] = owner_cls
	_proj_ids.append(id)
	shots += 1


func _step_projectiles() -> void:
	var gone: Array = []
	for id in _proj_ids:
		var a: ReplActor = actors[id]
		a.set_pos(a.x + a.vx * DT, a.y)
		var dead := tick >= int(_proj_die[id]) or a.x < 0.0 or a.x > ReplDefs.WORLD_W_PX
		if not dead:
			dead = _projectile_hits(a)
		if dead:
			gone.append(id)
	for id in gone:
		_proj_ids.erase(id)
		_proj_die.erase(id)
		_proj_owner.erase(id)
		remove_actor(id)


func _projectile_hits(p: ReplActor) -> bool:
	for tid in _tree_ids:
		var t: ReplActor = actors[tid]
		if absf(t.x - p.x) < TREE_HIT_REACH:
			t.set_hp(t.hp - 25 if t.hp > 25 else 100)      # срубили — на месте вырос новый
			tree_hits += 1
			return true
	if int(_proj_owner[p.id]) == ReplDefs.C_PLAYER:
		for bid in _bot_ids:
			var b: ReplActor = actors[bid]
			if absf(b.x - p.x) < BOT_HIT_REACH:
				b.set_hp(b.hp - 10 if b.hp > 10 else 50)
				bot_hits += 1
				return true
	return false


func _step_pickups() -> void:
	for id in _pickup_ids:
		var a: ReplActor = actors[id]
		if a.st == 0:
			for pid in player_actor_ids():
				var p: ReplActor = actors[pid]
				if absf(p.x - a.x) < PICKUP_REACH:
					a.set_st(1)
					_pickup_back[id] = tick + PICKUP_RESPAWN
					pickups_taken += 1
					break
		elif tick >= int(_pickup_back[id]):
			a.set_st(0)


# ------------------------------------------------------------------ проверка идентичности прогонов

func checksum() -> int:
	var ids: Array = actors.keys()
	ids.sort()
	var h := 7
	for id in ids:
		var a: ReplActor = actors[id]
		h = hash([h, id, roundi(a.x * 64.0), roundi(a.y * 64.0), roundi(a.vx * 64.0), roundi(a.vy * 64.0), a.st, a.hp])
	return h
