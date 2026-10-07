class_name GameHost
extends RefCounted
## Сервер-авторитет (Listen Server: хост играет сам). Принимает НЕДОВЕРЕННЫЕ команды ввода, прогоняет симуляцию,
## разбирает бой и руны, ведёт фазы матча, рассылает снимки (60 Гц, Unreliable) и события (Reliable).
## Позиций от клиентов не принимает вообще: протокол несёт только ввод.

signal event(kind: int, a: int, b: int, x: int, y: int, v: int)
signal roster_changed
signal phase_changed(phase: int)
signal dash_rejected(player_id: int, reason: String)

const MAX_AHEAD := 600          # команды дальше чем на 5 с вперёд — недопустимы (ускорение времени)
const STARVE_GRACE := 6         # тиков ждём опаздывающую команду, потом заполняем «удержанием»
const BACKLOG_FAST := 8         # накопилось больше — исполняем по 2 команды за тик (догоняем)
const SNAPSHOT_EVERY := 2       # тиков между снимками (60 Гц)
const HELD_MASK := Proto.BTN_DOWN | Proto.BTN_JUMP_HELD
const BUTTON_MASK := 63
const LAST_HIT_WINDOW := 360    # 3 с: падение после удара засчитывается ударившему

var net: NetNode
var phase := GC.PHASE_LOBBY
var tick := 0
var seed_value := 1
var rune_interval := GC.RUNE_SPAWN_INTERVAL
var allow_solo := false         # для тестов и тренировки: раунд не заканчивается при одном игроке

var slots := {}                 # id -> Slot
var runes: Array = []           # {id,type,x,y} в u
var round_ticks := 0
var countdown_left := 0
var winner := GC.NO_PLAYER
var started_with := 0

var _next_rune_id := 1
var _next_event_id := 1
var _rng := RandomNumberGenerator.new()
var _players_state := {}        # id -> PState (живые ссылки на состояние слотов)
var _last_hit := {}
var _stats := {}
var _closing := {}              # peer -> тик, когда убрать (отказ во входе: даём доставить Welcome)


class Slot extends RefCounted:
	var id: int
	var peer := -1                       # -1 — локальный игрок хоста
	var name := PackedByteArray()
	var color := 0
	var ready := false
	var state := PState.new()
	var cmds := {}                       # seq -> [axis, buttons]
	var seq_init := false
	var next_seq := 1
	var high := 0
	var starve := 0
	var last_axis := 0
	var last_held := 0
	var last_exec := 0                   # номер последней исполненной команды (ack в снимке)
	var gap_fills := 0
	var dups := 0
	var late := 0
	var bad_inputs := 0
	var dash_rejects := 0
	var alive_before := true


func _init(network: NetNode, seed_val: int = 1) -> void:
	net = network
	net.accept_new_peers = true
	seed_value = seed_val
	_rng.seed = seed_val
	net.message.connect(_on_message)
	net.peer_lost.connect(_on_peer_lost)


# ------------------------------------------------------------------ вход/выход игроков

func add_local_player(player_name: String, color: int) -> int:
	var s := _new_slot(-1, player_name.to_utf8_buffer(), color)
	roster_changed.emit()
	_send_roster()
	return s.id


func _free_id() -> int:
	for i in GC.MAX_PLAYERS:
		if not slots.has(i):
			return i
	return -1


func _new_slot(peer: int, name_utf8: PackedByteArray, color: int) -> Slot:
	var s := Slot.new()
	s.id = _free_id()
	s.peer = peer
	s.name = name_utf8.slice(0, Proto.MAX_NAME_BYTES)
	if s.name.is_empty():
		s.name = ("Игрок %d" % (s.id + 1)).to_utf8_buffer()
	var used := {}
	for o in slots.values():
		used[o.color] = true
	s.color = color if (color >= 0 and color < GC.COLORS.size() and not used.has(color)) else _first_free_color(used)
	s.state = PState.spawn(s.id)
	slots[s.id] = s
	return s


func _first_free_color(used: Dictionary) -> int:
	for c in GC.COLORS.size():
		if not used.has(c):
			return c
	return 0


func slot_of_peer(peer: int) -> Slot:
	for s in slots.values():
		if s.peer == peer:
			return s
	return null


