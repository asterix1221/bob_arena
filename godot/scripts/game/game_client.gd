class_name GameClient
extends RefCounted
## Клиент: предсказание своего персонажа (Client-Side Prediction), сверка с сервером (Server Reconciliation),
## интерполяция чужих. Серверу уходит ТОЛЬКО ввод (Input: оси и кнопки); позиции он от клиента не получает.
##   local_tick(axis, buttons)  — раз в тик (120 Гц): шаг предсказания + отправка Input (60 Гц, последние 10 команд)
##   process_net()              — приём: Welcome/Roster/Snapshot/GameEvent
## Сверка: в снимке — ownerState (полное состояние) на момент команды ack. Совпало с историей — тишина;
## расходится — берём серверное и ПОВТОРНО применяем все неподтверждённые команды.

signal connected(my_id: int)
signal rejected(status: int)
signal disconnected(reason: String)
signal event(kind: int, a: int, b: int, x: int, y: int, v: int)
signal roster_changed
signal phase_changed(phase: int)
signal correction(error_px: float, replayed: int)

const SEND_EVERY := 2
const REDUNDANCY := 10
const MAX_PENDING := 600
const SNAP_TELEPORT_PX := 120.0

var net: NetNode
var peer := 1
var my_id := -1
var phase := GC.PHASE_LOBBY
var roster := {}                       # id -> {color, flags, name:String}
var state := PState.new()              # предсказанное состояние своего персонажа
var remote := RemoteView.new()
var runes: Array = []                  # [{id,type,x_px,y_px}] из последнего снимка
var pub := {}                          # id -> последнее публичное состояние из снимка
var results := {}                      # id -> {kills, damage, secs, died} после раунда
var winner := GC.NO_PLAYER
var seed_value := 0
var tick_rate := GC.TICK_HZ

var cmd_seq := 0
var pending: Array = []                # [[seq, axis, buttons]] — ещё не подтверждены сервером
var history := {}                      # seq -> PState (состояние ПОСЛЕ команды)
var last_ack := 0

# --- наблюдаемая статистика (net_graph) ---
var corrections := 0
var last_error_px := 0.0
var max_error_px := 0.0
var snapshots_in := 0
var snap_tick_unwrapped := -1
var snap_recv_us := 0
var snap_interval_ms := 0.0
var snap_jitter_ms := 0.0
var snap_gaps := 0                     # пропущенные снимки (разрывы по тикам)
var local_dash_rejects := 0
var server_status := -1

var _seen_events := {}
var _seen_order: Array[int] = []
var _tick_count := 0
var _last_snap_us := 0
var _corr_times: Array[int] = []       # когда были коррекции (для «коррекций в секунду»)
var _snap_times: Array[int] = []
var _hello_name := PackedByteArray()
var _hello_color := 0


func _init(network: NetNode, host_peer: int = 1) -> void:
	net = network
	peer = host_peer
	net.message.connect(_on_message)
	net.peer_lost.connect(func(_p: int, r: String) -> void: disconnected.emit(r))
	net.reliable_failed.connect(_on_reliable_failed)


func join(player_name: String, color: int) -> void:
	_hello_name = player_name.to_utf8_buffer()
	_hello_color = color
	var n := _hello_name
	net.send(peer, func(q: int) -> PackedByteArray: return Proto.hello(q, Proto.GAME_PROTO, color, n), true)


func leave() -> void:
	net.send(peer, func(q: int) -> PackedByteArray: return Proto.leave(q, 0), true)


func _on_reliable_failed(_p: int, _seq: int) -> void:
	if my_id < 0:
		disconnected.emit("no_welcome")     # Hello так и не подтвердили


func process_net() -> void:
	net.process()


func now_us() -> int:
	return net.link.now_us()


## Оценка серверного тика «сейчас» (float): тик последнего снимка + прошедшее с его прихода время.
func server_tick_estimate() -> float:
	if snap_tick_unwrapped < 0:
		return -1.0
	return float(snap_tick_unwrapped) + float(now_us() - snap_recv_us) * float(tick_rate) / 1_000_000.0


