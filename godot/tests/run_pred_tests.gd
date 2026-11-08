extends SceneTree
## Тесты ПР №4 на новой игре: предсказание рывка вкл/выкл, замеры отклика, чит и серверная коррекция, путь предсказания
## для визуализации, сценарии T1–T5 в виртуальном времени (детерминированно).
##   godot --headless --path godot -s res://tests/run_pred_tests.gd

var passed := 0
var failed := 0
var current := ""
const TICK_US := 8333


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failed += 1
		print("  FAIL [%s] %s" % [current, msg])


func run(name: String, fn: Callable) -> void:
	current = name
	var before := failed
	fn.call()
	if failed == before:
		passed += 1
		print("  ok   %s" % name)


func _init() -> void:
	print("== Предсказание рывка и замеры ==")
	run("с предсказанием: рывок виден в тот же тик, сервер подтверждает через ~RTT", t_predict_on)
	run("без предсказания: на экране рывка нет, пока не ответил сервер; отклик ≈ RTT", t_predict_off)
	run("без предсказания: повтор команд после коррекции не «выстреливает» рывок раньше сервера", t_off_replay)
	run("переключение предсказания на лету (F4) работает", t_toggle)
	print("== Чит и коррекция ==")
	run("чит: сервер отклоняет рывок, клиент исправляется и сходится с сервером", t_cheat)
	print("== Данные визуализации ==")
	run("путь предсказания: точка сервера + по точке на неподтверждённую команду", t_path)
	run("режимы визуализации: прозрачность предсказанного персонажа", t_viz_modes)
	print("== Сценарии T1–T5 (виртуальное время) ==")
	run("T2/T3: без предсказания отклик ≈ RTT, с предсказанием ≈ 0, число рывков одинаково", t_scn_t2_t3)
	run("T4: потери 4% и джиттер — рывки принимаются, лишний отклоняется, клиент сходится", t_scn_t4)
	run("T5: чит — ровно 3 отказа сервера, коррекции, итог совпал с сервером", t_scn_t5)
	print("\n%d тестов, %d провалено" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)


class World:
	var hub := LoopHub.new()
	var host_link: LoopLink
	var host: GameHost
	var clients: Array = []
	var bots: Array = []
	var lag := 0.0
	var jitter := 0.0
	var loss := 0.0
	var ticks := 0

	func _init(lag_ms: float = 0.0, jitter_ms: float = 0.0, loss_fraction: float = 0.0, seed_value: int = 5) -> void:
		lag = lag_ms
		jitter = jitter_ms
		loss = loss_fraction
		host_link = LoopLink.new(hub, seed_value)
		host_link.set_emulation(lag, jitter, loss)
		host = GameHost.new(NetNode.new(host_link), seed_value)

	func add_client(name: String) -> GameClient:
		var l := LoopLink.new(hub, 100 + clients.size())
		l.set_emulation(lag, jitter, loss)
		var n := NetNode.new(l)
		n.add_peer(host_link.link_id)
		var c := GameClient.new(n, host_link.link_id)
		clients.append(c)
		bots.append(func(_c: GameClient, _t: int) -> Array: return [0, 0])
		c.join(name, clients.size() - 1)
		return c

	func step(n: int = 1) -> void:
		for i in n:
			ticks += 1
			hub.advance_us(TICK_US)
			for k in clients.size():
				var c: GameClient = clients[k]
				c.process_net()
				var cmd: Array = bots[k].call(c, ticks)
				c.local_tick(cmd[0], cmd[1])
			host.tick_once()

	func start_and_play() -> void:
		step(200)
		host.start_match()
		step(GC.COUNTDOWN_TICKS + 120)

	func server_state(i: int) -> PState:
		return host.slots[i].state


## Бот: одно нажатие рывка на тике press_at (счёт от вызова), дальше стоит.
func dash_once(press_at: int, axis: int = 127) -> Callable:
	var st := {"n": 0}
	return func(_c: GameClient, _t: int) -> Array:
		st["n"] += 1
		return [axis, Proto.BTN_DASH] if st["n"] == press_at else [axis, 0]


func t_predict_on() -> void:
	var w := World.new(100.0)
	var a := w.add_client("A")
	w.add_client("B")
	w.start_and_play()
	a.predict_dash = true
	w.bots[0] = dash_once(1)
	w.step(1)
	check(a.state.dash_left > 0, "рывок предсказан в тот же тик")
	w.bots[0] = func(_c: GameClient, _t: int) -> Array: return [0, 0]
	w.step(120)
	check(a.dash_accepted == 1 and a.dash_denied == 0, "принят %d / отклонён %d" % [a.dash_accepted, a.dash_denied])
	check(a.local_response_ms.size() == 1 and a.local_response_ms[0] < 10.0, "на экране сразу: %s мс" % str(a.local_response_ms))
	check(a.confirm_response_ms.size() == 1 and a.confirm_response_ms[0] > 150.0 and a.confirm_response_ms[0] < 320.0, "подтверждение ≈ RTT 200 мс: %s" % str(a.confirm_response_ms))
	check(a.corrections == 0, "без расхождений при честной игре: %d коррекций" % a.corrections)