func _on_message(peer: int, msg: Dictionary) -> void:
	match int(msg["type"]):
		Proto.T_HELLO:
			_on_hello(peer, msg)
		Proto.T_INPUT:
			var s := slot_of_peer(peer)
			if s != null:
				on_input(s, int(msg["first"]), msg["cmds"])
		Proto.T_LEAVE:
			var s2 := slot_of_peer(peer)
			if s2 != null:
				_remove_slot(s2, "left")
			net.remove_peer(peer, "left")


func _on_hello(peer: int, msg: Dictionary) -> void:
	var existing := slot_of_peer(peer)
	if existing != null:      # повторный Hello (потерялся Welcome) — отвечаем ещё раз тем же
		_send_welcome(peer, Proto.WELCOME_OK, existing.id)
		return
	var status := Proto.WELCOME_OK
	if int(msg["proto"]) != Proto.GAME_PROTO:
		status = Proto.WELCOME_BAD_VERSION
	elif phase != GC.PHASE_LOBBY or _free_id() < 0:
		status = Proto.WELCOME_FULL
	if status != Proto.WELCOME_OK:
		_send_welcome(peer, status, 0)
		_closing[peer] = tick + 240
		return
	var s := _new_slot(peer, msg["name"], int(msg["color"]))
	_send_welcome(peer, Proto.WELCOME_OK, s.id)
	_emit(GC.EV_JOINED, s.id, s.color, 0, 0, 0)
	roster_changed.emit()
	_send_roster()


func _send_welcome(peer: int, status: int, id: int) -> void:
	var t := tick & 0xFFFF
	var sd := seed_value
	net.send(peer, func(q: int) -> PackedByteArray:
		return Proto.welcome(q, status, Proto.GAME_PROTO, id, t, GC.TICK_HZ, sd), true)


func _on_peer_lost(peer: int, _reason: String) -> void:
	var s := slot_of_peer(peer)
	if s != null:
		_remove_slot(s, "lost")


func _remove_slot(s: Slot, _why: String) -> void:
	slots.erase(s.id)
	_players_state.erase(s.id)
	if phase == GC.PHASE_PLAYING or phase == GC.PHASE_COUNTDOWN:
		_stats.erase(s.id)
	_emit(GC.EV_LEFT, s.id, 0, 0, 0, 0)
	roster_changed.emit()
	_send_roster()


func roster_entries() -> Array:
	var out := []
	var ids: Array = slots.keys()
	ids.sort()
	for id in ids:
		var s: Slot = slots[id]
		out.append([s.id, s.color, (1 if s.peer == -1 else 0) | (2 if s.ready else 0), s.name])
	return out


func _send_roster() -> void:
	var entries := roster_entries()
	net.broadcast(func(q: int) -> PackedByteArray: return Proto.roster(q, entries), true)


# ------------------------------------------------------------------ ввод

## Принимает пачку команд [first, first+1, ...]. Любые значения санитизируются; дубликаты и опоздавшие игнорируются.
func on_input(s: Slot, first16: int, cmds: Array) -> void:
	if not s.seq_init:
		s.seq_init = true
		s.next_seq = first16
		s.high = first16 - 1
	for i in cmds.size():
		var seq := SeqUtil.unwrap16(first16 + i, s.high)
		if seq < s.next_seq:
			s.dups += 1               # обычная избыточность: эту команду уже исполнили
			continue
		if seq > s.next_seq + MAX_AHEAD:
			s.bad_inputs += 1
			continue
		if s.cmds.has(seq):
			continue
		var axis := clampi(int(cmds[i][0]), -127, 127)
		s.cmds[seq] = [axis, int(cmds[i][1]) & BUTTON_MASK]
		s.high = maxi(s.high, seq)


## Локальный игрок хоста: одна команда за тик, без сети.
func host_input(player_id: int, axis: int, buttons: int) -> void:
	if not slots.has(player_id):
		return
	var s: Slot = slots[player_id]
	if not s.seq_init:
		s.seq_init = true
		s.next_seq = 1
		s.high = 0
	s.high += 1
	s.cmds[s.high] = [clampi(axis, -127, 127), buttons & BUTTON_MASK]


# ------------------------------------------------------------------ матч

