class_name Proto
extends RefCounted
## Порт формата пакетов из protocol/protocol.{h,cpp} (ПР №2-3 + игровые типы).
## Заголовок 8 байт: type u8 | seq u16 | payloadSize u16 | version u16 | requiresAck u8.
## Правила разбора такие же строгие, как в C++ (совпадение проверяется golden_vectors.json):
## любой неверный пакет -> пустой Dictionary ({}), успешный -> Dictionary с полем "type".

const HEADER_SIZE := 8
const VERSION := 2
const GAME_PROTO := 1

const T_PING := 1
const T_PONG := 2
const T_MOVEMENT := 3
const T_SHOOT := 4
const T_ACK := 5
const T_HELLO := 6
const T_WELCOME := 7
const T_INPUT := 8
const T_SNAPSHOT := 9
const T_GAME_EVENT := 10
const T_LEAVE := 11
const T_ROSTER := 12
const T_WORLD_UPDATE := 13      # ПР №5: непрерывное состояние мировых акторов (Unreliable), см. ReplCodec
const T_WORLD_RELIABLE := 14    # ПР №5: появление/полное состояние/удаление акторов (Reliable)

const MAX_NAME_BYTES := 16
const MAX_INPUT_CMDS := 16
const MAX_SNAPSHOT_PLAYERS := 8
const MAX_SNAPSHOT_RUNES := 8
const MAX_OWNER_STATE := 96
const GAME_EVENT_PAYLOAD := 13
const MAX_ROSTER := 8

const BTN_JUMP := 1
const BTN_DASH := 2
const BTN_LIGHT := 4
const BTN_HEAVY := 8
const BTN_DOWN := 16
const BTN_JUMP_HELD := 32

const WELCOME_OK := 0
const WELCOME_FULL := 1
const WELCOME_BAD_VERSION := 2


static func _header(type: int, seq: int, payload_size: int, requires_ack: bool) -> PackedByteArray:
	var b := PackedByteArray()
	Wire.w_u8(b, type)
	Wire.w_u16(b, seq)
	Wire.w_u16(b, payload_size)
	Wire.w_u16(b, VERSION)
	Wire.w_u8(b, 1 if requires_ack else 0)
	return b


## Читает и проверяет заголовок. {} если данных мало, тип неизвестен, версия чужая, флаг не 0/1.
static func read_header(d: PackedByteArray) -> Dictionary:
	if d.size() < HEADER_SIZE:
		return {}
	var r := Wire.Reader.new(d)
	var type := r.u8()
	var seq := r.u16()
	var psize := r.u16()
	var version := r.u16()
	var ra := r.u8()
	if type < T_PING or type > T_WORLD_RELIABLE or version != VERSION or ra > 1:
		return {}
	return {"type": type, "seq": seq, "payload_size": psize, "requires_ack": ra == 1}


## Общая проверка: тип и requiresAck строго как у типа, payloadSize == фактическому хвосту.
static func _check(d: PackedByteArray, type: int, requires_ack: bool) -> Dictionary:
	var h := read_header(d)
	if h.is_empty() or h["type"] != type or h["requires_ack"] != requires_ack:
		return {}
	if d.size() != HEADER_SIZE + int(h["payload_size"]):
		return {}
	return h


# ------------------------------------------------------------------ ПР №2-3

static func ping(seq: int, client_send_us: int) -> PackedByteArray:
	var b := _header(T_PING, seq, 8, false)
	Wire.w_u64(b, client_send_us)
	return b


static func pong(seq: int, t_client: int, t_srv_rx: int, t_srv_tx: int) -> PackedByteArray:
	var b := _header(T_PONG, seq, 24, false)
	Wire.w_u64(b, t_client)
	Wire.w_u64(b, t_srv_rx)
	Wire.w_u64(b, t_srv_tx)
	return b


