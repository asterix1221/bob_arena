class_name ReplServer
extends RefCounted
## Репликатор Listen Server для ПР №5. Берёт события мира (ReplWorld) и раздаёт их клиентам через NetNode (ПР №1–3):
## надёжные пакеты (появление / «пробуждение» спящего / удаление) и ненадёжные обновления состояния.
## Какие оптимизации включены — решает ReplCfg; при всех выключенных получается наивная репликация («до»).

signal client_joined(client_id: int, peer: int)
signal client_left(client_id: int)

const MAX_CLIENTS := 4
const SPAWN_X := [400.0, 8000.0, 15200.0, 4200.0]


class Known extends RefCounted:
	var cls := 0
	var sent := false       # надёжная запись с полным состоянием уже отправлена
	var pending := 0        # маска полей, изменившихся с последней отправки этому клиенту (push)
	var due := 0            # сетевой тик, с которого актор можно обновлять снова (NetUpdateFrequency)
	var last_sent := 0
	var kf_due := 0         # когда слать «ключевое» полное состояние


class Conn extends RefCounted:
	var peer := 0
	var client_id := 0
	var avatar := 0
	var known := {}         # id -> Known
	var spawn_q := {}       # id -> true: отправить надёжным пакетом
	var destroy_q := {}     # id -> причина
	var flush_q := {}       # id -> true: изменение спящего актора
	var last_cmd := -1


var net: NetNode
var world: ReplWorld
var cfg: ReplCfg
var prof: ReplProfiler
var grid := ReplGrid.new()
var conns := {}             # peer -> Conn
var net_idx := 0
var _by_client := {}
var _check_count := 0


func _init(network: NetNode, w: ReplWorld, c: ReplCfg, p: ReplProfiler) -> void:
	net = network
	world = w
	cfg = c
	prof = p
	net.accept_new_peers = true
	net.message.connect(_on_message)
	net.peer_lost.connect(_on_peer_lost)
	world.actor_spawned.connect(_on_spawned)
	world.actor_removed.connect(_on_removed)
	for id in world.actors.keys():       # уровень мог быть собран до создания сервера
		var a: ReplActor = world.actors[id]
		if a.cls != ReplDefs.C_PLAYER:
			grid.insert(a.id, a.x, a.y)


# ------------------------------------------------------------------ подключение клиентов

func _on_message(peer: int, msg: Dictionary) -> void:
	var t: int = msg["type"]
	if t == Proto.T_HELLO:
		_on_hello(peer, msg)
	elif t == Proto.T_INPUT:
		if conns.has(peer) and not (msg["cmds"] as Array).is_empty():
			var c: Conn = conns[peer]
			var last_no: int = int(msg["first"]) + (msg["cmds"] as Array).size() - 1
			if c.last_cmd < 0 or SeqUtil.newer(last_no & 0xFFFF, c.last_cmd):
				c.last_cmd = last_no & 0xFFFF
				var cmd: Array = (msg["cmds"] as Array).back()
				world.set_input(c.client_id, int(cmd[0]), int(cmd[1]))
	elif t == Proto.T_LEAVE:
		_remove_client(peer)


func _on_hello(peer: int, _msg: Dictionary) -> void:
	if conns.has(peer):
		_send_welcome(conns[peer])
		return
	var cid := -1
	for i in MAX_CLIENTS:
		if not _by_client.has(i):
			cid = i
			break
	if cid < 0:
		net.send(peer, func(q: int) -> PackedByteArray: return Proto.welcome(q, 1, Proto.GAME_PROTO, 0, world.tick & 0xFFFF, ReplDefs.WORLD_HZ, world.seed_value), true)
		return
	var c := Conn.new()
	c.peer = peer
	c.client_id = cid
	conns[peer] = c
	_by_client[cid] = c
	var a := world.add_player(cid, SPAWN_X[cid % SPAWN_X.size()])
	c.avatar = a.id
	_send_welcome(c)
	if not cfg.relevancy:
		_queue_all(c)
	client_joined.emit(cid, peer)


func _send_welcome(c: Conn) -> void:
	net.send(c.peer, func(q: int) -> PackedByteArray: return Proto.welcome(q, 0, Proto.GAME_PROTO, c.client_id, world.tick & 0xFFFF, ReplDefs.WORLD_HZ, world.seed_value), true)


