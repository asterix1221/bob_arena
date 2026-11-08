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
## Рывок «нажат → решение сервера получено». accepted — сервер принял; local_ms — через сколько после нажатия рывок
## стал виден на экране клиента (≈0 с предсказанием, ≈RTT без него); confirm_ms — когда пришло подтверждение сервера.
## Игрок нажал рывок (команда с номером seq создана; клиент её уже отправляет/применяет по настройкам предсказания).
signal dash_pressed(seq: int)
signal dash_resolved(accepted: bool, local_ms: float, confirm_ms: float, reason_hint: String)

const SEND_EVERY := 2
const REDUNDANCY := 10
const MAX_PENDING := 600
const SNAP_TELEPORT_PX := 120.0
const MAX_DASH_MARKS := 16

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

# --- ПР №4: настройки предсказания рывка и наблюдение ---
## true — рывок исполняется у клиента сразу (CSP); false — клиент шлёт ввод, но рывок на экране появляется только
## после ответа сервера (вариант «без предсказания»; ходьба/прыжок предсказываются в обоих режимах).
var predict_dash := true
## Намеренный чит (для демонстрации коррекции): клиент локально игнорирует кулдаун и выносливость рывка.
var cheat_no_rules := false
var last_server_state: PState = null   # последнее АВТОРИТЕТНОЕ состояние (на момент last_ack) — «призрак» для визуализации
var local_response_ms: Array[float] = []     # нажатие рывка -> рывок виден у клиента
var confirm_response_ms: Array[float] = []   # нажатие рывка -> подтверждение сервера
var dash_accepted := 0
var dash_denied := 0
var _dash_marks: Array = []                  # [{seq, press_us, local_us}] ещё не разрешённые нажатия рывка

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

## Кнопки, которые клиент применяет К СЕБЕ при предсказании: без CSP рывка кнопка рывка локально «не нажимается»,
## но на сервер уходит как есть. Повтор команд после коррекции маскируется так же — иначе рывок «выстрелил бы» в повторе.
func _local_buttons(buttons: int) -> int:
	return buttons if predict_dash else (buttons & ~Proto.BTN_DASH)


## press_us — момент нажатия клавиши (мкс, как в InputLatch); 0 — считать «сейчас» (боты, тесты).
func local_tick(axis: int, buttons: int, press_us: int = 0) -> void:
	_tick_count += 1
	cmd_seq += 1
	var step_buttons := buttons & GameHost.BUTTON_MASK
	if buttons & Proto.BTN_DASH and my_id >= 0 and phase == GC.PHASE_PLAYING and state.alive:
		_dash_marks.append({"seq": cmd_seq, "press_us": press_us if press_us > 0 else now_us(), "local_us": -1})
		dash_pressed.emit(cmd_seq)
		if _dash_marks.size() > MAX_DASH_MARKS:
			_dash_marks.pop_front()
	if my_id >= 0 and phase == GC.PHASE_PLAYING and state.alive:
		if cheat_no_rules:
			state.dash_cd = 0
			state.stamina = GC.STAMINA_MAX
		var dash_before := state.dash_left
		var reason := PlatSim.step(state, axis, _local_buttons(step_buttons))
		if reason != "":
			local_dash_rejects += 1
		if dash_before == 0 and state.dash_left > 0 and not _dash_marks.is_empty() and int(_dash_marks.back()["seq"]) == cmd_seq:
			_dash_marks.back()["local_us"] = now_us()      # рывок стал виден (локально принят)
		history[cmd_seq] = state.copy()
	pending.append([cmd_seq, clampi(axis, -127, 127), step_buttons])
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
			_dash_marks.clear()
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
		last_server_state = server_state.copy()
		history.clear()
		_dash_marks.clear()
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
	last_server_state = server_state.copy()
	_resolve_dash_marks(server_state, ack)
	if predicted != null and predicted.equals(server_state):
		history.erase(ack)
		return
	# расхождение: серверное состояние + повтор неподтверждённых команд
	var before := state.copy()
	state = server_state.copy()
	for cmd in pending:
		if state.alive:
			PlatSim.step(state, int(cmd[1]), _local_buttons(int(cmd[2])))
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


## Сервер подтвердил/отклонил нажатия рывка с номерами <= ack. Принят ли рывок — видно по таймеру перезарядки в
## авторитетном состоянии: после принятия на команде seq он на ack равен DASH_COOLDOWN - (ack - seq).
func _resolve_dash_marks(server_state: PState, ack: int) -> void:
	var now := now_us()
	while not _dash_marks.is_empty() and int(_dash_marks[0]["seq"]) <= ack:
		var m: Dictionary = _dash_marks.pop_front()
		var seq := int(m["seq"])
		var accepted := server_state.dash_cd == GC.DASH_COOLDOWN - (ack - seq)
		var confirm_ms := float(now - int(m["press_us"])) / 1000.0
		var local_ms := -1.0
		if accepted:
			dash_accepted += 1
			confirm_response_ms.append(confirm_ms)
			# с предсказанием рывок виден сразу; без — только когда пришёл ответ сервера
			local_ms = float(int(m["local_us"]) - int(m["press_us"])) / 1000.0 if int(m["local_us"]) >= 0 else confirm_ms
			local_response_ms.append(local_ms)
		else:
			dash_denied += 1
		dash_resolved.emit(accepted, local_ms, confirm_ms, "" if accepted else "rejected")


## Для визуализации: путь предсказания в px. Первая точка — авторитетное положение сервера (на ack), дальше —
## положение клиента (ноги) после каждой ещё НЕ подтверждённой команды. Состояние не меняет.
func pending_path() -> PackedVector2Array:
	var pts := PackedVector2Array()
	if last_server_state == null:
		return pts
	pts.append(Vector2(last_server_state.x, last_server_state.y) / float(GC.SUB))
	for cmd in pending:
		var h: PState = history.get(int(cmd[0]))
		if h != null:
			pts.append(Vector2(h.x, h.y) / float(GC.SUB))
	return pts


## На сколько пикселей предсказанное положение «опережает» авторитетное (≈ RTT × скорость).
func prediction_lead_px() -> float:
	if last_server_state == null:
		return 0.0
	return Vector2(state.x - last_server_state.x, state.y - last_server_state.y).length() / float(GC.SUB)


## Коррекций за последнюю секунду и снимков за последнюю секунду (скользящее окно).
func rates() -> Dictionary:
	var now := now_us()
	while not _corr_times.is_empty() and now - _corr_times[0] > 1_000_000:
		_corr_times.pop_front()
	while not _snap_times.is_empty() and now - _snap_times[0] > 1_000_000:
		_snap_times.pop_front()
	return {"corrections_s": _corr_times.size(), "snapshots_s": _snap_times.size()}
