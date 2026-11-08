extends SceneTree
## Интеграционные тесты игры по сети: GameHost + GameClient поверх NetNode/LoopHub (виртуальное время, без сокетов).
##   godot --headless --path godot -s res://tests/run_game_net_tests.gd
## Один тик = 1/120 с (8333 мкс). Потери/задержки/джиттер эмулирует Link (датаграммы, обе стороны).

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
	print("== Вход, лобби, отсчёт ==")
	run("вход двух игроков: id, уникальные цвета, ростер с кириллицей", t_join)
	run("5-й игрок и вход во время матча отклоняются", t_full)
	run("старт матча: отсчёт 3-2-1 доходит до клиентов, затем игра", t_start)
	print("== Предсказание и сверка ==")
	run("простой без ввода: 0 коррекций при лаге и потерях", t_idle)
	run("ходьба: отклик мгновенный, итог совпадает с сервером", t_walk)
	run("сервер не доверяет клиенту: подмена позиции исправляется", t_teleport)
	run("рывок: предсказан сразу; запрещённый (кулдаун) отклоняется сервером и исправляется", t_dash_cheat)
	run("мусорный ввод санитизируется, будущие команды отбрасываются", t_bad_input)
	print("== Матч ==")
	run("бой до победителя: ROUND_END и статистика у обоих, ровно по разу при 30%% потерь", t_fight)
	run("падение с арены: смерть, победа соперника", t_fall)
	run("руна: подбор, событие, эффект виден клиенту", t_rune)
	run("реванш: возврат в лобби", t_rematch)
	run("обрыв клиента: слот освобождается, победа оставшегося", t_disconnect)
	print("\n%d тестов, %d провалено" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)


# ------------------------------------------------------------------ стенд

class World:
	var hub := LoopHub.new()
	var host_link: LoopLink
	var host: GameHost
	var clients: Array = []     # GameClient
	var nets: Array = []        # NetNode клиентов
	var links: Array = []
	var bots: Array = []        # Callable(client, tick) -> [axis, buttons]
	var lag := 0.0
	var jitter := 0.0
	var loss := 0.0
	var ticks := 0
	var events: Array = []      # [client_index, kind, a, b, v]

	func _init(lag_ms: float = 0.0, jitter_ms: float = 0.0, loss_fraction: float = 0.0, seed_value: int = 5) -> void:
		lag = lag_ms
		jitter = jitter_ms
		loss = loss_fraction
		host_link = LoopLink.new(hub, seed_value)
		host_link.set_emulation(lag, jitter, loss)
		host = GameHost.new(NetNode.new(host_link), seed_value)

	func add_client(name: String, color: int = 0) -> GameClient:
		var l := LoopLink.new(hub, 100 + clients.size())
		l.set_emulation(lag, jitter, loss)
		var n := NetNode.new(l)
		n.add_peer(host_link.link_id)
		var c := GameClient.new(n, host_link.link_id)
		var idx := clients.size()
		c.event.connect(func(k: int, a: int, b: int, _x: int, _y: int, v: int) -> void: events.append([idx, k, a, b, v]))
		clients.append(c)
		nets.append(n)
		links.append(l)
		bots.append(func(_c: GameClient, _t: int) -> Array: return [0, 0])
		c.join(name, color)
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

	func count_events(client_idx: int, kind: int) -> int:
		var n := 0
		for e in events:
			if e[0] == client_idx and e[1] == kind:
				n += 1
		return n

	func start_and_play() -> void:
		host.start_match()
		step(GC.COUNTDOWN_TICKS + 120)


func idle_bot() -> Callable:
	return func(_c: GameClient, _t: int) -> Array: return [0, 0]


func const_bot(axis: int, buttons: int = 0) -> Callable:
	return func(_c: GameClient, _t: int) -> Array: return [axis, buttons]


