class_name ClientPredictor
extends RefCounted
## Клиентская часть: Client-Side Prediction + Server Reconciliation.
## Аналог связки SavedMoves / ClientAdjustPosition / ClientUpdatePositionAfterServerUpdate из UE:
##   local_input()       — применить ввод СРАЗУ (предсказание) и сохранить команду и результат;
##   packet_cmds()       — последние неподтверждённые команды (избыточная отправка вместо reliable);
##   on_owner_snapshot() — сверка с авторитетным состоянием; при расхождении — перемотка и повтор.
## Время (now_ms) передаёт вызывающий — поэтому класс одинаково работает в игре и в тестах.

const HISTORY_MAX := 400
const REDUNDANCY := 10
const SNAP_THRESHOLD := 120.0        # px: больше — не сглаживаем, а телепортируем
const OFFSET_DECAY := 0.88           # сглаживание визуальной ошибки (≈90 мс на половину)

var cfg: Dictionary = DashRules.default_cfg()    # правила, по которым клиент ПРЕДСКАЗЫВАЕТ
var predict_dash := true
var state: PlayerState
var next_seq := 1
var pending: Array = []              # команды, ещё не подтверждённые сервером
var history := {}                    # seq -> состояние ПОСЛЕ применения команды seq
var last_ack := 0
var offset := Vector2.ZERO           # визуальная поправка после коррекции
var now_ms := 0.0
var events: Array = []               # строки лога (читает вызывающий)

# статистика
var corrections := 0
var last_error := 0.0
var max_error := 0.0
var key_queue: Array = []            # времена нажатий рывка, ещё не получившие ответ сервера (по порядку)
var local_response_ms: Array = []    # нажатие -> первый кадр рывка у клиента
var confirm_response_ms: Array = []  # нажатие -> подтверждение/видимый ответ сервера
var rejects_seen := 0
var server_dash_count := 0
var last_server_state: PlayerState


func _init(spawn: Vector2 = Vector2.ZERO) -> void:
	state = PlayerState.new()
	state.pos = spawn
	state.stamina = cfg["stamina_max"]
	last_server_state = state.duplicate_state()


## Чит для демонстрации расхождения: клиент «считает», что кулдауна нет и/или рывок быстрее.
func set_cheat(ignore_rules: bool, dash_speed_scale: float) -> void:
	cfg = DashRules.default_cfg()
	cfg["ignore_rules"] = ignore_rules
	cfg["dash_speed"] = cfg["dash_speed"] * dash_speed_scale


func display_pos() -> Vector2:
	return state.pos + offset


## Вызывать каждый тик. Возвращает {"cmd": Dictionary, "send_dash_request": bool}.
func local_input(move: Vector2, dash_pressed: bool) -> Dictionary:
	if dash_pressed:
		key_queue.append(now_ms)
	# С предсказанием флаг входит в команду и исполняется локально сразу;
	# без предсказания клиент ничего не делает сам, а лишь просит сервер (RPC).
	var cmd := PlayerSim.make_cmd(next_seq, move, dash_pressed and predict_dash)
	next_seq += 1
	var res := PlayerSim.step(state, cmd, cfg)
	if res["started"] and not key_queue.is_empty():
		var local_ms: float = now_ms - key_queue.back()
		local_response_ms.append(local_ms)
		events.append("[DASH] t=%d mode=PREDICTION local response=%.1f ms (key -> first predicted dash tick)" % [int(now_ms), local_ms])
	pending.append(cmd)
	history[cmd["seq"]] = state.duplicate_state()
	if history.size() > HISTORY_MAX:
		history.erase(history.keys().min())
	offset *= OFFSET_DECAY
	return {"cmd": cmd, "send_dash_request": dash_pressed and not predict_dash}


## Последние неподтверждённые команды (до REDUNDANCY штук) — защита от потерь без reliable-канала.
func packet_cmds() -> Array:
	var n := pending.size()
	return pending.slice(maxi(0, n - REDUNDANCY), n)


func on_owner_snapshot(snap: Dictionary) -> void:
	var ack: int = snap["ack"]
	if ack < last_ack:
		return                                        # устаревший (переупорядоченный) снимок
	var srv := PlayerState.from_dict(snap["state"])
	last_server_state = srv

	# Ответы сервера приходят в порядке нажатий: каждый принятый/отклонённый рывок закрывает одно нажатие.
	while snap["rej"] > rejects_seen:
		rejects_seen += 1
		var dt := -1.0
		if not key_queue.is_empty():
			dt = now_ms - key_queue.pop_front()
		events.append("[DASH] t=%d REJECTED by server: reason=%s (%.1f ms after key press)" % [int(now_ms), snap["why"], dt])
	while srv.dash_count > server_dash_count:
		server_dash_count += 1
		if not key_queue.is_empty():
			var ms: float = now_ms - key_queue.pop_front()
			confirm_response_ms.append(ms)
			events.append("[DASH] t=%d mode=%s server-confirmed/visible response=%.1f ms" % [int(now_ms), "PREDICTION" if predict_dash else "NO_PREDICTION", ms])

	# Подтверждённые команды больше не нужны (история на сам ack остаётся для сравнения).
	while not pending.is_empty() and pending[0]["seq"] <= ack:
		pending.pop_front()
	for k in history.keys():
		if k < ack:
			history.erase(k)
	last_ack = ack
	if ack == 0:
		return                                        # сервер ещё не обработал ни одной команды — сверять нечего

	var pred: PlayerState = history.get(ack)
	if pred != null and pred.matches(srv):
		return                                        # предсказание верно — коррекция не нужна

	# Расхождение: встать в авторитетное состояние и заново проиграть неподтверждённые команды.
	corrections += 1
	last_error = pred.pos.distance_to(srv.pos) if pred != null else 0.0
	max_error = maxf(max_error, last_error)
	var old_display := display_pos()
	state = srv.duplicate_state()
	history[ack] = srv.duplicate_state()
	for cmd in pending:
		PlayerSim.step(state, cmd, cfg)
		history[cmd["seq"]] = state.duplicate_state()
	var jump := old_display - state.pos
	offset = jump if jump.length() < SNAP_THRESHOLD else Vector2.ZERO
	events.append("[CORRECTION] t=%d #%d ack=%d predicted-vs-server error=%.1f px, replayed %d command(s)" % [int(now_ms), corrections, ack, last_error, pending.size()])
