class_name ReplClient
extends RefCounted
## Клиентская сторона репликации ПР №5: принимает пакеты, держит «вид мира» (то, что клиент знает об акторах)
## и экстраполирует позиции по скорости между обновлениями (dead reckoning) — именно это позволяет реже слать быстрых,
## но предсказуемых акторов, не создавая видимых рывков.

signal joined(client_id: int)

const EXTRAPOLATE_MAX_S := 0.30
const TOMB_KEEP_US := 10_000_000


class CActor extends RefCounted:
	var id := 0
	var cls := 0
	var x := 0.0
	var y := 0.0
	var vx := 0.0
	var vy := 0.0
	var st := 0
	var hp := 0
	var tick := 0               # tick мира последнего применённого состояния
	var pos_us := 0             # когда пришли последние координаты (для экстраполяции)
	var upd_us := 0             # когда пришло последнее любое обновление


var net: NetNode
var peer: int
var client_id := -1
var actors := {}                # id -> CActor
var tombs := {}                 # id -> [tick, us] удалённых (защита от опоздавших пакетов)
var stats := {"update_pkts": 0, "reliable_pkts": 0, "entries": 0, "upserts": 0, "destroys": 0, "stale": 0, "unknown": 0, "tomb_blocked": 0}
var _cmd := 0


func _init(network: NetNode, server_peer: int) -> void:
	net = network
	peer = server_peer
	net.message.connect(_on_message)


func join() -> void:
	net.send(peer, func(q: int) -> PackedByteArray: return Proto.hello(q, Proto.GAME_PROTO, 0, "repl".to_utf8_buffer()), true)


func process() -> void:
	net.process()


## Одна команда на пакет; сервер применяет самую новую.
func send_input(axis: int, buttons: int) -> void:
	_cmd = (_cmd + 1) & 0xFFFF
	var first := _cmd
	net.send(peer, func(q: int) -> PackedByteArray: return Proto.input(q, first, [[axis, buttons]]), false)


func avatar() -> CActor:
	return actors.get(ReplWorld.PLAYER_BASE + client_id)


## Позиция актора на момент now_us: последние координаты + скорость × прошедшее время (не дольше 0,3 с).
func pos_at(id: int, now_us: int) -> Vector2:
	var a: CActor = actors.get(id)
	if a == null:
		return Vector2(-1.0e9, -1.0e9)
	var age := minf(float(now_us - a.pos_us) / 1.0e6, EXTRAPOLATE_MAX_S)
	return Vector2(a.x + a.vx * age, a.y + a.vy * age)


static func _newer_or_eq(a: int, b: int) -> bool:
	return ((a - b + 32768) & 0xFFFF) - 32768 >= 0


func _on_message(_p: int, msg: Dictionary) -> void:
	var t: int = msg["type"]
	var now := net.link.now_us()
	if t == Proto.T_WELCOME:
		if int(msg["status"]) == 0 and client_id < 0:
			client_id = int(msg["id"])
			joined.emit(client_id)
	elif t == Proto.T_WORLD_UPDATE:
		stats["update_pkts"] += 1
		var tick: int = msg["tick"]
		for e in msg["entries"]:
			stats["entries"] += 1
			var a: CActor = actors.get(int(e["id"]))
			if a == null:
				stats["unknown"] += 1
				continue
			if not _newer_or_eq(tick, a.tick):
				stats["stale"] += 1
				continue
			_apply(a, e, tick, now)
	elif t == Proto.T_WORLD_RELIABLE:
		stats["reliable_pkts"] += 1
		var tick2: int = msg["tick"]
		for e in msg["entries"]:
			var id: int = e["id"]
			if int(e["op"]) == ReplDefs.OP_DESTROY:
				var cur: CActor = actors.get(id)
				if cur != null and not _newer_or_eq(tick2, cur.tick):
					stats["stale"] += 1
					continue
				actors.erase(id)
				tombs[id] = [tick2, now]
				stats["destroys"] += 1
			else:
				if tombs.has(id):
					var tb: Array = tombs[id]
					if not (_newer_or_eq(tick2, int(tb[0])) and tick2 != int(tb[0])):
						stats["tomb_blocked"] += 1
						continue
					tombs.erase(id)
				var a2: CActor = actors.get(id)
				if a2 == null:
					a2 = CActor.new()
					a2.id = id
					a2.cls = int(e["cls"])
					a2.tick = tick2
					actors[id] = a2
				elif not _newer_or_eq(tick2, a2.tick):
					stats["stale"] += 1
					continue
				_apply(a2, e, tick2, now)
				stats["upserts"] += 1
		_prune_tombs(now)


func _apply(a: CActor, e: Dictionary, tick: int, now: int) -> void:
	a.tick = tick
	a.upd_us = now
	if e.has("x") or e.has("y"):
		a.pos_us = now
	if e.has("x"):
		a.x = e["x"]
	if e.has("y"):
		a.y = e["y"]
	if e.has("vx"):
		a.vx = e["vx"]
	if e.has("vy"):
		a.vy = e["vy"]
	if e.has("st"):
		a.st = int(e["st"])
	if e.has("hp"):
		a.hp = int(e["hp"])


func _prune_tombs(now: int) -> void:
	for id in tombs.keys():
		if now - int((tombs[id] as Array)[1]) > TOMB_KEEP_US:
			tombs.erase(id)