static func movement(seq: int, x: int, y: int, ack: bool = false) -> PackedByteArray:
	var b := _header(T_MOVEMENT, seq, 4, ack)
	Wire.w_u16(b, x)
	Wire.w_u16(b, y)
	return b


static func shoot(seq: int, angle: int, weapon: int, ack: bool = true) -> PackedByteArray:
	var b := _header(T_SHOOT, seq, 3, ack)
	Wire.w_u16(b, angle)
	Wire.w_u8(b, weapon)
	return b


static func ack(seq: int, acked: int) -> PackedByteArray:
	var b := _header(T_ACK, seq, 2, false)
	Wire.w_u16(b, acked)
	return b


static func parse_ping(d: PackedByteArray) -> Dictionary:
	var h := _check(d, T_PING, false)
	if h.is_empty() or h["payload_size"] != 8:
		return {}
	var r := Wire.Reader.new(d, HEADER_SIZE)
	var t := r.u64()
	return h.merged({"t_client": t}) if r.ok and r.left() == 0 else {}


static func parse_pong(d: PackedByteArray) -> Dictionary:
	var h := _check(d, T_PONG, false)
	if h.is_empty() or h["payload_size"] != 24:
		return {}
	var r := Wire.Reader.new(d, HEADER_SIZE)
	var a := r.u64()
	var b := r.u64()
	var c := r.u64()
	return h.merged({"t_client": a, "t_srv_rx": b, "t_srv_tx": c}) if r.ok and r.left() == 0 else {}


static func parse_ack(d: PackedByteArray) -> Dictionary:
	var h := _check(d, T_ACK, false)
	if h.is_empty() or h["payload_size"] != 2:
		return {}
	var r := Wire.Reader.new(d, HEADER_SIZE)
	var a := r.u16()
	return h.merged({"acked": a}) if r.ok and r.left() == 0 else {}


# ------------------------------------------------------------------ игровые пакеты

static func hello(seq: int, game_proto: int, color: int, name_utf8: PackedByteArray) -> PackedByteArray:
	var n := mini(name_utf8.size(), MAX_NAME_BYTES)
	var b := _header(T_HELLO, seq, 3 + n, true)
	Wire.w_u8(b, game_proto)
	Wire.w_u8(b, color)
	Wire.w_u8(b, n)
	b.append_array(name_utf8.slice(0, n))
	return b


static func parse_hello(d: PackedByteArray) -> Dictionary:
	var h := _check(d, T_HELLO, true)
	if h.is_empty():
		return {}
	var r := Wire.Reader.new(d, HEADER_SIZE)
	var proto := r.u8()
	var color := r.u8()
	var n := r.u8()
	if not r.ok or n > MAX_NAME_BYTES or r.left() != n:
		return {}
	return h.merged({"proto": proto, "color": color, "name": r.bytes(n)})


static func welcome(seq: int, status: int, game_proto: int, player_id: int, tick: int, rate: int, seed_value: int) -> PackedByteArray:
	var b := _header(T_WELCOME, seq, 10, true)
	Wire.w_u8(b, status)
	Wire.w_u8(b, game_proto)
	Wire.w_u8(b, player_id)
	Wire.w_u16(b, tick)
	Wire.w_u8(b, rate)
	Wire.w_u32(b, seed_value)
	return b


static func parse_welcome(d: PackedByteArray) -> Dictionary:
	var h := _check(d, T_WELCOME, true)
	if h.is_empty():
		return {}
	var r := Wire.Reader.new(d, HEADER_SIZE)
	var out := {"status": r.u8(), "proto": r.u8(), "id": r.u8(), "tick": r.u16(), "rate": r.u8(), "seed": r.u32()}
	return h.merged(out) if r.ok and r.left() == 0 else {}