func t_predict_off() -> void:
	var w := World.new(100.0)
	var a := w.add_client("A")
	w.add_client("B")
	w.start_and_play()
	a.predict_dash = false
	w.bots[0] = dash_once(1)
	w.step(1)
	check(a.state.dash_left == 0 and a.dash_accepted == 0, "в тот же тик рывка на экране нет")
	w.bots[0] = func(_c: GameClient, _t: int) -> Array: return [0, 0]
	w.step(10)      # 83 мс < RTT: ответа сервера ещё нет
	check(a.state.dash_left == 0, "через 83 мс всё ещё нет (ждём сервер)")
	w.step(60)
	check(a.dash_accepted == 1, "сервер принял и клиент это увидел")
	check(a.local_response_ms.size() == 1 and a.local_response_ms[0] > 150.0, "отклик ≈ RTT, а не 0: %s мс" % str(a.local_response_ms))
	check(is_equal_approx(a.local_response_ms[0], a.confirm_response_ms[0]), "на экране = подтверждение")
	check(a.corrections >= 1, "в момент подтверждения клиент «догоняет» рывок коррекцией")
	w.step(300)
	check(a.state.equals(w.server_state(0)), "итог совпал с сервером")


func t_off_replay() -> void:
	var w := World.new(100.0)
	var a := w.add_client("A")
	w.add_client("B")
	w.start_and_play()
	a.predict_dash = false
	w.bots[0] = dash_once(1)
	w.step(1)
	w.bots[0] = const_bot(127)
	# пока ответа нет, любая коррекция/повтор не должна включать рывок у клиента раньше подтверждения
	var early := false
	for i in 20:
		w.step(1)
		if a.dash_accepted == 0 and a.state.dash_left > 0:
			early = true
	check(not early, "до ответа сервера рывок у клиента не появлялся")


func const_bot(axis: int, buttons: int = 0) -> Callable:
	return func(_c: GameClient, _t: int) -> Array: return [axis, buttons]


func t_toggle() -> void:
	var w := World.new(60.0)
	var a := w.add_client("A")
	w.add_client("B")
	w.start_and_play()
	a.predict_dash = false
	w.bots[0] = dash_once(1)
	w.step(1)
	check(a.state.dash_left == 0, "выкл: нет")
	w.bots[0] = const_bot(0)
	w.step(400)       # дождались кулдауна
	a.predict_dash = true
	w.bots[0] = dash_once(1)
	w.step(1)
	check(a.state.dash_left > 0, "вкл: рывок сразу")
	w.bots[0] = const_bot(0)
	w.step(300)
	check(a.dash_accepted == 2 and a.state.equals(w.server_state(0)), "оба рывка приняты, состояния совпали")


func t_cheat() -> void:
	var w := World.new(50.0)
	var a := w.add_client("A")
	w.add_client("B")
	w.start_and_play()
	var rej := {"n": 0}
	w.host.dash_rejected.connect(func(_id: int, _r: String) -> void: rej["n"] += 1)
	w.bots[0] = dash_once(1)
	w.step(60)
	w.bots[0] = const_bot(0)
	w.step(40)      # кулдаун сервера (144 тика) ещё идёт
	check(a.dash_accepted == 1, "честный рывок принят")
	var corr0 := a.corrections
	a.cheat_no_rules = true
	w.bots[0] = dash_once(1)
	w.step(1)
	check(a.state.dash_left > 0, "локально читерский рывок предсказан")
	a.cheat_no_rules = false
	w.bots[0] = const_bot(0)
	w.step(300)
	check(rej["n"] == 1, "сервер отклонил ровно один рывок (%d)" % rej["n"])
	check(a.dash_denied == 1, "клиент узнал об отказе (%d)" % a.dash_denied)
	check(a.corrections > corr0, "клиент получил коррекцию")
	check(a.state.equals(w.server_state(0)), "клиент вернулся к серверному состоянию")


