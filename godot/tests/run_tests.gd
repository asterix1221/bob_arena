extends SceneTree
## Автотесты ПР №4 (Godot). Запуск (из корня репозитория):
##   godot --headless --path godot -s res://tests/run_tests.gd
## Проверяют: правила рывка, детерминизм симуляции, серверную защиту от «чужого» ввода,
## эмуляцию сети и ПОЛНЫЙ цикл «предсказание -> сервер -> коррекция -> повтор» на виртуальном
## времени (без сокетов): сравнение «без предсказания / с предсказанием», потери, чит, сходимость.

var passed := 0
var failed := 0
var current := ""


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failed += 1
		print("  FAIL [%s] %s" % [current, msg])


func approx(a: float, b: float, eps: float, msg: String = "") -> void:
	check(absf(a - b) <= eps, "%s: %f != %f (eps %f)" % [msg, a, b, eps])


func run(name: String, fn: Callable) -> void:
	current = name
	var before := failed
	fn.call()
	if failed == before:
		passed += 1
		print("  ok   %s" % name)


# ---------------------------------------------------------------- харнес (виртуальное время)

class Loop:
	## Клиент + сервер + два канала с эмуляцией сети, шаг = один тик 60 Гц.
	var server := ServerSim.new()
	var cp: ClientPredictor
	var up := NetEmu.new(11)       # клиент -> сервер
	var down := NetEmu.new(12)     # сервер -> клиент
	var now := 0.0
	var tick := 0
	var spawn := Vector2(120, 200)

	func _init(lag: float = 0.0, jitter: float = 0.0, loss: float = 0.0, predict: bool = true) -> void:
		server.add_player(1, spawn)
		cp = ClientPredictor.new(spawn)
		cp.predict_dash = predict
		up.configure(lag, jitter, loss)
		down.configure(lag, jitter, loss)

	func step(move: Vector2 = Vector2.ZERO, dash: bool = false) -> void:
		now += 1000.0 / 60.0
		tick += 1
		cp.now_ms = now
		up.poll(now)
		down.poll(now)
		var res := cp.local_input(move, dash)
		var cmds := cp.packet_cmds()
		up.send(now, func(): server.receive_cmds(1, cmds))
		if res["send_dash_request"]:
			up.send(now, func(): server.request_dash(1), true)
		server.tick()
		if tick % 2 == 0:
			var snap := server.owner_snapshot(1)
			down.send(now, func():
				cp.now_ms = now
				cp.on_owner_snapshot(snap))

	func run_ticks(n: int, move: Vector2 = Vector2.ZERO) -> void:
		for _i in n:
			step(move)

	func settle(n: int = 120) -> void:
		run_ticks(n)