## cmds: Array из [axis(-127..127), buttons]. Команда i имеет номер first + i (mod 65536).
static func input(seq: int, first_cmd: int, cmds: Array) -> PackedByteArray:
	var n := mini(cmds.size(), MAX_INPUT_CMDS)
	var b := _header(T_INPUT, seq, 3 + 2 * n, false)
	Wire.w_u16(b, first_cmd)
	Wire.w_u8(b, n)
	for i in n:
		Wire.w_i8(b, cmds[i][0])
		Wire.w_u8(b, cmds[i][1])
	return b


static func parse_input(d: PackedByteArray) -> Dictionary:
	var h := _check(d, T_INPUT, false)
	if h.is_empty():
		return {}
	var r := Wire.Reader.new(d, HEADER_SIZE)
	var first := r.u16()
	var n := r.u8()
	if not r.ok or n < 1 or n > MAX_INPUT_CMDS or r.left() != 2 * n:
		return {}
	var cmds := []
	for i in n:
		var axis := r.i8()
		cmds.append([axis, r.u8()])
	return h.merged({"first": first, "cmds": cmds})


## players: [[id,x,y,vx,vy,hp,flags,buffs]...], owner: PackedByteArray, runes: [[id,type,x,y]...]
static func snapshot(seq: int, tick: int, ack_cmd: int, players: Array, owner: PackedByteArray, runes: Array) -> PackedByteArray:
	var np := mini(players.size(), MAX_SNAPSHOT_PLAYERS)
	var no := mini(owner.size(), MAX_OWNER_STATE)
	var nr := mini(runes.size(), MAX_SNAPSHOT_RUNES)
	var b := _header(T_SNAPSHOT, seq, 2 + 2 + 1 + 13 * np + 1 + no + 1 + 6 * nr, false)
	Wire.w_u16(b, tick)
	Wire.w_u16(b, ack_cmd)
	Wire.w_u8(b, np)
	for i in np:
		var e: Array = players[i]
		Wire.w_u8(b, e[0])
		Wire.w_i16(b, e[1])
		Wire.w_i16(b, e[2])
		Wire.w_i16(b, e[3])
		Wire.w_i16(b, e[4])
		Wire.w_u8(b, e[5])
		Wire.w_u8(b, e[6])
		Wire.w_u16(b, e[7])
	Wire.w_u8(b, no)
	b.append_array(owner.slice(0, no))
	Wire.w_u8(b, nr)
	for i in nr:
		var q: Array = runes[i]
		Wire.w_u8(b, q[0])
		Wire.w_u8(b, q[1])
		Wire.w_i16(b, q[2])
		Wire.w_i16(b, q[3])
	return b


static func parse_snapshot(d: PackedByteArray) -> Dictionary:
	var h := _check(d, T_SNAPSHOT, false)
	if h.is_empty():
		return {}
	var r := Wire.Reader.new(d, HEADER_SIZE)
	var tick := r.u16()
	var ack_cmd := r.u16()
	var np := r.u8()
	if not r.ok or np > MAX_SNAPSHOT_PLAYERS or r.left() < 13 * np:
		return {}
	var players := []
	for i in np:
		players.append([r.u8(), r.i16(), r.i16(), r.i16(), r.i16(), r.u8(), r.u8(), r.u16()])
	var no := r.u8()
	if not r.ok or no > MAX_OWNER_STATE or r.left() < no:
		return {}
	var owner := r.bytes(no)
	var nr := r.u8()
	if not r.ok or nr > MAX_SNAPSHOT_RUNES or r.left() != 6 * nr:
		return {}
	var runes := []
	for i in nr:
		runes.append([r.u8(), r.u8(), r.i16(), r.i16()])
	if not r.ok:
		return {}
	return h.merged({"tick": tick, "ack": ack_cmd, "players": players, "owner": owner, "runes": runes})