## Бот-боец: бежит к ближайшему противнику, бьёт в упор.
func chaser_bot() -> Callable:
	var st := {"n": 0}
	return func(c: GameClient, _t: int) -> Array:
		st["n"] += 1
		var me := c.state
		var best := {}
		var best_d := 1e9
		for id in c.pub.keys():
			if id == c.my_id:
				continue
			var e: Dictionary = c.pub[id]
			if int(e["flags"]) & 1 == 0:
				continue
			var d := absf(e["x"] - me.x / 256.0)
			if d < best_d:
				best_d = d
				best = e
		if best.is_empty():
			return [0, 0]
		var dx: float = best["x"] - me.x / 256.0
		var axis := 0
		if dx > 25.0: axis = 127
		elif dx < -25.0: axis = -127
		var buttons := 0
		if absf(dx) < 70.0 and st["n"] % 14 == 0:
			buttons = Proto.BTN_LIGHT if st["n"] % 56 != 0 else Proto.BTN_HEAVY
		return [axis, buttons]


# ------------------------------------------------------------------ тесты

func t_join() -> void:
	var w := World.new(20.0)
	var a := w.add_client("Алиса", 0)
	var b := w.add_client("Боб", 0)       # просит тот же цвет — получит другой
	w.step(240)
	check(a.my_id == 0 and b.my_id == 1, "id: %d, %d" % [a.my_id, b.my_id])
	check(a.roster.size() == 2 and b.roster.size() == 2, "ростер у обоих")
	check(a.roster[0]["name"] == "Алиса" and a.roster[1]["name"] == "Боб", "имена с кириллицей: %s" % str(a.roster))
	check(a.roster[0]["color"] != a.roster[1]["color"], "цвета уникальны")
	check(b.server_status == Proto.WELCOME_OK, "Welcome ok")


func t_full() -> void:
	var w := World.new(10.0)
	var cs := []
	for i in 5:
		cs.append(w.add_client("P%d" % i, i))
	var rejected_status := {"v": -1}
	cs[4].rejected.connect(func(s: int) -> void: rejected_status["v"] = s)
	w.step(240)
	check(cs[3].my_id == 3 and cs[4].my_id == -1, "4 вошли, 5-й нет: %d %d" % [cs[3].my_id, cs[4].my_id])
	check(rejected_status["v"] == Proto.WELCOME_FULL, "статус «мест нет»: %d" % rejected_status["v"])
	check(w.host.slots.size() == 4, "слотов %d" % w.host.slots.size())
	w.host.start_match()
	var late := w.add_client("Поздний", 0)
	var late_status := {"v": -1}
	late.rejected.connect(func(s: int) -> void: late_status["v"] = s)
	w.step(240)
	check(late.my_id == -1 and late_status["v"] == Proto.WELCOME_FULL, "вход во время матча отклонён")


func t_start() -> void:
	var w := World.new(30.0)
	var a := w.add_client("A")
	var b := w.add_client("B")
	w.step(200)
	check(w.host.start_match(), "старт принят")
	w.step(100)
	check(a.phase == GC.PHASE_COUNTDOWN and b.phase == GC.PHASE_COUNTDOWN, "отсчёт у клиентов, фаза %d" % a.phase)
	var counts := []
	for e in w.events:
		if e[0] == 0 and e[1] == GC.EV_COUNTDOWN:
			counts.append(e[4])
	check(counts == [3], "до сих пор получен «3»: %s" % str(counts))
	w.step(GC.COUNTDOWN_TICKS)
	check(a.phase == GC.PHASE_PLAYING and w.host.phase == GC.PHASE_PLAYING, "игра началась")
	counts.clear()
	for e in w.events:
		if e[0] == 0 and e[1] == GC.EV_COUNTDOWN:
			counts.append(e[4])
	check(counts == [3, 2, 1], "отсчёт 3-2-1: %s" % str(counts))
	check(w.count_events(0, GC.EV_ROUND_START) == 1 and w.count_events(1, GC.EV_ROUND_START) == 1, "ROUND_START по разу")
	var sp := GC.spawn_u(0)
	check(a.state.x == sp[0] and a.state.y == sp[1], "стоят на точках появления")