func render_tick() -> float:
	return server_tick_estimate() - float(remote.delay_ticks)


## Позиция/состояние чужого игрока для отрисовки (в px). {} если нет данных.
func view_of(id: int) -> Dictionary:
	if id == my_id:
		return {}
	return remote.sample(id, render_tick())


# ------------------------------------------------------------------ предсказание

func local_tick(axis: int, buttons: int) -> void:
	_tick_count += 1
	cmd_seq += 1
	if my_id >= 0 and phase == GC.PHASE_PLAYING and state.alive:
		var reason := PlatSim.step(state, axis, buttons)
		if reason != "":
			local_dash_rejects += 1
		history[cmd_seq] = state.copy()
	pending.append([cmd_seq, clampi(axis, -127, 127), buttons & GameHost.BUTTON_MASK])
	if pending.size() > MAX_PENDING:
		var drop: Array = pending.pop_front()
		history.erase(drop[0])
	if my_id >= 0 and _tick_count % SEND_EVERY == 0:
		_send_input()


func _send_input() -> void:
	var n := mini(pending.size(), REDUNDANCY)
	if n == 0:
		return
	var cmds := []
	for i in range(pending.size() - n, pending.size()):
		cmds.append([pending[i][1], pending[i][2]])
	var first: int = pending[pending.size() - n][0] & 0xFFFF
	net.send(peer, func(q: int) -> PackedByteArray: return Proto.input(q, first, cmds), false)


# ------------------------------------------------------------------ приём

func _set_phase(p: int) -> void:
	if phase != p:
		var old := phase
		phase = p
		if p == GC.PHASE_LOBBY or p == GC.PHASE_COUNTDOWN:
			history.clear()     # pending НЕ чистим: он нужен для избыточной отправки (защита от потерь)
		if old != GC.PHASE_PLAYING and p == GC.PHASE_PLAYING:
			history.clear()
		phase_changed.emit(p)


func _on_message(_p: int, msg: Dictionary) -> void:
	match int(msg["type"]):
		Proto.T_WELCOME:
			server_status = int(msg["status"])
			if server_status != Proto.WELCOME_OK:
				rejected.emit(server_status)
				return
			if my_id < 0:
				my_id = int(msg["id"])
				seed_value = int(msg["seed"])
				tick_rate = int(msg["rate"])
				connected.emit(my_id)
		Proto.T_ROSTER:
			roster.clear()
			for e in msg["entries"]:
				roster[int(e[0])] = {"color": int(e[1]), "flags": int(e[2]), "name": (e[3] as PackedByteArray).get_string_from_utf8()}
			roster_changed.emit()
		Proto.T_SNAPSHOT:
			_on_snapshot(msg)
		Proto.T_GAME_EVENT:
			_on_event(msg)
		Proto.T_LEAVE:
			disconnected.emit("host_left")


func _on_event(msg: Dictionary) -> void:
	var id := int(msg["id"])
	if _seen_events.has(id):
		return                              # повтор надёжного пакета — игнорируем (идемпотентность)
	_seen_events[id] = true
	_seen_order.append(id)
	if _seen_order.size() > 512:
		_seen_events.erase(_seen_order.pop_front())
	var kind := int(msg["kind"])
	match kind:
		GC.EV_COUNTDOWN:
			if phase == GC.PHASE_LOBBY or phase == GC.PHASE_ENDED:
				_set_phase(GC.PHASE_COUNTDOWN)
		GC.EV_ROUND_START:
			results.clear()
		GC.EV_ROUND_END:
			winner = int(msg["a"])
		GC.EV_LOBBY:
			_set_phase(GC.PHASE_LOBBY)
		GC.EV_STATS:
			results[int(msg["a"])] = {"kills": int(msg["b"]), "damage": int(msg["v"]), "secs": int(msg["x"]), "died": int(msg["y"]) == 1}
	event.emit(kind, int(msg["a"]), int(msg["b"]), int(msg["x"]), int(msg["y"]), int(msg["v"]))