func t_path() -> void:
	var w := World.new(100.0)
	var a := w.add_client("A")
	w.add_client("B")
	w.start_and_play()
	w.bots[0] = const_bot(127)
	w.step(30)
	var path := a.pending_path()
	check(a.pending.size() > 3, "есть неподтверждённые команды (%d)" % a.pending.size())
	check(path.size() == a.pending.size() + 1, "путь %d точек при %d неподтверждённых" % [path.size(), a.pending.size()])
	check(path[0].is_equal_approx(Vector2(a.last_server_state.x, a.last_server_state.y) / float(GC.SUB)), "путь начинается в точке сервера")
	check(path[path.size() - 1].is_equal_approx(Vector2(a.state.x, a.state.y) / float(GC.SUB)), "путь заканчивается в предсказанной точке")
	check(a.prediction_lead_px() > 5.0, "клиент опережает сервер на %.1f px" % a.prediction_lead_px())
	w.bots[0] = const_bot(0)
	w.step(400)
	check(a.prediction_lead_px() < 0.5, "после остановки опережение исчезло (%.2f px)" % a.prediction_lead_px())


func t_viz_modes() -> void:
	check(PredViz.local_alpha(PredViz.OFF) == 1.0 and PredViz.local_alpha(PredViz.GHOST) == 1.0, "в выкл и призраке персонаж плотный")
	check(PredViz.local_alpha(PredViz.FADED) < 1.0 and PredViz.local_alpha(PredViz.FULL) < 1.0, "в FADED/FULL предсказанный полупрозрачный")
	check(PredViz.NAMES.size() == 4, "четыре режима")


func _scenario(case_id: String, lag: float, jitter: float, loss: float, predict: bool, seed_value: int) -> Array:
	var w := World.new(lag, jitter, loss, seed_value)
	var a := w.add_client("A")
	w.add_client("B")
	w.step(200)
	var brain := ScenarioBrain.new(String(Scenario.CASES[case_id]["brain"]))
	a.predict_dash = predict
	w.bots[0] = func(c: GameClient, _t: int) -> Array: return brain.think(c)
	w.host.start_match()
	var guard := 0
	while not brain.done and guard < 40000:
		w.step(1)
		guard += 1
	w.step(400)
	return [w, a]


func t_scn_t2_t3() -> void:
	var r2 := _scenario("T2", 100.0, 0.0, 0.0, false, 5)
	var r3 := _scenario("T3", 100.0, 0.0, 0.0, true, 5)
	var a2: GameClient = r2[1]
	var a3: GameClient = r3[1]
	check(a2.dash_accepted == 5 and a3.dash_accepted == 5, "по 5 принятых рывков (%d / %d)" % [a2.dash_accepted, a3.dash_accepted])
	var avg2 := _avg(a2.local_response_ms)
	var avg3 := _avg(a3.local_response_ms)
	check(avg2 > 150.0, "без предсказания на экране через %.0f мс" % avg2)
	check(avg3 < 10.0, "с предсказанием на экране через %.1f мс" % avg3)
	check(a3.corrections == 0, "с предсказанием при честной игре 0 коррекций (%d)" % a3.corrections)
	check(a2.corrections >= 5, "без предсказания коррекция на каждый рывок (%d)" % a2.corrections)
	check(_same_motion(a3, (r3[0] as World).server_state(0)) and _same_motion(a2, (r2[0] as World).server_state(0)), "оба сошлись с сервером")


func t_scn_t4() -> void:
	var r := _scenario("T4", 175.0, 25.0, 0.04, true, 9)
	var a: GameClient = r[1]
	check(a.dash_accepted == 5 and a.dash_denied == 1, "принято %d / отклонено %d (ожидалось 5 / 1)" % [a.dash_accepted, a.dash_denied])
	check(a.prediction_lead_px() < 0.5, "итоговое расхождение %.2f px" % a.prediction_lead_px())
	check(_same_motion(a, (r[0] as World).server_state(0)), "положение и рывок совпали с серверными")


func t_scn_t5() -> void:
	var r := _scenario("T5", 175.0, 25.0, 0.04, true, 9)
	var a: GameClient = r[1]
	check(a.dash_denied == 3 and a.dash_accepted == 5, "принято %d / отклонено %d (ожидалось 5 / 3)" % [a.dash_accepted, a.dash_denied])
	check(a.corrections >= 3, "коррекций %d" % a.corrections)
	check((r[0] as World).host.slots[0].dash_rejects == 3, "сервер отклонил 3 рывка")
	check(_same_motion(a, (r[0] as World).server_state(0)), "положение и рывок совпали с серверными")


## Положение, скорость и рывок совпали. Таймеры рун/регенерации не сравниваем: клиент по определению «впереди» сервера на
## неподтверждённые команды (≈ RTT), поэтому долгие таймеры (руны 15 с) у них отличаются на эти тики.
func _same_motion(c: GameClient, sv: PState) -> bool:
	return c.state.x == sv.x and c.state.y == sv.y and c.state.vx == sv.vx and c.state.vy == sv.vy and c.state.dash_left == sv.dash_left and c.state.alive == sv.alive


func _avg(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += float(v)
	return s / float(a.size())