func t_idle() -> void:
	var w := World.new(60.0, 10.0, 0.05, 9)
	var a := w.add_client("A")
	var b := w.add_client("B")
	w.step(200)
	w.start_and_play()
	var c0 := a.corrections + b.corrections
	w.step(600)
	check(a.corrections + b.corrections == c0, "коррекций в простое: %d" % (a.corrections + b.corrections - c0))
	var hs: PState = w.host.slots[0].state
	check(a.state.equals(hs), "клиент A совпадает с сервером")
	check(w.host.slots[0].gap_fills <= 30, "заполнений дыр %d" % w.host.slots[0].gap_fills)


func t_walk() -> void:
	var w := World.new(60.0, 10.0, 0.03, 11)
	var a := w.add_client("A")
	var b := w.add_client("B")
	w.step(200)
	w.start_and_play()
	var x0 := a.state.x
	w.bots[0] = const_bot(127)
	w.step(1)
	check(a.state.x - x0 > 0, "отклик мгновенный: сдвиг в тот же тик (без ожидания сети)")
	w.step(120)
	var walked := (a.state.x - x0) / 256
	check(walked > 100, "прошёл %d px за секунду" % walked)
	w.bots[0] = const_bot(0)
	w.step(400)
	var hs: PState = w.host.slots[0].state
	check(a.state.equals(hs), "после остановки состояния совпали (x %d vs %d)" % [a.state.x / 256, hs.x / 256])
	check(a.max_error_px < 20.0, "максимальная коррекция %.1f px" % a.max_error_px)


func t_teleport() -> void:
	var w := World.new(40.0)
	var a := w.add_client("A")
	var b := w.add_client("B")
	w.step(200)
	w.start_and_play()
	w.step(60)
	var honest_x: int = w.host.slots[0].state.x
	a.state.x += 300 * 256              # «читер» двигает свой персонаж на 300 px локально
	a.state.y -= 200 * 256
	w.step(1)
	check(a.state.x > honest_x + 250 * 256, "локально телепорт «сработал»")
	w.step(120)
	var hs: PState = w.host.slots[0].state
	check(hs.x == honest_x, "сервер позицию не принял: x=%d, было %d" % [hs.x / 256, honest_x / 256])
	check(a.state.equals(hs) and a.corrections >= 1, "клиент возвращён к серверному состоянию, коррекций %d" % a.corrections)
	check(a.max_error_px > 200.0, "размер коррекции %.0f px" % a.max_error_px)


func t_dash_cheat() -> void:
	var w := World.new(50.0)
	var a := w.add_client("A")
	var b := w.add_client("B")
	w.step(200)
	w.start_and_play()
	var rej := {"n": 0, "reason": ""}
	w.host.dash_rejected.connect(func(id: int, r: String) -> void:
		rej["n"] += 1
		rej["reason"] = r)
	var fired := {"n": 0}
	w.bots[0] = func(_c: GameClient, _t: int) -> Array:
		fired["n"] += 1
		return [127, Proto.BTN_DASH] if fired["n"] == 1 else [127, 0]
	w.step(1)
	check(a.state.dash_left > 0 and a.state.vx == GC.DASH_SPEED, "рывок предсказан в тот же тик")
	w.bots[0] = const_bot(0)
	w.step(60)      # рывок прошёл, кулдаун (144 тика) ещё идёт
	check(rej["n"] == 0 and w.host.slots[0].state.dash_cd > 0 and w.host.slots[0].state.dash_cd < GC.DASH_COOLDOWN, "сервер принял честный рывок, кулдаун %d" % w.host.slots[0].state.dash_cd)
	# читер: обнуляет кулдаун и выносливость локально, снова жмёт рывок
	var host_x_before: int = w.host.slots[0].state.x
	var corrections_before := a.corrections
	a.state.dash_cd = 0
	a.state.stamina = GC.STAMINA_MAX
	var once := {"n": 0}
	w.bots[0] = func(_c: GameClient, _t: int) -> Array:
		once["n"] += 1
		return [127, Proto.BTN_DASH] if once["n"] == 1 else [127, 0]
	w.step(1)
	check(a.state.dash_left > 0, "локально читерский рывок предсказан")
	w.bots[0] = const_bot(0)
	w.step(240)
	check(rej["n"] >= 1 and rej["reason"] in ["cooldown", "no_stamina"], "сервер отклонил: %s (%d раз)" % [rej["reason"], rej["n"]])
	check(a.corrections > corrections_before, "клиент получил коррекцию")
	check(a.state.equals(w.host.slots[0].state), "клиент вернулся к серверному состоянию")
	check(w.host.slots[0].state.x < host_x_before + 160 * 256 + 60 * 256, "сервер не пустил дальше положенного")