func _on_snapshot(msg: Dictionary) -> void:
	var now := now_us()
	var t16: int = msg["tick"]
	var t := t16 if snap_tick_unwrapped < 0 else SeqUtil.unwrap16(t16, snap_tick_unwrapped)
	if snap_tick_unwrapped >= 0 and t <= snap_tick_unwrapped:
		return                              # старый или повторный снимок (UDP может переставлять)
	if snap_tick_unwrapped >= 0:
		var dt_ticks := t - snap_tick_unwrapped
		if dt_ticks > GameHost.SNAPSHOT_EVERY * 2:
			snap_gaps += 1
		var iv := float(now - _last_snap_us) / 1000.0
		snap_jitter_ms += (absf(iv - snap_interval_ms) - snap_jitter_ms) / 16.0
		snap_interval_ms += (iv - snap_interval_ms) / 8.0
	snap_tick_unwrapped = t
	snap_recv_us = now
	_last_snap_us = now
	snapshots_in += 1
	_snap_times.append(now)
	# публичные состояния всех игроков (для интерполяции чужих и HUD)
	for e in msg["players"]:
		var id := int(e[0])
		pub[id] = {"x": e[1] / 16.0, "y": e[2] / 16.0, "vx": e[3], "vy": e[4], "hp": e[5], "flags": e[6], "buffs": e[7]}
		if id != my_id:
			remote.add(id, t, e[1] / 16.0, e[2] / 16.0, float(e[3]) / float(GC.SUB), float(e[4]) / float(GC.SUB), e[6], e[5], e[7])
	for id in pub.keys():
		var present := false
		for e2 in msg["players"]:
			if int(e2[0]) == id:
				present = true
				break
		if not present:
			pub.erase(id)
			remote.forget(id)
	runes = []
	for r in msg["runes"]:
		runes.append({"id": r[0], "type": r[1], "x": r[2] / 16.0, "y": r[3] / 16.0})
	# ownerState: [phase u8][PState]
	var blob: PackedByteArray = msg["owner"]
	if blob.size() < 2 or my_id < 0:
		return
	_set_phase(blob[0])
	var server_state := PState.from_bytes(blob.slice(1))
	if server_state == null:
		return
	var ack := SeqUtil.unwrap16(int(msg["ack"]), cmd_seq)
	_reconcile(server_state, ack)


func _reconcile(server_state: PState, ack: int) -> void:
	if phase != GC.PHASE_PLAYING:
		# лобби/отсчёт/конец: просто зеркалим серверное (в отсчёте это состояния появления)
		state = server_state
		history.clear()
		last_ack = ack
		while not pending.is_empty() and pending[0][0] <= ack:
			pending.pop_front()
		return
	while not pending.is_empty() and pending[0][0] <= ack:
		pending.pop_front()
	var predicted: PState = history.get(ack)
	for k in history.keys():
		if k < ack:
			history.erase(k)
	last_ack = maxi(last_ack, ack)
	if predicted != null and predicted.equals(server_state):
		history.erase(ack)
		return
	# расхождение: серверное состояние + повтор неподтверждённых команд
	var before := state.copy()
	state = server_state.copy()
	for cmd in pending:
		if state.alive:
			PlatSim.step(state, int(cmd[1]), int(cmd[2]))
		history[int(cmd[0])] = state.copy()
	var dx := float(state.x - before.x) / float(GC.SUB)
	var dy := float(state.y - before.y) / float(GC.SUB)
	var err := sqrt(dx * dx + dy * dy)
	if predicted == null and err < 0.01:
		return                              # нечего было предсказывать (например, начало раунда)
	corrections += 1
	last_error_px = err
	max_error_px = maxf(max_error_px, err)
	_corr_times.append(now_us())
	correction.emit(err, pending.size())


## Коррекций за последнюю секунду и снимков за последнюю секунду (скользящее окно).
func rates() -> Dictionary:
	var now := now_us()
	while not _corr_times.is_empty() and now - _corr_times[0] > 1_000_000:
		_corr_times.pop_front()
	while not _snap_times.is_empty() and now - _snap_times[0] > 1_000_000:
		_snap_times.pop_front()
	return {"corrections_s": _corr_times.size(), "snapshots_s": _snap_times.size()}