func _init() -> void:
	print("== ПР №4 / Godot: автотесты ==")
	# --- правила и симуляция
	run("fresh state allows dash", t_fresh)
	run("dash begin consumes stamina and sets cooldown", t_begin)
	run("second dash during dash rejected", t_already)
	run("dash during cooldown rejected", t_cooldown)
	run("dash without stamina rejected", t_stamina)
	run("stamina regenerates but not above max", t_regen)
	run("cooldown ends after cooldown_ticks", t_cooldown_end)
	run("dash distance = speed * duration", t_distance)
	run("dash direction computed from input, falls back to facing", t_direction)
	run("wall blocks dash (no tunnelling)", t_wall)
	run("arena bounds clamp", t_bounds)
	run("input quantization and clamp (|move| <= 1)", t_quant)
	run("simulation is deterministic", t_determinism)
	# --- серверная защита
	run("server ignores position field in command", t_no_pos)
	run("server clamps oversized move vector", t_clamp)
	run("server drops duplicate/old commands", t_dups)
	run("server rate-limits commands (speed hack)", t_rate)
	run("server fills gap with held input", t_gap)
	run("server rejects malformed commands", t_malformed)
	# --- сеть
	run("netemu delays by lag", t_emu_lag)
	run("netemu loss rate close to configured", t_emu_loss)
	run("netemu reliable ignores loss", t_emu_reliable)
	run("netemu delivers in order of due time", t_emu_order)
	# --- предсказание и коррекция
	run("no lag: no corrections, client == server", t_nolag)
	run("lag 100: prediction has no corrections on plain movement", t_lag_move)
	run("lag 100: dash response local ~0 ms vs no-prediction ~RTT", t_response)
	run("lag 100: prediction confirmed by server after ~RTT", t_confirm)
	run("lag 175+jitter+4% loss: client converges to server", t_loss_converge)
	run("cheat (ignore cooldown) -> server rejects -> correction -> converge after cheat off", t_cheat)
	run("cheat speed x3 -> distance mismatch corrected", t_cheat_speed)
	run("server rejection is reported to client", t_reject_report)
	run("overlapping key presses: responses matched in press order", t_overlap)
	run("reconciliation replays pending commands (exact state)", t_replay_exact)
	run("owner snapshot ignored if older than last ack", t_old_snapshot)
	run("remote interpolation lerps between snapshots", t_interp)
	run("bot scenarios produce inputs and finish", t_bots)

	print("---")
	print("%d тестов, %d провалено" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- тесты правил

func _st(pos := Vector2(300, 300)) -> PlayerState:
	var s := PlayerState.new()
	s.pos = pos
	s.stamina = 100.0
	return s


func _cmd(seq: int, move: Vector2, dash: bool) -> Dictionary:
	return PlayerSim.make_cmd(seq, move, dash)


func t_fresh() -> void:
	check(DashRules.validate(_st(), DashRules.default_cfg()) == "", "fresh")


func t_begin() -> void:
	var s := _st(); var c := DashRules.default_cfg()
	DashRules.begin(s, c, Vector2.RIGHT)
	approx(s.stamina, 65.0, 0.001, "stamina")
	check(s.cooldown_left == 72 and s.dash_left == 11 and s.dash_count == 1, "timers")


func t_already() -> void:
	var s := _st(); var c := DashRules.default_cfg()
	DashRules.begin(s, c, Vector2.RIGHT)
	check(DashRules.validate(s, c) == "already_dashing")


func t_cooldown() -> void:
	var s := _st(); var c := DashRules.default_cfg()
	DashRules.begin(s, c, Vector2.RIGHT)
	for _i in 12:
		DashRules.tick_timers(s, c, s.dash_left > 0)
	check(s.dash_left == 0)
	check(DashRules.validate(s, c) == "cooldown")


func t_stamina() -> void:
	var s := _st(); var c := DashRules.default_cfg()
	s.stamina = 34.0
	check(DashRules.validate(s, c) == "no_stamina")


func t_regen() -> void:
	var s := _st(); var c := DashRules.default_cfg()
	s.stamina = 0.0
	for _i in 60:
		DashRules.tick_timers(s, c, false)
	approx(s.stamina, 25.0, 0.01, "1 s regen")
	for _i in 1000:
		DashRules.tick_timers(s, c, false)
	approx(s.stamina, 100.0, 0.0001, "cap")


func t_cooldown_end() -> void:
	var s := _st(); var c := DashRules.default_cfg()
	DashRules.begin(s, c, Vector2.RIGHT)
	for _i in 72:
		DashRules.tick_timers(s, c, s.dash_left > 0)
	check(DashRules.validate(s, c) == "")


func t_distance() -> void:
	var s := _st(Vector2(100, 100)); var c := DashRules.default_cfg()
	PlayerSim.step(s, _cmd(1, Vector2.RIGHT, true), c)
	for i in 10:
		PlayerSim.step(s, _cmd(2 + i, Vector2.ZERO, false), c)
	approx(s.pos.x - 100.0, 900.0 * 11.0 / 60.0, 0.5, "distance")
	approx(s.pos.y, 100.0, 0.001, "no drift")


func t_direction() -> void:
	var c := DashRules.default_cfg()
	var s := _st(Vector2(100, 400))
	PlayerSim.step(s, _cmd(1, Vector2.DOWN, true), c)
	check(s.dash_dir.is_equal_approx(Vector2.DOWN), "input dir")
	var s2 := _st(Vector2(300, 300))
	PlayerSim.step(s2, _cmd(1, Vector2.LEFT, false), c)      # facing = LEFT
	PlayerSim.step(s2, _cmd(2, Vector2.ZERO, true), c)       # без ввода -> по facing
	check(s2.dash_dir.is_equal_approx(Vector2.LEFT), "facing fallback")


func t_wall() -> void:
	var c := DashRules.default_cfg()
	var s := _st(Vector2(560, 300))                           # стена по x=620..660
	PlayerSim.step(s, _cmd(1, Vector2.RIGHT, true), c)
	for i in 30:
		PlayerSim.step(s, _cmd(2 + i, Vector2.RIGHT, false), c)
	check(s.pos.x <= 620.0 - c["radius"] + 0.01, "stopped before wall, x=%f" % s.pos.x)


func t_bounds() -> void:
	var c := DashRules.default_cfg()
	var s := _st(Vector2(20, 20))
	for i in 60:
		PlayerSim.step(s, _cmd(i + 1, Vector2(-1, -1), false), c)
	check(s.pos.x >= c["radius"] - 0.001 and s.pos.y >= c["radius"] - 0.001)


func t_quant() -> void:
	var cmd := PlayerSim.make_cmd(1, Vector2(5, 5), false)
	check(Vector2(cmd["mx"], cmd["my"]).length() <= 127.5, "limited")
	var cmd2 := PlayerSim.make_cmd(2, Vector2(0.5, 0), false)
	check(cmd2["mx"] == 64 or cmd2["mx"] == 63, "quantized %d" % cmd2["mx"])


func t_determinism() -> void:
	var c := DashRules.default_cfg()
	var a := _st(); var b := _st()
	for i in 300:
		var mv := Vector2(sin(i * 0.1), cos(i * 0.07))
		var cmd := _cmd(i + 1, mv, i % 50 == 0)
		PlayerSim.step(a, cmd, c)
		PlayerSim.step(b, cmd, c)
	check(a.pos == b.pos and a.stamina == b.stamina and a.cooldown_left == b.cooldown_left, "identical")


# ---------------------------------------------------------------- серверная защита

func t_no_pos() -> void:
	var sv := ServerSim.new(); sv.add_player(5, Vector2(100, 100))
	sv.receive_cmds(5, [{"seq": 1, "mx": 0, "my": 0, "dash": false, "pos": Vector2(1000, 600), "x": 999}])
	sv.tick()
	check(sv.players[5]["state"].pos.is_equal_approx(Vector2(100, 100)), "teleport ignored")


func t_clamp() -> void:
	var sv := ServerSim.new(); sv.add_player(5, Vector2(100, 100))
	sv.receive_cmds(5, [{"seq": 1, "mx": 100000, "my": 0, "dash": false}])
	sv.tick()
	var moved: float = sv.players[5]["state"].pos.x - 100.0
	approx(moved, 220.0 / 60.0, 0.01, "max walk step")


func t_dups() -> void:
	var sv := ServerSim.new(); sv.add_player(5, Vector2(100, 100))
	var c1 := PlayerSim.make_cmd(1, Vector2.RIGHT, false)
	sv.receive_cmds(5, [c1, c1, c1])
	sv.tick()
	sv.receive_cmds(5, [c1])
	sv.tick()
	check(sv.stats["dup_cmds"] >= 3, "dups counted %d" % sv.stats["dup_cmds"])
	approx(sv.players[5]["state"].pos.x - 100.0, 220.0 / 60.0, 0.01, "applied once")


func t_rate() -> void:
	var sv := ServerSim.new(); sv.add_player(5, Vector2(100, 100))
	var cmds: Array = []
	for i in 30:
		cmds.append(PlayerSim.make_cmd(i + 1, Vector2.RIGHT, false))
	sv.receive_cmds(5, cmds)                  # 30 команд одним пакетом («ускорение времени»)
	sv.tick()
	var moved: float = sv.players[5]["state"].pos.x - 100.0
	check(moved <= 220.0 / 60.0 * 2.01, "at most ~2 commands in first tick, moved %f" % moved)
	for _i in 4:
		sv.tick()
	moved = sv.players[5]["state"].pos.x - 100.0
	check(moved <= 220.0 / 60.0 * (1 + 5 + 0.01), "never faster than credit allows")


func t_gap() -> void:
	var sv := ServerSim.new(); sv.add_player(5, Vector2(100, 100))
	sv.receive_cmds(5, [PlayerSim.make_cmd(1, Vector2.RIGHT, false), PlayerSim.make_cmd(5, Vector2.RIGHT, false)])
	for _i in 4:
		sv.tick()
	check(sv.stats["gap_fills"] == 3, "filled 3 missing, got %d" % sv.stats["gap_fills"])
	check(sv.players[5]["last_seq"] == 5)


func t_malformed() -> void:
	var sv := ServerSim.new(); sv.add_player(5, Vector2(100, 100))
	sv.receive_cmds(5, ["junk", 42, {"mx": 1}, {"seq": "x"}])
	check(sv.stats["rejected_cmds"] == 4, "rejected %d" % sv.stats["rejected_cmds"])
	sv.receive_cmds(99, [PlayerSim.make_cmd(1, Vector2.RIGHT, false)])    # неизвестный peer — без падения


# ---------------------------------------------------------------- эмуляция сети

func t_emu_lag() -> void:
	var e := NetEmu.new(1); e.configure(100.0, 0.0, 0.0)
	var box := [0]
	e.send(0.0, func(): box[0] += 1)
	e.poll(99.0); check(box[0] == 0, "not yet")
	e.poll(100.0); check(box[0] == 1, "delivered")


func t_emu_loss() -> void:
	var e := NetEmu.new(3); e.configure(0.0, 0.0, 5.0)
	var box := [0]
	for i in 4000:
		e.send(0.0, func(): box[0] += 1)
	e.poll(1.0)
	var rate := float(e.dropped) / 4000.0 * 100.0
	check(rate > 3.5 and rate < 6.5, "loss %f%%" % rate)
	check(box[0] + e.dropped == 4000, "accounted")


func t_emu_reliable() -> void:
	var e := NetEmu.new(3); e.configure(0.0, 0.0, 100.0)
	var box := [0]
	for i in 50:
		e.send(0.0, func(): box[0] += 1, true)
	e.poll(1.0)
	check(box[0] == 50 and e.dropped == 0)


func t_emu_order() -> void:
	var e := NetEmu.new(3); e.configure(0.0, 0.0, 0.0)
	var got: Array = []
	e.lag_ms = 200.0; e.send(0.0, func(): got.append("slow"))
	e.lag_ms = 50.0; e.send(0.0, func(): got.append("fast"))
	e.poll(300.0)
	check(got == ["fast", "slow"], str(got))


# ---------------------------------------------------------------- предсказание/коррекция

func t_nolag() -> void:
	var lp := Loop.new(0.0)
	lp.run_ticks(60, Vector2.RIGHT)
	lp.step(Vector2.RIGHT, true)
	lp.run_ticks(60, Vector2.DOWN)
	lp.settle()
	check(lp.cp.corrections == 0, "corrections %d" % lp.cp.corrections)
	check(lp.cp.state.pos.distance_to(lp.server.players[1]["state"].pos) < 0.01, "same pos")


func t_lag_move() -> void:
	var lp := Loop.new(100.0)
	lp.run_ticks(90, Vector2.RIGHT)
	lp.run_ticks(60, Vector2(0, 1))
	lp.run_ticks(60, Vector2(-1, 0))
	lp.settle()
	check(lp.cp.corrections == 0, "plain movement needs no corrections, got %d" % lp.cp.corrections)


func _dash_experiment(predict: bool) -> Loop:
	var lp := Loop.new(100.0, 0.0, 0.0, predict)
	lp.run_ticks(30, Vector2.RIGHT)
	lp.step(Vector2.RIGHT, true)
	lp.run_ticks(60, Vector2.RIGHT)
	lp.settle()
	return lp


func t_response() -> void:
	var p := _dash_experiment(true)
	var b := _dash_experiment(false)
	check(p.cp.local_response_ms.size() == 1, "prediction local sample")
	check(p.cp.local_response_ms[0] <= 20.0, "predicted local response %f" % p.cp.local_response_ms[0])
	check(b.cp.local_response_ms.is_empty(), "baseline has no local response")
	check(b.cp.confirm_response_ms.size() == 1, "baseline visible response sample")
	var rtt_ms: float = b.cp.confirm_response_ms[0]
	check(rtt_ms >= 200.0 and rtt_ms <= 290.0, "baseline response ~RTT (200 ms + snapshot period), got %f" % rtt_ms)


func t_confirm() -> void:
	var p := _dash_experiment(true)
	check(p.cp.confirm_response_ms.size() == 1)
	check(p.cp.confirm_response_ms[0] >= 200.0 and p.cp.confirm_response_ms[0] <= 290.0, "confirm %f" % p.cp.confirm_response_ms[0])
	check(p.cp.state.pos.distance_to(p.server.players[1]["state"].pos) < 0.01, "converged")


func t_loss_converge() -> void:
	var lp := Loop.new(175.0, 25.0, 4.0)
	lp.run_ticks(60, Vector2.RIGHT)
	lp.step(Vector2.RIGHT, true)
	lp.run_ticks(100, Vector2(1, 1))
	lp.step(Vector2.ZERO, true)
	lp.run_ticks(100, Vector2(-1, 0.3))
	lp.settle(240)
	var err := lp.cp.state.pos.distance_to(lp.server.players[1]["state"].pos)
	check(err < 0.5, "final error %f px (corrections %d)" % [err, lp.cp.corrections])
	check(lp.server.players[1]["last_seq"] >= lp.tick - 30, "server kept up")


func t_cheat() -> void:
	var lp := Loop.new(100.0)
	lp.run_ticks(30, Vector2.RIGHT)
	lp.step(Vector2.RIGHT, true)                  # честный рывок
	lp.cp.set_cheat(true, 1.0)
	lp.run_ticks(15, Vector2.RIGHT)
	lp.step(Vector2.RIGHT, true)                  # рывок до кулдауна: клиент «разрешил», сервер нет
	lp.run_ticks(60, Vector2.RIGHT)
	check(lp.server.stats["dash_rejects"] >= 1, "server rejected cheated dash")
	check(lp.cp.corrections >= 1, "client was corrected (%d)" % lp.cp.corrections)
	check(lp.cp.max_error > 1.0, "visible error %f" % lp.cp.max_error)
	lp.cp.set_cheat(false, 1.0)
	lp.settle(240)
	var err := lp.cp.state.pos.distance_to(lp.server.players[1]["state"].pos)
	check(err < 0.5, "converged after cheat off, err %f" % err)


func t_cheat_speed() -> void:
	var lp := Loop.new(100.0)
	lp.cp.set_cheat(true, 3.0)
	lp.run_ticks(20, Vector2.RIGHT)
	lp.step(Vector2.RIGHT, true)
	lp.run_ticks(40, Vector2.RIGHT)
	check(lp.cp.corrections >= 1, "speed cheat caught")
	lp.cp.set_cheat(false, 1.0)
	lp.settle(240)
	check(lp.cp.state.pos.distance_to(lp.server.players[1]["state"].pos) < 0.5, "converged")


func t_reject_report() -> void:
	var lp := Loop.new(50.0)
	lp.run_ticks(10, Vector2.RIGHT)
	lp.step(Vector2.RIGHT, true)
	lp.run_ticks(20, Vector2.RIGHT)
	lp.step(Vector2.RIGHT, true)                  # кулдаун ещё идёт — оба откажут
	lp.run_ticks(30, Vector2.RIGHT)
	check(lp.cp.rejects_seen >= 1, "owner informed of rejection")
	var found := false
	for e in lp.cp.events:
		if "REJECTED" in e and "cooldown" in e:
			found = true
	check(found, "log line with reason")


func t_overlap() -> void:
	var lp := Loop.new(100.0)
	lp.run_ticks(10, Vector2.RIGHT)
	lp.step(Vector2.RIGHT, true)                  # принят
	lp.run_ticks(5, Vector2.RIGHT)
	lp.step(Vector2.RIGHT, true)                  # до кулдауна: будет отказ
	lp.run_ticks(60, Vector2.RIGHT)
	check(lp.cp.confirm_response_ms.size() == 1, "one confirmation")
	check(lp.cp.confirm_response_ms[0] >= 200.0, "first press measured from ITS key press, got %f" % lp.cp.confirm_response_ms[0])
	check(lp.cp.key_queue.is_empty(), "queue drained")


func t_replay_exact() -> void:
	var lp := Loop.new(100.0)
	lp.cp.set_cheat(true, 3.0)
	lp.step(Vector2.RIGHT, true)
	lp.run_ticks(5, Vector2.RIGHT)
	lp.cp.set_cheat(false, 1.0)
	lp.run_ticks(60, Vector2.RIGHT)
	# к моменту после коррекции клиентское состояние = серверное + повтор неподтверждённых команд
	var srv: PlayerState = lp.cp.last_server_state
	var replay := srv.duplicate_state()
	for cmd in lp.cp.pending:
		PlayerSim.step(replay, cmd, lp.cp.cfg)
	if lp.cp.corrections > 0 and lp.cp.last_ack == lp.cp.pending[0]["seq"] - 1:
		check(replay.pos.distance_to(lp.cp.state.pos) < 0.05, "replay == state (%f)" % replay.pos.distance_to(lp.cp.state.pos))


func t_old_snapshot() -> void:
	var lp := Loop.new(0.0)
	lp.run_ticks(10, Vector2.RIGHT)
	var ack_before := lp.cp.last_ack
	var old := {"ack": ack_before - 3, "state": PlayerState.new().to_dict(), "rej": 0, "why": "", "tick": 1}
	lp.cp.on_owner_snapshot(old)
	check(lp.cp.last_ack == ack_before and lp.cp.corrections == 0, "stale snapshot ignored")


func t_interp() -> void:
	var r := RemoteInterp.new()
	r.push(10, Vector2(0, 0), false, 0.0)
	r.push(20, Vector2(100, 0), false, 0.0)
	# через 6 тиков отставания: est = 20 + 0; rt = 14 -> t = 0.4
	var p := r.sample(0.0)
	approx(p.x, 40.0, 0.01, "lerp")
	r.push(20, Vector2(999, 0), false, 0.0)          # дубликат тика игнорируется
	check(r.buf.size() == 2)


func t_bots() -> void:
	for name in ["walk", "dash_latency", "loss_mix", "cheat", "wall"]:
		var b := Bot.new(name)
		var moved := false
		var dashed := false
		for t in b.duration_ticks + 1:
			var s := b.sample(t)
			moved = moved or s["move"] != Vector2.ZERO
			dashed = dashed or s["dash"]
		check(moved and dashed, "bot %s moves and dashes" % name)
		check(b.sample(b.duration_ticks)["done"], "bot %s finishes" % name)