func t_bad_input() -> void:
	var w := World.new(10.0)
	var a := w.add_client("A")
	var b := w.add_client("B")
	w.step(200)
	w.start_and_play()
	var s: GameHost.Slot = w.host.slots[0]
	var bad_before := s.bad_inputs
	# вручную формируем «злую» пачку: ось вне диапазона, лишние биты кнопок, номер далеко в будущем
	w.host.on_input(s, (s.next_seq + 5) & 0xFFFF, [[500, 0xFFFF]])
	var stored: Array = s.cmds[s.next_seq + 5]
	check(stored[0] == 127 and stored[1] <= GameHost.BUTTON_MASK, "ось и кнопки санитизированы: %s" % str(stored))
	w.host.on_input(s, (s.next_seq + 3000) & 0xFFFF, [[1, 0]])
	check(s.bad_inputs == bad_before + 1 and not s.cmds.has(s.next_seq + 3000), "команда из далёкого будущего отброшена")
	check(s.cmds.size() < 20, "буфер не раздувается: %d" % s.cmds.size())
	w.step(5)
	var d := s.dups
	w.host.on_input(s, 1, [[0, 0], [0, 0]])
	check(s.dups == d + 2, "старые/повторные команды игнорируются")


func t_fight() -> void:
	var w := World.new(40.0, 5.0, 0.30, 21)
	var a := w.add_client("A")
	var b := w.add_client("B")
	w.step(600)
	w.bots[0] = chaser_bot()
	w.bots[1] = chaser_bot()
	w.host.start_match()
	var guard := 0
	while w.host.phase != GC.PHASE_ENDED and guard < 60 * 120:
		w.step(120)
		guard += 120
	check(w.host.phase == GC.PHASE_ENDED, "раунд закончился за %d тиков" % guard)
	w.step(1500)      # дать дойти надёжным событиям через 30%% потерь
	check(w.host.winner == 0 or w.host.winner == 1, "победитель %d" % w.host.winner)
	for i in 2:
		check(w.count_events(i, GC.EV_ROUND_END) == 1, "клиент %d: ROUND_END ровно раз (%d)" % [i, w.count_events(i, GC.EV_ROUND_END)])
		check(w.count_events(i, GC.EV_STATS) == 2, "клиент %d: статистика обоих (%d)" % [i, w.count_events(i, GC.EV_STATS)])
		check(w.count_events(i, GC.EV_DEATH) == 1, "клиент %d: одна смерть (%d)" % [i, w.count_events(i, GC.EV_DEATH)])
	check(w.clients[0].winner == w.host.winner, "клиент знает победителя")
	var dmg := 0
	for r in w.clients[0].results.values():
		dmg += int(r["damage"])
	check(dmg > 0, "в бою был нанесён урон: %d" % dmg)