func _on_peer_lost(peer: int) -> void:
	_remove_client(peer)


func _remove_client(peer: int) -> void:
	if not conns.has(peer):
		return
	var c: Conn = conns[peer]
	conns.erase(peer)
	_by_client.erase(c.client_id)
	world.remove_player(c.client_id)
	client_left.emit(c.client_id)


func _queue_all(c: Conn) -> void:
	for id in world.actors.keys():
		_ensure_known(c, id, world.actors[id])
		c.spawn_q[id] = true


func _ensure_known(c: Conn, id: int, a: ReplActor) -> void:
	if c.known.has(id):
		return
	var k := Known.new()
	k.cls = a.cls
	var period := ReplDefs.period_net_ticks(a.cls, cfg.freq)
	k.due = net_idx + 1 + (id % period if cfg.freq else 0)     # разнесение по тикам (frequency buckets)
	k.last_sent = net_idx
	k.kf_due = net_idx + cfg.keyframe_net_ticks + (id % cfg.keyframe_net_ticks)
	c.known[id] = k


## Смена набора оптимизаций «на лету» (лаборатория): приводим известные клиентам акторы к ожидаемому состоянию.
func apply_cfg() -> void:
	for peer in conns.keys():
		var c: Conn = conns[peer]
		if not cfg.relevancy:
			for id in world.actors.keys():
				if not c.known.has(id):
					_ensure_known(c, id, world.actors[id])
					c.spawn_q[id] = true
		for id in c.known.keys():
			var k: Known = c.known[id]
			var a: ReplActor = world.actors.get(id)
			if a != null:
				k.due = net_idx + 1
				k.pending = ReplDefs.F_ALL if cfg.push else 0


# ------------------------------------------------------------------ события мира

func _on_spawned(a: ReplActor) -> void:
	if a.cls != ReplDefs.C_PLAYER:
		grid.insert(a.id, a.x, a.y)
	if not cfg.relevancy:
		for peer in conns.keys():
			var c: Conn = conns[peer]
			if c.avatar == a.id:
				continue
			_ensure_known(c, a.id, a)
			c.spawn_q[a.id] = true


func _on_removed(a: ReplActor) -> void:
	grid.remove(a.id)
	for peer in conns.keys():
		var c: Conn = conns[peer]
		c.spawn_q.erase(a.id)
		c.flush_q.erase(a.id)
		if c.known.has(a.id):
			var k: Known = c.known[a.id]
			if k.sent:
				c.destroy_q[a.id] = ReplDefs.DESTROY_REMOVED
			c.known.erase(a.id)


# ------------------------------------------------------------------ шаг сервера (60 Гц)

func step() -> void:
	net.process()
	world.step()
	_distribute_dirty()
	prof.tick(world.tick)
	if world.tick % ReplDefs.NET_EVERY == 0:
		net_idx += 1
		for peer in conns.keys():
			_net_tick(conns[peer])


## Push-модель: актор сам сообщил, какие поля изменились; раздаём это клиентам, которые его знают.
func _distribute_dirty() -> void:
	for id in world.dirty_ids:
		var a: ReplActor = world.actors.get(id)
		if a == null:
			continue
		var m := a.dirty
		if (m & (ReplDefs.F_X | ReplDefs.F_Y)) != 0 and a.cls != ReplDefs.C_PLAYER:
			grid.move(a.id, a.x, a.y)
		var sleeping := cfg.dormancy and a.can_sleep
		for peer in conns.keys():
			var c: Conn = conns[peer]
			var k: Known = c.known.get(id)
			if k == null or not k.sent:
				continue
			if sleeping:
				c.flush_q[id] = true                    # FlushNetDormancy: разово и надёжно
			elif cfg.push:
				k.pending |= m
		a.clear_dirty()
	world.dirty_ids.clear()


func _net_tick(c: Conn) -> void:
	var t0 := Time.get_ticks_usec()
	if cfg.relevancy:
		_update_relevance(c)
	_send_reliable(c)
	_send_updates(c)
	prof.known(c.known.size())
	prof.cpu(Time.get_ticks_usec() - t0)


# ------------------------------------------------------------------ релевантность (Replication Graph)