static func game_event(seq: int, id: int, kind: int, tick: int, a: int, b_: int, x: int, y: int, v: int) -> PackedByteArray:
	var b := _header(T_GAME_EVENT, seq, GAME_EVENT_PAYLOAD, true)
	Wire.w_u16(b, id)
	Wire.w_u8(b, kind)
	Wire.w_u16(b, tick)
	Wire.w_u8(b, a)
	Wire.w_u8(b, b_)
	Wire.w_i16(b, x)
	Wire.w_i16(b, y)
	Wire.w_i16(b, v)
	return b


static func parse_game_event(d: PackedByteArray) -> Dictionary:
	var h := _check(d, T_GAME_EVENT, true)
	if h.is_empty() or h["payload_size"] != GAME_EVENT_PAYLOAD:
		return {}
	var r := Wire.Reader.new(d, HEADER_SIZE)
	var out := {"id": r.u16(), "kind": r.u8(), "tick": r.u16(), "a": r.u8(), "b": r.u8(), "x": r.i16(), "y": r.i16(), "v": r.i16()}
	return h.merged(out) if r.ok and r.left() == 0 else {}


static func leave(seq: int, reason: int) -> PackedByteArray:
	var b := _header(T_LEAVE, seq, 1, true)
	Wire.w_u8(b, reason)
	return b


static func parse_leave(d: PackedByteArray) -> Dictionary:
	var h := _check(d, T_LEAVE, true)
	if h.is_empty() or h["payload_size"] != 1:
		return {}
	return h.merged({"reason": d[HEADER_SIZE]})


## entries: [[id, color, flags(бит0 хост, бит1 готов), name_utf8], ...]
static func roster(seq: int, entries: Array) -> PackedByteArray:
	var n := mini(entries.size(), MAX_ROSTER)
	var payload := 1
	for i in n:
		payload += 4 + mini((entries[i][3] as PackedByteArray).size(), MAX_NAME_BYTES)
	var b := _header(T_ROSTER, seq, payload, true)
	Wire.w_u8(b, n)
	for i in n:
		var e: Array = entries[i]
		var nm: PackedByteArray = e[3]
		var len := mini(nm.size(), MAX_NAME_BYTES)
		Wire.w_u8(b, e[0])
		Wire.w_u8(b, e[1])
		Wire.w_u8(b, e[2])
		Wire.w_u8(b, len)
		b.append_array(nm.slice(0, len))
	return b


static func parse_roster(d: PackedByteArray) -> Dictionary:
	var h := _check(d, T_ROSTER, true)
	if h.is_empty():
		return {}
	var r := Wire.Reader.new(d, HEADER_SIZE)
	var n := r.u8()
	if not r.ok or n > MAX_ROSTER:
		return {}
	var entries := []
	for i in n:
		var id := r.u8()
		var color := r.u8()
		var flags := r.u8()
		var len := r.u8()
		if not r.ok or len > MAX_NAME_BYTES or r.left() < len:
			return {}
		entries.append([id, color, flags, r.bytes(len)])
	if not r.ok or r.left() != 0:
		return {}
	return h.merged({"entries": entries})


## Разбор по типу: {} при любой ошибке. Для Movement/Shoot — минимальный разбор (поля как в C++).
static func parse(d: PackedByteArray) -> Dictionary:
	var h := read_header(d)
	if h.is_empty():
		return {}
	match h["type"]:
		T_PING: return parse_ping(d)
		T_PONG: return parse_pong(d)
		T_ACK: return parse_ack(d)
		T_HELLO: return parse_hello(d)
		T_WELCOME: return parse_welcome(d)
		T_INPUT: return parse_input(d)
		T_SNAPSHOT: return parse_snapshot(d)
		T_GAME_EVENT: return parse_game_event(d)
		T_LEAVE: return parse_leave(d)
		T_ROSTER: return parse_roster(d)
		T_WORLD_UPDATE: return ReplCodec.parse_update(d)
		T_WORLD_RELIABLE: return ReplCodec.parse_reliable(d)
		_: return h # Movement/Shoot: игре не нужны, достаточно валидного заголовка