func t_fall() -> void:
	var w := World.new(20.0)
	var a := w.add_client("A")
	var b := w.add_client("B")
	w.step(200)
	w.start_and_play()
	w.bots[0] = const_bot(127)             # A бежит вправо и падает с края центральной платформы
	w.step(900)
	check(not w.host.slots[0].state.alive and w.host.slots[1].state.alive, "A упал, B жив")
	check(w.host.phase == GC.PHASE_ENDED and w.host.winner == 1, "победил B (фаза %d, победитель %d)" % [w.host.phase, w.host.winner])
	var death_cause := -1
	for e in w.events:
		if e[0] == 1 and e[1] == GC.EV_DEATH and e[2] == 0:
			death_cause = e[4]
	check(death_cause == 1, "причина смерти — падение: %d" % death_cause)
	check(not a.state.alive, "клиент A знает, что мёртв")


func t_rune() -> void:
	var w := World.new(30.0)
	var a := w.add_client("A")
	var b := w.add_client("B")
	w.step(200)
	w.start_and_play()
	w.host.rune_interval = 0
	var st: PState = w.host.slots[0].state
	w.host.runes.append({"id": 5, "type": GC.R_SPEED, "x": st.x, "y": st.y})
	w.step(120)
	check(w.host.runes.is_empty(), "руна подобрана на сервере")
	check(w.host.slots[0].state.buffs[GC.R_SPEED] > 0, "эффект у игрока на сервере")
	check(w.count_events(0, GC.EV_PICKUP) == 1 and w.count_events(1, GC.EV_PICKUP) == 1, "PICKUP по разу у обоих клиентов")
	check(a.state.buffs[GC.R_SPEED] > 0, "владелец видит эффект (сверка)")
	check(int(b.pub[0]["buffs"]) & (1 << GC.R_SPEED) != 0, "соперник видит ауру в маске")
	var cb: int = a.state.buffs[GC.R_SPEED]
	var sb: int = w.host.slots[0].state.buffs[GC.R_SPEED]
	check(absi(cb - sb) <= 40 and a.state.x == w.host.slots[0].state.x, "таймер эффекта у клиента и сервера близки (%d vs %d)" % [cb, sb])
	w.host.rune_interval = 60
	w.step(130)
	check(w.host.runes.size() >= 1 or w.count_events(0, GC.EV_PICKUP) >= 2, "сервер сам создаёт руны по таймеру")


func t_rematch() -> void:
	var w := World.new(20.0)
	var a := w.add_client("A")
	var b := w.add_client("B")
	w.step(200)
	w.start_and_play()
	w.bots[0] = const_bot(127)
	w.step(900)
	check(w.host.phase == GC.PHASE_ENDED, "раунд завершён")
	w.host.rematch()
	w.step(120)
	check(w.host.phase == GC.PHASE_LOBBY and a.phase == GC.PHASE_LOBBY and b.phase == GC.PHASE_LOBBY, "все в лобби (%d %d %d)" % [w.host.phase, a.phase, b.phase])
	w.bots[0] = const_bot(0)
	check(w.host.start_match(), "новый матч стартует")
	w.step(GC.COUNTDOWN_TICKS + 120)
	check(a.phase == GC.PHASE_PLAYING and a.state.alive and w.host.slots[0].state.alive, "новый раунд идёт, игроки живы")


func t_disconnect() -> void:
	var w := World.new(20.0)
	var a := w.add_client("A")
	var b := w.add_client("B")
	w.step(200)
	w.start_and_play()
	# клиент B «пропал»: больше не обрабатывается и ничего не шлёт
	var dead_events := w.count_events(0, GC.EV_LEFT)
	for i in 600:
		w.ticks += 1
		w.hub.advance_us(TICK_US)
		a.process_net()
		a.local_tick(0, 0)
		w.host.tick_once()
	check(w.host.slots.size() == 1 and not w.host.slots.has(1), "слот B освобождён по таймауту")
	check(w.host.phase == GC.PHASE_ENDED and w.host.winner == 0, "A победил (фаза %d, победитель %d)" % [w.host.phase, w.host.winner])
	check(w.count_events(0, GC.EV_LEFT) == dead_events + 1, "клиент A получил EV_LEFT")