func _update_relevance(c: Conn) -> void:
	var obs: ReplActor = world.actors.get(c.avatar)
	if obs == null:
		return
	var want := {}
	for pid in world.player_actor_ids():        # игроки релевантны всем всегда (AlwaysRelevantNode)
		want[pid] = true
	var reach := 1400.0 + ReplDefs.HYST_PX
	var cells_before := grid.cells_visited
	var cands := grid.query_x_range(obs.x - reach, obs.x + reach)
	var checks := 0
	for id in cands:
		var a: ReplActor = world.actors.get(id)
		if a == null:
			continue
		checks += 1
		if is_net_relevant_for(a, obs, c.known.has(id)):
			want[id] = true
	prof.relevance(checks, grid.cells_visited - cells_before)
	for id in want.keys():
		if not c.known.has(id):
			var a2: ReplActor = world.actors[id]
			_ensure_known(c, id, a2)
			c.spawn_q[id] = true
	for id in c.known.keys():
		if not want.has(id):
			var k: Known = c.known[id]
			if k.sent:
				c.destroy_q[id] = ReplDefs.DESTROY_IRRELEVANT
			c.spawn_q.erase(id)
			c.flush_q.erase(id)
			c.known.erase(id)


## Аналог AActor::IsNetRelevantFor. Базово — расстояние по X до своего персонажа (NetCullDistance класса).
## С custom_relevance: за спиной радиус меньше (для декора и предметов; враги и снаряды опасны с любой стороны) и
## гистерезис — уже известный актор отпускается чуть дальше, чем берётся (нет «мигания» на границе).
func is_net_relevant_for(a: ReplActor, obs: ReplActor, was_known: bool) -> bool:
	if a.cls == ReplDefs.C_PLAYER:
		return true
	var dx := a.x - obs.x
	var limit: float = ReplDefs.CULL_PX[a.cls]
	if cfg.custom_relevance:
		var ahead := (dx >= 0.0) == obs.facing_right()
		if not ahead:
			limit *= ReplDefs.BACK_FACTOR[a.cls]
		if was_known:
			limit += ReplDefs.HYST_PX
	return absf(dx) <= limit


# ------------------------------------------------------------------ надёжный канал: spawn / sleep-flush / destroy

func _send_reliable(c: Conn) -> void:
	var fmt := ReplDefs.FMT_QUANT if cfg.quantize else 0
	var entries: Array = []
	var sizes := 0
	var max_payload := ReplDefs.MAX_UPDATE_PAYLOAD
	for id in c.destroy_q.keys():
		entries.append([ReplDefs.OP_DESTROY, id, c.destroy_q[id]])
		prof.reliable_op("destroy")
	c.destroy_q.clear()
	var upserts := {}
	for id in c.spawn_q.keys():
		upserts[id] = "spawn"
	for id in c.flush_q.keys():
		if not upserts.has(id):
			upserts[id] = "state"
	c.spawn_q.clear()
	c.flush_q.clear()
	var ids: Array = upserts.keys()
	ids.sort()
	for id in ids:
		var a: ReplActor = world.actors.get(id)
		var k: Known = c.known.get(id)
		if a == null or k == null:
			continue
		entries.append([ReplDefs.OP_UPSERT, a])
		prof.reliable_op(upserts[id])
		k.sent = true
		k.pending = 0
		k.last_sent = net_idx
		k.kf_due = net_idx + cfg.keyframe_net_ticks + (id % cfg.keyframe_net_ticks)
		var period := ReplDefs.period_net_ticks(a.cls, cfg.freq)
		k.due = net_idx + 1 + (id % period if cfg.freq else 0)       # фаза разнесения сохраняется и после появления
	if entries.is_empty():
		return
	var chunk: Array = []
	for e in entries:
		var es := ReplCodec.upsert_entry_size(fmt) if int(e[0]) == ReplDefs.OP_UPSERT else ReplCodec.DESTROY_ENTRY_SIZE
		if sizes + es > max_payload - 4 and not chunk.is_empty():
			_emit_reliable(c, fmt, chunk, sizes)
			chunk = []
			sizes = 0
		chunk.append(e)
		sizes += es
	if not chunk.is_empty():
		_emit_reliable(c, fmt, chunk, sizes)