func start_match() -> bool:
	if phase != GC.PHASE_LOBBY or (slots.size() < 2 and not allow_solo) or slots.is_empty():
		return false
	_set_phase(GC.PHASE_COUNTDOWN)
	countdown_left = GC.COUNTDOWN_TICKS
	runes.clear()
	_last_hit.clear()
	_stats.clear()
	winner = GC.NO_PLAYER
	var ids: Array = slots.keys()
	ids.sort()
	var slot_index := 0
	for id in ids:
		var s: Slot = slots[id]
		s.state = PState.spawn(slot_index)
		s.alive_before = true
		_stats[id] = {"damage": 0, "kills": 0, "died_tick": -1}
		slot_index += 1
	started_with = slots.size()
	round_ticks = 0
	_next_rune_id = 1
	return true


func rematch() -> void:
	if phase == GC.PHASE_ENDED:
		_set_phase(GC.PHASE_LOBBY)
		for s in slots.values():
			s.state = PState.spawn(s.id)
		_emit(GC.EV_LOBBY, 0, 0, 0, 0, 0)


func _set_phase(p: int) -> void:
	if phase != p:
		phase = p
		phase_changed.emit(p)


func _emit(kind: int, a: int, b: int, x: int, y: int, v: int) -> void:
	var id := _next_event_id & 0xFFFF
	_next_event_id += 1
	var t := tick & 0xFFFF
	net.broadcast(func(q: int) -> PackedByteArray:
		return Proto.game_event(q, id, kind, t, a, b, clampi(x, -32768, 32767), clampi(y, -32768, 32767), clampi(v, -32768, 32767)), true)
	event.emit(kind, a, b, x, y, v)


# ------------------------------------------------------------------ тик (вызывать 120 раз в секунду)

func tick_once() -> void:
	net.process()
	tick += 1
	for peer in _closing.keys():
		if tick >= int(_closing[peer]):
			_closing.erase(peer)
			net.remove_peer(peer, "rejected")
	_players_state.clear()
	var ids: Array = slots.keys()
	ids.sort()
	for id in ids:
		var s: Slot = slots[id]
		_players_state[id] = s.state
	# 1. исполнение команд игроков
	for id in ids:
		_consume(slots[id])
	# 2. фазы
	match phase:
		GC.PHASE_COUNTDOWN:
			_tick_countdown()
		GC.PHASE_PLAYING:
			_tick_playing()
	# 3. снимки
	if phase != GC.PHASE_LOBBY and tick % SNAPSHOT_EVERY == 0:
		_send_snapshots()


func _consume(s: Slot) -> void:
	if not s.seq_init:
		return
	var runs := 1
	if s.high - s.next_seq + 1 > BACKLOG_FAST:
		runs = 2
	for r in runs:
		var cmd: Array
		if s.cmds.has(s.next_seq):
			cmd = s.cmds[s.next_seq]
			s.cmds.erase(s.next_seq)
			s.starve = 0
		elif s.high >= s.next_seq:
			# дыра: следующие команды уже есть, а этой нет — восполняем «удержанием» без одноразовых нажатий
			cmd = [s.last_axis, s.last_held]
			s.gap_fills += 1
		else:
			s.starve += 1
			if s.starve <= STARVE_GRACE:
				return
			cmd = [s.last_axis, s.last_held]      # ждали достаточно: идём дальше, опоздавшая команда будет отброшена
			s.gap_fills += 1
		s.next_seq += 1
		s.last_exec = s.next_seq - 1
		s.last_axis = int(cmd[0])
		s.last_held = int(cmd[1]) & HELD_MASK
		if phase == GC.PHASE_PLAYING and s.state.alive:
			var reason := PlatSim.step(s.state, int(cmd[0]), int(cmd[1]))
			if reason != "":
				s.dash_rejects += 1
				dash_rejected.emit(s.id, reason)


func _tick_countdown() -> void:
	if countdown_left % GC.TICK_HZ == 0 and countdown_left > 0:
		_emit(GC.EV_COUNTDOWN, 0, 0, 0, 0, countdown_left / GC.TICK_HZ)
	countdown_left -= 1
	if countdown_left <= 0:
		_set_phase(GC.PHASE_PLAYING)
		round_ticks = 0
		_emit(GC.EV_ROUND_START, 0, 0, 0, 0, 0)


