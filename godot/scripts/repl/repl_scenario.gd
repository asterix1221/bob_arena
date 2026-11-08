class_name ReplScenario
extends RefCounted
## Воспроизводимый сценарий нагрузки для ПР №5: Listen Server + N клиентов в одном процессе на виртуальном времени (LoopHub).
## Условия «до» и «после» идентичны по построению: тот же seed мира, то же число клиентов, те же скриптовые команды.
## Мир от репликации не зависит, поэтому контрольная сумма состояния мира в конце прогона обязана совпасть (result.checksum).

const TICK_US := 16667
const SAMPLE_EVERY := 6         # снимок качества раз в 100 мс мира


## Скриптовые команды клиента i в момент t (тики после старта steady): [axis, buttons].
static func script_input(i: int, t: int) -> Array:
	match i % 3:
		0:
			return [127, 0]                                  # идёт вправо, не останавливаясь
		1:
			return [-64, 0]                                  # идёт влево вдвое медленнее
		_:
			return [0 if t < 600 else -100, ReplWorld.BTN_SHOOT]    # стоит 10 с, стреляя; затем идёт влево


## Прогон сценария. opts: seconds (30), clients (3), join_s (2), seed (7), lag_ms (0), loss (0..1), budget (-1 — как в cfg).
static func run(cfg: ReplCfg, opts: Dictionary = {}) -> Dictionary:
	var seconds: int = opts.get("seconds", 30)
	var n_clients: int = opts.get("clients", 3)
	var join_s: int = opts.get("join_s", 2)
	var seed_value: int = opts.get("seed", 7)
	var lag: float = opts.get("lag_ms", 0.0)
	var loss: float = opts.get("loss", 0.0)
	var keep_session: bool = opts.get("keep_session", false)

	var hub := LoopHub.new()
	var host_link := LoopLink.new(hub, 1)
	host_link.set_emulation(lag, 0.0, loss)
	var host_net := NetNode.new(host_link)
	var world := ReplWorld.new(seed_value)
	world.build_level()
	var prof := ReplProfiler.new()
	prof.clients = n_clients
	var server := ReplServer.new(host_net, world, cfg, prof)
	var clients: Array = []
	for i in n_clients:
		var l := LoopLink.new(hub, 100 + i)
		l.set_emulation(lag, 0.0, loss)
		var n := NetNode.new(l)
		n.add_peer(host_link.link_id)
		var c := ReplClient.new(n, host_link.link_id)
		c.join()
		clients.append(c)
	var level_actors := world.count()

	var tick_all := func(inputs_t: int, scripted: bool) -> void:
		hub.advance_us(TICK_US)
		for i in clients.size():
			var c: ReplClient = clients[i]
			c.process()
			if c.client_id >= 0:
				var inp: Array = script_input(i, inputs_t) if scripted else [0, 0]
				c.send_input(int(inp[0]), int(inp[1]))
		server.step()

	# --- фаза join: начальная синхронизация, клиенты стоят
	prof.begin("join", world.tick)
	for t in join_s * ReplDefs.WORLD_HZ:
		tick_all.call(0, false)
	var join_known: Array = []
	for c: ReplClient in clients:
		join_known.append(c.actors.size())
	var link_out0 := host_link.sent_bytes
	var link_pk0 := host_link.sent_packets
	var net_out0 := _peer_out_total(host_net)

	# --- фаза steady: скриптовое движение, замеры качества
	prof.begin("steady", world.tick)
	var q := {"samples": 0, "visible": 0, "missing": 0, "err_sum": 0.0, "err_max": 0.0, "errs": [], "per_class_err": {}, "per_class_n": {}}
	var peak_known := 0
	for t in seconds * ReplDefs.WORLD_HZ:
		tick_all.call(t, true)
		if t % SAMPLE_EVERY == 0:
			_sample_quality(world, clients, hub.now_us, q)
	var link_out := host_link.sent_bytes - link_out0
	var link_pk := host_link.sent_packets - link_pk0
	var net_out := _peer_out_total(host_net) - net_out0

	var errs: Array = q["errs"]
	errs.sort()
	var p95 := 0.0
	if not errs.is_empty():
		p95 = float(errs[mini(errs.size() - 1, int(float(errs.size()) * 0.95))])
	var per_class_err := {}
	for cls in ReplDefs.NUM_CLASSES:
		var cn: int = q["per_class_n"].get(cls, 0)
		per_class_err[ReplDefs.CLASS_KEYS[cls]] = (float(q["per_class_err"].get(cls, 0.0)) / float(cn)) if cn > 0 else 0.0
	var steady := prof.summary("steady", n_clients)
	var upstream := 0
	for c: ReplClient in clients:
		upstream += _peer_out_total(c.net)
	var result := {
		"config": cfg.name,
		"techniques": cfg.active(),
		"seconds": seconds,
		"clients": n_clients,
		"level_actors": level_actors,
		"actors_at_end": world.count(),
		"checksum": world.checksum(),
		"world_events": {"shots": world.shots, "tree_hits": world.tree_hits, "bot_hits": world.bot_hits, "pickups_taken": world.pickups_taken},
		"join": prof.summary("join", n_clients),
		"join_known": join_known,
		"steady": steady,
		"link_out_bytes": link_out,
		"link_out_packets": link_pk,
		"net_out_bytes_wire": net_out,
		"client_upstream_bytes_wire": upstream,
		"quality": {
			"samples": q["samples"], "visible": q["visible"], "missing": q["missing"],
			"err_avg_px": (float(q["err_sum"]) / float(maxi(q["visible"] - q["missing"], 1))),
			"err_p95_px": p95, "err_max_px": q["err_max"], "per_class_err_px": per_class_err,
		},
		"client_stats": clients[0].stats if not clients.is_empty() else {},
	}
	if keep_session:
		result["session"] = {"world": world, "server": server, "clients": clients, "hub": hub}
	return result


static func _peer_out_total(n: NetNode) -> int:
	var s := 0
	for p: NetNode.Peer in n.peers.values():
		s += p.bytes_out_total
	return s


## Для каждого клиента: акторы сервера в окне камеры (±640 px вокруг своего персонажа) — известны ли клиенту и насколько точно.
static func _sample_quality(world: ReplWorld, clients: Array, now_us: int, q: Dictionary) -> void:
	q["samples"] += 1
	for c: ReplClient in clients:
		if c.client_id < 0:
			continue
		var me: ReplActor = world.actors.get(ReplWorld.PLAYER_BASE + c.client_id)
		if me == null:
			continue
		for id in world.actors.keys():
			var a: ReplActor = world.actors[id]
			if absf(a.x - me.x) > ReplDefs.VIEW_HALF_W or world.tick - a.born_tick < 6:
				continue        # только что появившийся актор доедет за 1–2 сетевых тика — это не «пропажа»
			q["visible"] += 1
			var ca: ReplClient.CActor = c.actors.get(id)
			if ca == null:
				q["missing"] += 1
				continue
			var p := c.pos_at(id, now_us)
			var e := p.distance_to(Vector2(a.x, a.y))
			q["err_sum"] += e
			q["err_max"] = maxf(q["err_max"], e)
			(q["errs"] as Array).append(e)
			q["per_class_err"][a.cls] = float(q["per_class_err"].get(a.cls, 0.0)) + e
			q["per_class_n"][a.cls] = int(q["per_class_n"].get(a.cls, 0)) + 1
