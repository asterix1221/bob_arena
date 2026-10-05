class_name ServerSim
extends RefCounted
## Авторитетная серверная логика (без сети и без Node): принимает НЕдоверенные команды ввода,
## сама симулирует игроков теми же правилами (PlayerSim) и формирует снимки.
## Клиент никогда не присылает позицию — только seq, ось ввода и флаг «хочу рывок».

const MAX_QUEUE := 40         # защита памяти: не копим бесконечно команды от клиента
const CREDIT_CAP := 6.0       # допустимый «разгон» после лага (команд за тик)
const MAX_GAP_FILL := 8       # сколько пропущенных тиков восполняем «удержанием» последнего ввода

var cfg := DashRules.default_cfg()
var players := {}             # peer_id -> Dictionary (см. add_player)
var tick_no := 0
var stats := {"rejected_cmds": 0, "dup_cmds": 0, "gap_fills": 0, "dash_rejects": 0, "dash_accepts": 0}


func add_player(id: int, spawn: Vector2) -> void:
	var s := PlayerState.new()
	s.pos = spawn
	s.stamina = cfg["stamina_max"]
	players[id] = {
		"state": s, "queue": [], "last_seq": 0, "max_queued": 0, "credit": 0.0,
		"dash_request": false, "reject_count": 0, "last_reject": "",
		"last_cmd": PlayerSim.make_cmd(0, Vector2.ZERO, false),
	}


func remove_player(id: int) -> void:
	players.erase(id)


## Приём пакета команд от клиента (недоверенный ввод!). Дубликаты и «старьё» отбрасываются.
func receive_cmds(id: int, cmds: Array) -> void:
	if not players.has(id):
		return
	var p: Dictionary = players[id]
	var q: Array = p["queue"]
	for raw in cmds:
		if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("seq")) != TYPE_INT:
			stats["rejected_cmds"] += 1
			continue
		var seq: int = raw["seq"]
		if seq <= p["last_seq"] or seq <= p["max_queued"]:
			stats["dup_cmds"] += 1       # уже обработана/в очереди (избыточная переотправка)
			continue
		if q.size() >= MAX_QUEUE:
			stats["rejected_cmds"] += 1
			continue
		# В очередь попадают ТОЛЬКО известные поля — любые «лишние» (например, pos) отбрасываются.
		q.append({"seq": seq, "mx": int(raw.get("mx", 0)), "my": int(raw.get("my", 0)), "dash": bool(raw.get("dash", false))})
		p["max_queued"] = seq


## Вариант без предсказания: запрос рывка пришёл отдельным RPC.
func request_dash(id: int) -> void:
	if players.has(id):
		players[id]["dash_request"] = true


## Один серверный тик. Возвращает список строк-событий для лога.
func tick() -> Array:
	var events: Array = []
	tick_no += 1
	for id in players:
		var p: Dictionary = players[id]
		p["credit"] = minf(CREDIT_CAP, p["credit"] + 1.0)   # не больше ~1 команды за тик в среднем
		var q: Array = p["queue"]
		while p["credit"] >= 1.0 and not q.is_empty():
			var cmd: Dictionary = q.pop_front()
			var seq: int = cmd["seq"]
			var expected: int = p["last_seq"] + 1
			if seq > expected:
				# Пропуск (все копии потеряны): восполняем удержанием последнего ввода.
				var fill := mini(seq - expected, MAX_GAP_FILL)
				for _i in fill:
					var hold: Dictionary = p["last_cmd"].duplicate()
					hold["dash"] = false
					PlayerSim.step(p["state"], hold, cfg)
				stats["gap_fills"] += fill
				events.append("[SERVER] peer=%d missing %d command(s) before seq=%d, held last input" % [id, seq - expected, seq])
			if p["dash_request"]:
				cmd["dash"] = true
				p["dash_request"] = false
			var res := PlayerSim.step(p["state"], cmd, cfg)
			if res["started"]:
				stats["dash_accepts"] += 1
				events.append("[DASH] SERVER ACCEPTED peer=%d seq=%d stamina_left=%.1f" % [id, seq, p["state"].stamina])
			elif res["rejected"] != "":
				p["reject_count"] += 1
				p["last_reject"] = res["rejected"]
				stats["dash_rejects"] += 1
				events.append("[DASH] SERVER REJECTED peer=%d seq=%d reason=%s cooldown_left=%d stamina=%.1f" % [id, seq, res["rejected"], p["state"].cooldown_left, p["state"].stamina])
			p["last_seq"] = seq
			p["last_cmd"] = cmd
			p["credit"] -= 1.0
	return events


## Авторитетное состояние владельцу (аналог ClientAdjustPosition/ClientAckGoodMove).
func owner_snapshot(id: int) -> Dictionary:
	var p: Dictionary = players[id]
	return {"ack": p["last_seq"], "state": p["state"].to_dict(), "rej": p["reject_count"],
		"why": p["last_reject"], "tick": tick_no}


## Состояние мира для остальных (аналог Simulated Proxy): только то, что нужно для отрисовки.
func world_snapshot() -> Dictionary:
	var out := {}
	for id in players:
		var s: PlayerState = players[id]["state"]
		out[id] = {"pos": s.pos, "dash": s.dash_left > 0}
	return {"tick": tick_no, "p": out}