func _tick_playing() -> void:
	round_ticks += 1
	var events: Array = Combat.resolve_hits(_players_state, tick, _last_hit, _stats)
	events.append_array(Combat.resolve_pickups(_players_state, runes))
	# падения (смерть из PlatSim.step) — засчитываем убийство, если недавно били
	for id in _players_state.keys():
		var st: PState = _players_state[id]
		var s: Slot = slots[id]
		if s.alive_before and not st.alive:
			if not _was_death_reported(events, id):
				var killer := GC.NO_PLAYER
				if _last_hit.has(id) and tick - int(_last_hit[id]["tick"]) <= LAST_HIT_WINDOW:
					killer = int(_last_hit[id]["by"])
					if _stats.has(killer):
						_stats[killer]["kills"] += 1
				events.append({"kind": GC.EV_DEATH, "a": id, "b": killer, "x": st.x / GC.SUB, "y": mini(st.y / GC.SUB, 880), "v": 1})
		s.alive_before = st.alive
	for e in events:
		if e["kind"] == GC.EV_DEATH and _stats.has(int(e["a"])):
			_stats[int(e["a"])]["died_tick"] = round_ticks
		_emit(int(e["kind"]), int(e["a"]), int(e["b"]), int(e["x"]), int(e["y"]), int(e["v"]))
	# руны
	if rune_interval > 0 and round_ticks % rune_interval == 0:
		_spawn_rune()
	# конец раунда
	var alive: Array = []
	for id in _players_state.keys():
		if _players_state[id].alive:
			alive.append(id)
	if started_with >= 2 and alive.size() <= 1:
		_end_round(alive[0] if alive.size() == 1 else GC.NO_PLAYER)


func _was_death_reported(events: Array, id: int) -> bool:
	for e in events:
		if e["kind"] == GC.EV_DEATH and int(e["a"]) == id:
			return true
	return false


func _end_round(win: int) -> void:
	winner = win
	_set_phase(GC.PHASE_ENDED)
	_emit(GC.EV_ROUND_END, win, 0, 0, 0, 0)
	var ids: Array = slots.keys()
	ids.sort()
	for id in ids:
		var st: Dictionary = _stats.get(id, {"damage": 0, "kills": 0, "died_tick": -1})
		var life := int(st["died_tick"]) if int(st["died_tick"]) >= 0 else round_ticks
		_emit(GC.EV_STATS, id, int(st["kills"]), life / GC.TICK_HZ, 1 if int(st["died_tick"]) >= 0 else 0, int(st["damage"]))


func _spawn_rune() -> void:
	if runes.size() >= GC.MAX_RUNES_ON_GROUND:
		return
	var plats: Array = GC.platforms_u()
	var p: Array = plats[_rng.randi() % plats.size()]
	var margin := 40 * GC.SUB
	var x := _rng.randi_range(p[0] + margin, p[1] - margin)
	var rune_type := _rng.randi() % GC.NUM_RUNES
	runes.append({"id": _next_rune_id, "type": rune_type, "x": x, "y": p[2]})
	_next_rune_id = (_next_rune_id % 255) + 1


func _send_snapshots() -> void:
	var entries := []
	var ids: Array = slots.keys()
	ids.sort()
	for id in ids:
		var st: PState = slots[id].state
		entries.append([id, clampi(st.x / 16, -32768, 32767), clampi(st.y / 16, -32768, 32767),
			clampi(st.vx, -32768, 32767), clampi(st.vy, -32768, 32767), st.hp, st.flag_byte(), st.buff_mask()])
	var rune_entries := []
	for r in runes:
		rune_entries.append([r["id"], r["type"], clampi(r["x"] / 16, -32768, 32767), clampi(r["y"] / 16, -32768, 32767)])
	var t := tick & 0xFFFF
	for s in slots.values():
		if s.peer < 0:
			continue
		var owner := PackedByteArray()
		Wire.w_u8(owner, phase)
		owner.append_array(s.state.to_bytes())
		var ack: int = s.last_exec & 0xFFFF
		net.send(s.peer, func(q: int) -> PackedByteArray:
			return Proto.snapshot(q, t, ack, entries, owner, rune_entries), false)