func _emit_reliable(c: Conn, fmt: int, chunk: Array, sizes: int) -> void:
	var tick16 := world.tick & 0xFFFF
	net.send(c.peer, func(q: int) -> PackedByteArray: return ReplCodec.reliable_packet(q, tick16, fmt, chunk), true)
	prof.packet("reliable", 4 + sizes, chunk.size())
	for e in chunk:
		if int(e[0]) == ReplDefs.OP_UPSERT:
			var a: ReplActor = e[1]
			prof.entry(a.id, a.cls, ReplCodec.upsert_entry_size(fmt), 6)
		else:
			prof.entry(int(e[1]), _cls_of_destroyed(int(e[1])), ReplCodec.DESTROY_ENTRY_SIZE, 0)


func _cls_of_destroyed(id: int) -> int:
	if id < ReplWorld.TREE_BASE:
		return ReplDefs.C_PLAYER
	if id < ReplWorld.PICKUP_BASE:
		return ReplDefs.C_TREE
	if id < ReplWorld.BOT_BASE:
		return ReplDefs.C_PICKUP
	if id < ReplWorld.CLOUD_BASE:
		return ReplDefs.C_BOT
	if id < ReplWorld.PROJ_BASE:
		return ReplDefs.C_CLOUD
	return ReplDefs.C_PROJ


# ------------------------------------------------------------------ ненадёжные обновления состояния

func _send_updates(c: Conn) -> void:
	var fmt := (ReplDefs.FMT_DELTA if cfg.push else 0) | (ReplDefs.FMT_QUANT if cfg.quantize else 0)
	var ids: Array = c.known.keys()
	ids.sort()
	var cands: Array = []          # [id, mask, score]
	for id in ids:
		var k: Known = c.known[id]
		if not k.sent:
			continue
		var a: ReplActor = world.actors.get(id)
		if a == null:
			continue
		if cfg.dormancy and a.can_sleep:
			continue
		if net_idx < k.due:
			continue
		var mask := ReplDefs.F_ALL
		if cfg.push:
			if net_idx >= k.kf_due:
				k.pending = ReplDefs.F_ALL
			mask = k.pending
			if mask == 0:
				continue
		var score := 0.0
		if cfg.priority:
			score = float(ReplDefs.PRIORITY[a.cls]) * float(net_idx - k.last_sent + 1)
		cands.append([id, mask, score])
	if cands.is_empty():
		return
	if cfg.priority:
		cands.sort_custom(func(x: Array, y: Array) -> bool: return float(x[2]) > float(y[2]) or (float(x[2]) == float(y[2]) and int(x[0]) < int(y[0])))
	var sel: Array = []
	var used := 0
	for cd in cands:
		var es := ReplCodec.update_entry_size(fmt, int(cd[1]))
		if cfg.budget_bytes > 0 and used + es > cfg.budget_bytes:
			break
		used += es
		sel.append(cd)
	var chunk: Array = []
	var chunk_size := 4
	for cd in sel:
		var es2 := ReplCodec.update_entry_size(fmt, int(cd[1]))
		if chunk_size + es2 > ReplDefs.MAX_UPDATE_PAYLOAD and not chunk.is_empty():
			_emit_update(c, fmt, chunk, chunk_size)
			chunk = []
			chunk_size = 4
		var a2: ReplActor = world.actors[int(cd[0])]
		chunk.append([a2, int(cd[1])])
		chunk_size += es2
		var k2: Known = c.known[int(cd[0])]
		k2.pending = 0
		k2.last_sent = net_idx
		k2.due = net_idx + ReplDefs.period_net_ticks(a2.cls, cfg.freq)
		k2.kf_due = net_idx + cfg.keyframe_net_ticks
	if not chunk.is_empty():
		_emit_update(c, fmt, chunk, chunk_size)


func _emit_update(c: Conn, fmt: int, chunk: Array, payload: int) -> void:
	var tick16 := world.tick & 0xFFFF
	net.send(c.peer, func(q: int) -> PackedByteArray: return ReplCodec.update_packet(q, tick16, fmt, chunk), false)
	prof.packet("update", payload, chunk.size())
	for e in chunk:
		var a: ReplActor = e[0]
		var m: int = e[1] if (fmt & ReplDefs.FMT_DELTA) != 0 else ReplDefs.F_ALL
		var nf := 0
		for i in 6:
			if (m >> i) & 1:
				nf += 1
		prof.entry(a.id, a.cls, ReplCodec.update_entry_size(fmt, int(e[1])), nf)
