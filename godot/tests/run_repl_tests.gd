extends SceneTree
## ПР №5: тесты репликации (кодек, сетка, мир, каждая оптимизация, потери, порядок пакетов, реальный UDP). Запуск:
##   godot --headless --path godot -s res://tests/run_repl_tests.gd

var passed := 0
var failed := 0
var current := ""


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failed += 1
		print("  FAIL [%s] %s" % [current, msg])


func run(name: String, fn: Callable) -> void:
	current = name
	var before := failed
	await fn.call()
	if failed == before:
		passed += 1
		print("  ok   %s" % name)


func _initialize() -> void:
	print("== Кодек и структуры ==")
	await run("квантование: ошибка позиции ≤ 0,125 px, скорости ≤ 4 px/с, насыщение", t_quant)
	await run("размеры записей: наивная 21 Б, дельта+квант. x — 5 Б", t_sizes)
	await run("кодек: пакет обновления туда-обратно (наивный и дельта+квант.)", t_update_roundtrip)
	await run("кодек: надёжный пакет (upsert/destroy), мусор отвергается", t_reliable_roundtrip)
	await run("Grid Spatialization: вставка, перенос, удаление, запрос полосы", t_grid)
	print("== Мир-нагрузка ==")
	await run("уровень: ≥ 50 акторов, детерминизм по seed", t_world)
	await run("push: dirty только при изменении; статика не «грязнится»", t_dirty)
	print("== Оптимизации ==")
	await run("baseline: каждый клиент знает все акторы, всё шлётся на каждом сетевом тике", t_baseline)
	await run("Replication Graph: далёкие акторы не реплицируются, видимые — все на месте", t_relevancy)
	await run("IsNetRelevantFor: за спиной радиус меньше, гистерезис выхода", t_custom_relevance)
	await run("Net Dormancy: спящие не шлются; изменение будит надёжно (в т. ч. при потерях)", t_dormancy)
	await run("Push-based: стоящий актор молчит, ключевое состояние раз в секунду", t_push)
	await run("NetUpdateFrequency: декор ~2 Гц, обновления разнесены по тикам", t_freq)
	await run("NetPriority: при нехватке бюджета враги и снаряды свежее декора", t_priority)
	print("== Надёжность ==")
	await run("потери 15% и задержка: видимые акторы на месте, спящие согласованы", t_loss)
	await run("опоздавшие и переставленные пакеты: надгробия и tick-контроль", t_reorder)
	await run("смена набора оптимизаций на лету: клиент остаётся согласованным", t_live_switch)
	print("== Результат ==")
	await run("идентичные условия: контрольная сумма мира совпадает до/после", t_same_world)
	await run("оптимизированный профиль ≥ 60% меньше базового; каждая из 2+ техник даёт эффект", t_reduction)
	await run("профилировщик: учтённые байты согласуются с реальным трафиком канала", t_profiler)
	await run("реальный UDP (localhost): вход, репликация, клиент видит акторов", t_udp)
	await run("лаборатория: переключатели, пресеты и профиль сети работают на лету", t_lab)
	await run("лаборатория в игре: меню → настройки → переключатели → замер «до/после» → выход", t_lab_in_game)
	print("\n%d тестов, %d провалено" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)


# ------------------------------------------------------------------ вспомогательное

func mk(cfg: ReplCfg, n_clients: int = 1, lag: float = 0.0, loss: float = 0.0) -> Dictionary:
	var hub := LoopHub.new()
	var hl := LoopLink.new(hub, 1)
	hl.set_emulation(lag, 0.0, loss)
	var hn := NetNode.new(hl)
	var world := ReplWorld.new(7)
	world.build_level()
	var prof := ReplProfiler.new()
	prof.clients = n_clients
	var server := ReplServer.new(hn, world, cfg, prof)
	var clients: Array = []
	for i in n_clients:
		var l := LoopLink.new(hub, 100 + i)
		l.set_emulation(lag, 0.0, loss)
		var n := NetNode.new(l)
		n.add_peer(hl.link_id)
		var c := ReplClient.new(n, hl.link_id)
		c.join()
		clients.append(c)
	prof.begin("steady", 0)
	return {"hub": hub, "link": hl, "net": hn, "world": world, "server": server, "clients": clients, "prof": prof}


## n тиков; inputs(client_index, t) -> [axis, buttons] или null — стоять.
func stepn(s: Dictionary, n: int, inputs: Callable = Callable()) -> void:
	var hub: LoopHub = s["hub"]
	var server: ReplServer = s["server"]
	var clients: Array = s["clients"]
	var world: ReplWorld = s["world"]
	for t in n:
		hub.advance_us(ReplScenario.TICK_US)
		for i in clients.size():
			var c: ReplClient = clients[i]
			c.process()
			if c.client_id >= 0:
				var inp: Array = [0, 0]
				if inputs.is_valid():
					inp = inputs.call(i, world.tick)
				c.send_input(int(inp[0]), int(inp[1]))
		server.step()


func place_player(s: Dictionary, client: int, x: float) -> void:
	var w: ReplWorld = s["world"]
	var a: ReplActor = w.actors[ReplWorld.PLAYER_BASE + client]
	a.set_pos(x, a.y)


func cfg_of(keys: Array, label: String = "t") -> ReplCfg:
	return ReplCfg.only(keys, label)


# ------------------------------------------------------------------ кодек

func t_quant() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 2000:
		var p := rng.randf_range(0.0, 16000.0)
		check(absf(ReplDefs.dq_pos(ReplDefs.q_pos(p)) - p) <= 0.125 + 1e-6, "позиция %f" % p)
		var v := rng.randf_range(-1000.0, 1000.0)
		check(absf(ReplDefs.dq_vel(ReplDefs.q_vel(v)) - v) <= 4.0 + 1e-6, "скорость %f" % v)
	check(ReplDefs.q_pos(-50.0) == 0 and ReplDefs.q_pos(99999.0) == 65535, "насыщение позиции")
	check(ReplDefs.q_vel(5000.0) == 127 and ReplDefs.q_vel(-5000.0) == -127, "насыщение скорости")
	check(ReplDefs.q_pos(ReplDefs.WORLD_W_PX) < 65535, "мир целиком влезает в u16")


func _actor(id: int, cls: int, x: float, y: float, vx: float, st: int, hp: int) -> ReplActor:
	var a := ReplActor.new(id, cls, [])
	a.x = x
	a.y = y
	a.vx = vx
	a.st = st
	a.hp = hp
	return a


func t_sizes() -> void:
	check(ReplCodec.update_entry_size(0, ReplDefs.F_ALL) == 21, "наивная запись 21 Б, а не %d" % ReplCodec.update_entry_size(0, ReplDefs.F_ALL))
	check(ReplCodec.update_entry_size(ReplDefs.FMT_DELTA | ReplDefs.FMT_QUANT, ReplDefs.F_X) == 5, "дельта x квант. = 5 Б")
	check(ReplCodec.update_entry_size(ReplDefs.FMT_DELTA, ReplDefs.F_X) == 7, "дельта x float = 7 Б")
	check(ReplCodec.update_entry_size(ReplDefs.FMT_QUANT, ReplDefs.F_ALL) == 11, "полная квант. запись 11 Б")
	check(ReplCodec.upsert_entry_size(0) == 22 and ReplCodec.upsert_entry_size(ReplDefs.FMT_QUANT) == 12, "размеры upsert")


func t_update_roundtrip() -> void:
	var a := _actor(300, ReplDefs.C_BOT, 1234.5678, 700.0, -83.3, 5, 42)
	var b := _actor(1001, ReplDefs.C_PROJ, 15999.9, 670.0, 320.0, 1, 0)
	for fmt in [0, ReplDefs.FMT_QUANT, ReplDefs.FMT_DELTA, ReplDefs.FMT_DELTA | ReplDefs.FMT_QUANT]:
		var masks := [ReplDefs.F_ALL, ReplDefs.F_ALL] if (fmt & ReplDefs.FMT_DELTA) == 0 else [ReplDefs.F_X | ReplDefs.F_ST, ReplDefs.F_ALL]
		var raw := ReplCodec.update_packet(9, 777, fmt, [[a, masks[0]], [b, masks[1]]])
		var expect := 8 + 4 + ReplCodec.update_entry_size(fmt, masks[0]) + ReplCodec.update_entry_size(fmt, masks[1])
		check(raw.size() == expect, "размер пакета fmt=%d: %d != %d" % [fmt, raw.size(), expect])
		var m := Proto.parse(raw)
		check(not m.is_empty() and m["type"] == Proto.T_WORLD_UPDATE and not m["requires_ack"], "разбор fmt=%d" % fmt)
		if m.is_empty():
			continue
		check(m["tick"] == 777 and m["entries"].size() == 2, "tick/число записей")
		var e0: Dictionary = m["entries"][0]
		var tol := 0.13 if (fmt & ReplDefs.FMT_QUANT) != 0 else 0.01
		check(e0["id"] == 300 and e0.has("x") and absf(e0["x"] - 1234.5678) <= tol, "x туда-обратно fmt=%d: %s" % [fmt, str(e0.get("x"))])
		check(e0["st"] == 5, "st")
		if (fmt & ReplDefs.FMT_DELTA) != 0:
			check(not e0.has("hp") and not e0.has("vx") and e0["mask"] == (ReplDefs.F_X | ReplDefs.F_ST), "в дельте только поля маски")
		else:
			check(absf(e0["vx"] - (-83.3)) <= (4.01 if (fmt & ReplDefs.FMT_QUANT) != 0 else 0.01) and e0["hp"] == 42 and e0["cls"] == ReplDefs.C_BOT, "полная запись")
		var e1: Dictionary = m["entries"][1]
		check(e1["id"] == 1001 and absf(e1["x"] - 15999.9) <= tol, "вторая запись")
	check(Proto.parse(ReplCodec.update_packet(1, 1, 0, [])).get("entries", [1]).size() == 0, "пустой пакет допустим")


func t_reliable_roundtrip() -> void:
	var a := _actor(205, ReplDefs.C_PICKUP, 3333.0, 660.0, 0.0, 1, 0)
	for fmt in [0, ReplDefs.FMT_QUANT]:
		var raw := ReplCodec.reliable_packet(3, 65535, fmt, [[ReplDefs.OP_UPSERT, a], [ReplDefs.OP_DESTROY, 1001, ReplDefs.DESTROY_IRRELEVANT]])
		check(raw.size() == 8 + 4 + ReplCodec.upsert_entry_size(fmt) + 4, "размер надёжного пакета")
		var m := Proto.parse(raw)
		check(not m.is_empty() and m["type"] == Proto.T_WORLD_RELIABLE and m["requires_ack"], "надёжный тип с requiresAck")
		check(m["tick"] == 65535 and m["entries"][0]["cls"] == ReplDefs.C_PICKUP and m["entries"][0]["st"] == 1, "upsert")
		check(m["entries"][1]["op"] == ReplDefs.OP_DESTROY and m["entries"][1]["reason"] == ReplDefs.DESTROY_IRRELEVANT, "destroy")
		for cut in [1, 5, raw.size() - 8 - 1]:
			check(Proto.parse(raw.slice(0, raw.size() - cut)).is_empty(), "усечённый пакет (−%d Б) отвергнут" % cut)
	var upd := ReplCodec.update_packet(1, 1, 0, [[a, ReplDefs.F_ALL]])
	var bad := upd.duplicate()
	bad.append(0)
	check(Proto.parse(bad).is_empty(), "лишние байты отвергнуты")
	var bad2 := upd.duplicate()
	bad2[10] = 7      # fmt с лишними битами (после заголовка: tick u16, затем fmt)
	check(Proto.parse(bad2).is_empty(), "неизвестные биты fmt отвергнуты")
	var hdr := Proto.read_header(ReplCodec.update_packet(1, 1, 0, []))
	check(not hdr.is_empty(), "заголовок типа 13 принимается")
	var raw15 := ReplCodec.update_packet(1, 1, 0, [])
	raw15[0] = 15
	check(Proto.parse(raw15).is_empty(), "тип 15 неизвестен")


func t_grid() -> void:
	var g := ReplGrid.new()
	g.insert(1, 100.0, 700.0)
	g.insert(2, 4200.0, 700.0)
	g.insert(3, 4300.0, 100.0)
	check(g.size() == 3, "три актора")
	var near := g.query_x_range(0.0, 1000.0)
	check(near.has(1) and not near.has(2) and not near.has(3), "полоса 0..1000: только первый, а не %s" % str(near))
	var far := g.query_x_range(4000.0, 4500.0)
	check(far.has(2) and far.has(3) and not far.has(1), "полоса 4000..4500 охватывает обе строки сетки")
	g.move(1, 4250.0, 700.0)
	check(g.query_x_range(4000.0, 4500.0).has(1) and not g.query_x_range(0.0, 1000.0).has(1), "перенос в другую ячейку")
	g.remove(2)
	check(g.size() == 2 and not g.query_x_range(4000.0, 4500.0).has(2), "удаление")
	var c0 := g.cells_visited
	g.query_x_range(0.0, 999.0)
	check(g.cells_visited - c0 <= 6, "запрос смотрит несколько ячеек, а не весь мир")


# ------------------------------------------------------------------ мир

func t_world() -> void:
	var w := ReplWorld.new(7)
	w.build_level()
	check(w.count() >= 50, "в сцене %d акторов (нужно ≥ 50)" % w.count())
	check(w.count() == ReplWorld.N_TREES + ReplWorld.N_PICKUPS + ReplWorld.N_BOTS + ReplWorld.N_CLOUDS, "состав уровня")
	var w2 := ReplWorld.new(7)
	w2.build_level()
	var w3 := ReplWorld.new(8)
	w3.build_level()
	for i in 600:
		w.step()
		w2.step()
		w3.step()
	check(w.checksum() == w2.checksum(), "один seed — одинаковый мир")
	check(w.checksum() != w3.checksum(), "другой seed — другой мир")
	var ids := {}
	for id in w.actors.keys():
		ids[(w.actors[id] as ReplActor).cls] = true
	check(ids.size() >= 4 and ids.has(ReplDefs.C_BOT) and ids.has(ReplDefs.C_CLOUD), "в мире классы акторов: деревья, предметы, боты, облака")


func t_dirty() -> void:
	var w := ReplWorld.new(7)
	w.build_level()
	w.dirty_ids.clear()
	for a: ReplActor in w.actors.values():
		a.clear_dirty()
	var t: ReplActor = w.actors[ReplWorld.TREE_BASE]
	t.set_pos(t.x, t.y)
	t.set_hp(t.hp)
	check(t.dirty == 0 and w.dirty_ids.is_empty(), "та же запись — не «грязно»")
	t.set_hp(50)
	t.set_st(3)
	t.set_hp(40)
	check(t.dirty == (ReplDefs.F_HP | ReplDefs.F_ST), "маска изменённых полей")
	check(w.dirty_ids.count(t.id) == 1, "актор попал в список один раз")
	for i in 120:
		w.step()
	var tree_dirty := 0
	for id in w.dirty_ids:
		if (w.actors.get(id) as ReplActor).cls == ReplDefs.C_TREE and id != t.id:
			tree_dirty += 1
	check(tree_dirty == 0 or w.tree_hits > 0, "деревья без попаданий не меняются")


# ------------------------------------------------------------------ оптимизации

func t_baseline() -> void:
	var s := mk(ReplCfg.baseline(), 2)
	stepn(s, 120)
	var w: ReplWorld = s["world"]
	for c: ReplClient in s["clients"]:
		check(c.client_id >= 0, "клиент вошёл")
		check(c.actors.size() == w.count(), "клиент знает %d из %d акторов" % [c.actors.size(), w.count()])
	var prof: ReplProfiler = s["prof"]
	prof.begin("m", w.tick)
	stepn(s, 120)
	var sm := prof.summary("m", 2)
	var expected := float(w.count()) * float(ReplDefs.NET_HZ)
	check(absf(sm["entries_per_s_per_client"] - expected) <= expected * 0.08, "записей/с на клиента %.0f, ожидалось ≈ %.0f" % [sm["entries_per_s_per_client"], expected])
	check(absf(sm["avg_bytes_per_entry"] - 21.0) < 1.0, "в среднем 21 Б на запись, а не %.1f" % sm["avg_bytes_per_entry"])
	check(sm["kb_s_per_client"] > 35.0, "наивный трафик велик: %.1f КБ/с на клиента" % sm["kb_s_per_client"])


func t_relevancy() -> void:
	var s := mk(cfg_of(["relevancy"]), 2)
	var w: ReplWorld = s["world"]
	stepn(s, 20)       # клиенты входят и получают аватары
	place_player(s, 0, 400.0)
	place_player(s, 1, 8000.0)
	stepn(s, 180)
	var c0: ReplClient = s["clients"][0]
	var c1: ReplClient = s["clients"][1]
	check(c0.actors.size() < w.count() / 3, "клиент 0 знает %d из %d" % [c0.actors.size(), w.count()])
	check(c0.actors.has(ReplWorld.PLAYER_BASE + 1), "чужой игрок релевантен всегда")
	var me0: ReplActor = w.actors[ReplWorld.PLAYER_BASE]
	for id in w.actors.keys():
		var a: ReplActor = w.actors[id]
		if absf(a.x - me0.x) <= ReplDefs.VIEW_HALF_W:
			check(c0.actors.has(id), "видимый актор %d (x=%.0f) отсутствует у клиента" % [id, a.x])
		if a.cls == ReplDefs.C_TREE and absf(a.x - me0.x) > 1100.0:
			check(not c0.actors.has(id), "далёкое дерево %d реплицируется" % id)
	var me1: ReplActor = w.actors[ReplWorld.PLAYER_BASE + 1]
	var near1 := 0
	for id in c1.actors.keys():
		if absf((c1.actors[id] as ReplClient.CActor).x - me1.x) < 1500.0:
			near1 += 1
	check(near1 >= c1.actors.size() - 1, "у клиента 1 только акторы поблизости")
	# проход через мир: акторы приходят и уходят, видимое не пропадает
	var walk := func(i: int, _t: int) -> Array: return [127, 0] if i == 0 else [0, 0]
	var missing := 0
	for k in 20:
		stepn(s, 60, walk)
		for id in w.actors.keys():
			var a2: ReplActor = w.actors[id]
			var me: ReplActor = w.actors[ReplWorld.PLAYER_BASE]
			if absf(a2.x - me.x) <= ReplDefs.VIEW_HALF_W and w.tick - a2.born_tick > 6 and not c0.actors.has(id):
				missing += 1
	check(missing == 0, "за 20 с ходьбы пропало видимых акторов: %d" % missing)
	check(int(c0.stats["destroys"]) > 10 and int(c0.stats["upserts"]) > 20, "акторы появлялись и уходили (destroys=%d, upserts=%d)" % [c0.stats["destroys"], c0.stats["upserts"]])
	for id in c0.actors.keys():
		check(w.actors.has(id), "у клиента остался актор %d, которого нет на сервере" % id)


func t_custom_relevance() -> void:
	var s := mk(cfg_of(["relevancy", "custom_relevance"]), 1)
	var srv: ReplServer = s["server"]
	var obs := _actor(1, ReplDefs.C_PLAYER, 5000.0, 700.0, 0.0, 1, 100)       # смотрит вправо
	var tree_front := _actor(100, ReplDefs.C_TREE, 5000.0 + 950.0, 700.0, 0.0, 0, 100)
	var tree_back := _actor(101, ReplDefs.C_TREE, 5000.0 - 950.0, 700.0, 0.0, 0, 100)
	check(srv.is_net_relevant_for(tree_front, obs, false), "впереди на 950 px (лимит 1000) — релевантно")
	check(not srv.is_net_relevant_for(tree_back, obs, false), "сзади на 950 px (лимит 750) — нет")
	var tree_back_near := _actor(102, ReplDefs.C_TREE, 5000.0 - 700.0, 700.0, 0.0, 0, 100)
	check(srv.is_net_relevant_for(tree_back_near, obs, false), "сзади на 700 px — да (камера видит 640)")
	var bot_back := _actor(300, ReplDefs.C_BOT, 5000.0 - 1300.0, 700.0, 0.0, 0, 50)
	check(srv.is_net_relevant_for(bot_back, obs, false), "враг сзади на 1300 px релевантен (радиус не сужается)")
	var edge := _actor(103, ReplDefs.C_TREE, 5000.0 - 800.0, 700.0, 0.0, 0, 100)
	check(not srv.is_net_relevant_for(edge, obs, false) and srv.is_net_relevant_for(edge, obs, true), "гистерезис: уже известный остаётся до 870 px")
	obs.st = 0       # развернулся влево
	check(srv.is_net_relevant_for(tree_back, obs, false) and not srv.is_net_relevant_for(tree_front, obs, false), "после разворота «перед» и «зад» меняются местами")
	var s2 := mk(cfg_of(["relevancy"]), 1)
	var plain: ReplServer = s2["server"]
	obs.st = 1
	check(plain.is_net_relevant_for(tree_back, obs, false) and not plain.is_net_relevant_for(edge, obs, true) == false, "без custom — симметричный радиус 1000 без гистерезиса")


func t_dormancy() -> void:
	var s := mk(cfg_of(["dormancy"]), 1, 0.0, 0.0)
	var w: ReplWorld = s["world"]
	var prof: ReplProfiler = s["prof"]
	var c: ReplClient = s["clients"][0]
	stepn(s, 20)
	place_player(s, 0, 2000.0)       # между ботами (1000 и 3000): никто не стреляет, деревья не задеты
	stepn(s, 100)
	prof.begin("m", w.tick)
	stepn(s, 120)
	var sm := prof.summary("m", 1)
	check(sm["per_class"]["tree"]["entries"] == 0 and sm["per_class"]["pickup"]["entries"] == 0, "деревья и предметы не обновляются: %s" % str(sm["per_class"]["tree"]))
	check(sm["per_class"]["bot"]["entries"] > 100, "боты по-прежнему обновляются")
	# изменение спящего актора доходит надёжным пробуждением
	var tree: ReplActor = w.actors[ReplWorld.TREE_BASE + 3]
	tree.set_hp(33)
	stepn(s, 6)
	check((c.actors[tree.id] as ReplClient.CActor).hp == 33, "пробуждение доставило hp")
	check(int(sm["reliable_ops"]["state"]) == 0, "до этого пробуждений не было")
	var sm2 := prof.summary("m", 1)
	check(int(sm2["reliable_ops"]["state"]) == 1, "ровно одно пробуждение (state=%d)" % sm2["reliable_ops"]["state"])
	# при потерях: надёжный канал догоняет
	var s2 := mk(cfg_of(["dormancy"]), 1, 20.0, 0.3)
	stepn(s2, 150)
	var w2: ReplWorld = s2["world"]
	var t2: ReplActor = w2.actors[ReplWorld.TREE_BASE + 5]
	t2.set_hp(61)
	t2.set_st(3)
	stepn(s2, 240)
	var ca: ReplClient.CActor = (s2["clients"][0] as ReplClient).actors.get(t2.id)
	check(ca != null and ca.hp == 61 and ca.st == 3, "при 30% потерь спящий актор согласован")


func t_push() -> void:
	var s := mk(cfg_of(["push"]), 1)
	var w: ReplWorld = s["world"]
	var prof: ReplProfiler = s["prof"]
	stepn(s, 120)
	prof.begin("m", w.tick)
	stepn(s, 300)
	var sm := prof.summary("m", 1)
	var tree_entries: int = sm["per_class"]["tree"]["entries"]
	var secs := 5.0
	var per_tree_per_s := float(tree_entries) / float(ReplWorld.N_TREES) / secs
	check(per_tree_per_s >= 0.8 and per_tree_per_s <= 1.5, "стоящее дерево — ключевое состояние ~1 раз/с, а не %.2f" % per_tree_per_s)
	check(sm["avg_bytes_per_entry"] < 12.0, "записи короче наивных: %.1f Б" % sm["avg_bytes_per_entry"])
	var bot_bytes: float = float(sm["per_class"]["bot"]["bytes"]) / float(maxi(sm["per_class"]["bot"]["entries"], 1))
	check(bot_bytes < 14.0, "бот: ~%.1f Б на запись (x + изредка прочее)" % bot_bytes)
	# клиент всё равно видит актуальный мир
	var c: ReplClient = s["clients"][0]
	var worst := 0.0
	for id in w.actors.keys():
		var a: ReplActor = w.actors[id]
		var ca: ReplClient.CActor = c.actors.get(id)
		check(ca != null, "актор %d известен" % id)
		if ca != null:
			worst = maxf(worst, c.pos_at(id, (s["hub"] as LoopHub).now_us).distance_to(Vector2(a.x, a.y)))
	check(worst < 12.0, "максимальная ошибка позиции %.1f px" % worst)


func t_freq() -> void:
	var s := mk(cfg_of(["freq"]), 1)
	var w: ReplWorld = s["world"]
	var prof: ReplProfiler = s["prof"]
	stepn(s, 120)
	prof.begin("m", w.tick)
	var per_tick: Array = []
	var last := 0
	for i in 15 * 4:
		stepn(s, 2)
		var cur: int = (prof.phases["m"] as ReplProfiler.Phase).per_class.get(ReplDefs.C_TREE, {"entries": 0})["entries"]
		per_tick.append(cur - last)
		last = cur
	var sm := prof.summary("m", 1)
	var trees: float = float(sm["per_class"]["tree"]["entries"]) / float(ReplWorld.N_TREES) / sm["seconds"]
	check(trees >= 1.7 and trees <= 2.3, "дерево обновляется %.2f Гц (ожидалось 2)" % trees)
	var bots: float = float(sm["per_class"]["bot"]["entries"]) / float(ReplWorld.N_BOTS) / sm["seconds"]
	check(bots >= 28.0 and bots <= 32.0, "бот обновляется %.1f Гц (игровое — без изменений, 30)" % bots)
	var mx := 0
	for v in per_tick:
		mx = maxi(mx, int(v))
	check(mx <= 6, "обновления деревьев разнесены: максимум %d за тик из %d деревьев" % [mx, ReplWorld.N_TREES])


func t_priority() -> void:
	var errs := {}
	for pr in [false, true]:
		var c := ReplCfg.new()
		c.priority = pr
		c.budget_bytes = 600
		var r := ReplScenario.run(c, {"seconds": 12, "clients": 2})
		errs[pr] = r["quality"]["per_class_err_px"]
	check(float(errs[true]["bot"]) * 5.0 < float(errs[false]["bot"]), "с приоритетом боты точнее: %.1f против %.1f px" % [errs[true]["bot"], errs[false]["bot"]])
	check(float(errs[true]["projectile"]) < float(errs[false]["projectile"]), "и снаряды: %.1f против %.1f px" % [errs[true]["projectile"], errs[false]["projectile"]])
	check(float(errs[true]["bot"]) < 5.0, "при приоритете враги почти без ошибки (%.1f px)" % errs[true]["bot"])


# ------------------------------------------------------------------ надёжность

func t_loss() -> void:
	var s := mk(ReplCfg.optimized(), 2, 25.0, 0.15)
	var walk := func(i: int, _t: int) -> Array: return [127, 0] if i == 0 else [-64, ReplWorld.BTN_SHOOT]
	stepn(s, 60 * 15, walk)
	var w: ReplWorld = s["world"]
	var hub: LoopHub = s["hub"]
	for c: ReplClient in s["clients"]:
		check(c.client_id >= 0, "вход прошёл при потерях")
		var me: ReplActor = w.actors[ReplWorld.PLAYER_BASE + c.client_id]
		var missing := 0
		var worst := 0.0
		for id in w.actors.keys():
			var a: ReplActor = w.actors[id]
			if absf(a.x - me.x) > ReplDefs.VIEW_HALF_W or w.tick - a.born_tick < 30:
				continue
			var ca: ReplClient.CActor = c.actors.get(id)
			if ca == null:
				missing += 1
				continue
			if a.cls == ReplDefs.C_TREE:
				check(ca.hp == a.hp, "hp дерева %d: у клиента %d, на сервере %d" % [id, ca.hp, a.hp])
			if a.cls == ReplDefs.C_PICKUP:
				check(ca.st == a.st, "предмет %d: состояние различается" % id)
			if a.cls == ReplDefs.C_BOT:
				worst = maxf(worst, c.pos_at(id, hub.now_us).distance_to(Vector2(a.x, a.y)))
		check(missing == 0, "клиент %d: нет %d видимых акторов" % [c.client_id, missing])
		check(worst < 60.0, "клиент %d: боты в пределах %.1f px при 25 мс и 15%% потерь" % [c.client_id, worst])


func t_reorder() -> void:
	var hub := LoopHub.new()
	var l := LoopLink.new(hub, 1)
	var c := ReplClient.new(NetNode.new(l), 99)
	var a := _actor(300, ReplDefs.C_BOT, 100.0, 700.0, 0.0, 0, 50)
	var up := func(tick: int, x: float) -> Dictionary:
		var m := Proto.parse(ReplCodec.update_packet(1, tick, 0, [[_actor(300, ReplDefs.C_BOT, x, 700.0, 0.0, 0, 50), ReplDefs.F_ALL]]))
		return m
	var upsert := func(tick: int, x: float) -> Dictionary:
		var aa := _actor(300, ReplDefs.C_BOT, x, 700.0, 0.0, 0, 50)
		return Proto.parse(ReplCodec.reliable_packet(2, tick, 0, [[ReplDefs.OP_UPSERT, aa]]))
	var destroy := func(tick: int) -> Dictionary:
		return Proto.parse(ReplCodec.reliable_packet(3, tick, 0, [[ReplDefs.OP_DESTROY, 300, 0]]))
	c._on_message(99, up.call(10, 111.0))
	check(c.actors.is_empty(), "обновление раньше появления игнорируется")
	c._on_message(99, upsert.call(12, 120.0))
	check(c.actors[300].x == 120.0, "upsert создал актор")
	c._on_message(99, up.call(11, 999.0))
	check(c.actors[300].x == 120.0 and int(c.stats["stale"]) == 1, "опоздавшее обновление (tick 11 < 12) отброшено")
	c._on_message(99, up.call(14, 140.0))
	check(c.actors[300].x == 140.0, "свежее применено")
	c._on_message(99, destroy.call(16))
	check(not c.actors.has(300), "destroy удалил актор")
	c._on_message(99, upsert.call(13, 130.0))
	check(not c.actors.has(300) and int(c.stats["tomb_blocked"]) == 1, "опоздавший upsert (tick 13 < destroy 16) не воскрешает актор")
	c._on_message(99, upsert.call(20, 200.0))
	check(c.actors.has(300) and c.actors[300].x == 200.0, "повторное появление позже удаления принимается")
	c._on_message(99, up.call(30000, 1.0))
	c._on_message(99, up.call(60000, 2.0))
	c._on_message(99, up.call(65535, 5.0))
	c._on_message(99, up.call(3, 7.0))
	check(c.actors[300].x == 7.0, "перенос tick через 65535→0 учитывается")
	check(ReplClient._newer_or_eq(1, 65534) and not ReplClient._newer_or_eq(65534, 1), "сравнение tick по модулю 65536")
	a.x = 0.0


func t_live_switch() -> void:
	var cfg := ReplCfg.baseline()
	var s := mk(cfg, 1)
	var w: ReplWorld = s["world"]
	var srv: ReplServer = s["server"]
	var c: ReplClient = s["clients"][0]
	stepn(s, 90)
	check(c.actors.size() == w.count(), "baseline: знает все")
	cfg.set_flag("relevancy", true)
	srv.apply_cfg()
	stepn(s, 90)
	check(c.actors.size() < w.count() / 2, "после включения релевантности акторов стало %d" % c.actors.size())
	cfg.set_flag("dormancy", true)
	cfg.set_flag("push", true)
	cfg.set_flag("quantize", true)
	srv.apply_cfg()
	stepn(s, 90)
	cfg.set_flag("relevancy", false)
	cfg.set_flag("dormancy", false)
	srv.apply_cfg()
	stepn(s, 120)
	check(c.actors.size() == w.count(), "после выключения релевантности клиент снова знает все: %d из %d" % [c.actors.size(), w.count()])
	var worst := 0.0
	for id in w.actors.keys():
		var a: ReplActor = w.actors[id]
		worst = maxf(worst, c.pos_at(id, (s["hub"] as LoopHub).now_us).distance_to(Vector2(a.x, a.y)))
	check(worst < 12.0, "и согласован с сервером: %.1f px" % worst)


# ------------------------------------------------------------------ итог

func t_same_world() -> void:
	var a := ReplScenario.run(ReplCfg.baseline(), {"seconds": 8})
	var b := ReplScenario.run(ReplCfg.optimized(), {"seconds": 8})
	check(a["checksum"] == b["checksum"], "контрольные суммы мира различаются")
	check(a["world_events"] == b["world_events"], "события мира различаются")
	check(int(a["world_events"]["shots"]) > 0 and int(a["world_events"]["tree_hits"]) > 0, "в сценарии есть выстрелы и попадания в деревья")
	check(int(a["level_actors"]) >= 50 and int(a["clients"]) == int(b["clients"]), "то же число акторов и клиентов")


func t_reduction() -> void:
	var o := {"seconds": 12}
	var base := ReplScenario.run(ReplCfg.baseline(), o)
	var opt := ReplScenario.run(ReplCfg.optimized(), o)
	var bk: float = base["steady"]["kb_s_total"]
	var ok: float = opt["steady"]["kb_s_total"]
	check(ok <= bk * 0.4, "снижение трафика %.0f%% (цель ≥ 60%%)" % ((1.0 - ok / bk) * 100.0))
	check(float(opt["quality"]["err_avg_px"]) < 2.0 and int(opt["quality"]["missing"]) == 0, "качество картинки: ошибка %.2f px, пропаж %d" % [opt["quality"]["err_avg_px"], opt["quality"]["missing"]])
	check(float(opt["steady"]["known_avg"]) < float(base["steady"]["known_avg"]) / 3.0, "реплицируемых акторов у клиента втрое меньше")
	var effective := 0
	for k in ["relevancy", "dormancy", "push", "quantize", "freq"]:
		var r := ReplScenario.run(ReplCfg.only([k], "x"), o)
		if float(r["steady"]["kb_s_total"]) < bk * 0.85:
			effective += 1
		else:
			check(false, "техника %s не дала эффекта: %.1f против %.1f КБ/с" % [k, r["steady"]["kb_s_total"], bk])
	check(effective >= 2, "эффективных техник: %d" % effective)


func t_profiler() -> void:
	var r := ReplScenario.run(ReplCfg.baseline(), {"seconds": 6})
	var link: int = r["link_out_bytes"]
	var prof_payload_hdr: int = int(r["steady"]["payload_bytes"]) + int(r["steady"]["packets"]) * 8
	check(prof_payload_hdr <= link and float(prof_payload_hdr) >= float(link) * 0.97, "профиль %d Б, канал %d Б (разница — только Ping/ACK)" % [prof_payload_hdr, link])
	var wire: int = r["net_out_bytes_wire"]
	check(int(r["steady"]["wire_bytes"]) <= wire and float(r["steady"]["wire_bytes"]) >= float(wire) * 0.97, "с учётом +28 Б IP/UDP: %d против %d" % [r["steady"]["wire_bytes"], wire])
	check(r["steady"]["heavy_actors"].size() == 10 and int(r["steady"]["heavy_actors"][0]["bytes"]) >= int(r["steady"]["heavy_actors"][9]["bytes"]), "таблица «тяжёлых» акторов отсортирована")
	var cls_sum := 0
	for k in r["steady"]["per_class"].keys():
		cls_sum += int(r["steady"]["per_class"][k]["bytes"])
	check(cls_sum + int(r["steady"]["packets"]) * (8 + 28 + 4) >= int(r["steady"]["wire_bytes"]) - 64 and cls_sum < int(r["steady"]["wire_bytes"]), "байты по классам + накладные = всего")
	check(float(r["steady"]["series_kb"].size()) >= 5.0, "ряд КБ/с по секундам")


func t_udp() -> void:
	var cfg := ReplCfg.optimized()
	var hl := UdpLink.new(1)
	check(hl.listen(27093) == OK, "bind 27093")
	var hn := NetNode.new(hl)
	var world := ReplWorld.new(7)
	world.build_level()
	var prof := ReplProfiler.new()
	prof.begin("steady", 0)
	var server := ReplServer.new(hn, world, cfg, prof)
	var cl := UdpLink.new(2)
	check(cl.connect_to("127.0.0.1", 27093) == OK, "клиентский сокет")
	var cn := NetNode.new(cl)
	cn.add_peer(1)
	var client := ReplClient.new(cn, 1)
	client.join()
	var step_us := 1_000_000 / ReplDefs.WORLD_HZ
	var next := Time.get_ticks_usec()
	var end := Time.get_ticks_msec() + 3500
	while Time.get_ticks_msec() < end:
		client.process()
		if client.client_id >= 0:
			client.send_input(127, 0)
		var now := Time.get_ticks_usec()
		while next <= now:
			server.step()
			next += step_us
		OS.delay_msec(2)
	check(client.client_id == 0, "Hello → Welcome по реальному UDP")
	var me := client.avatar()
	check(me != null and me.x > 400.0, "аватар двигается по вводу клиента")
	check(client.actors.size() >= 8 and client.actors.size() < world.count(), "клиент получил акторов поблизости: %d из %d" % [client.actors.size(), world.count()])
	var server_me: ReplActor = world.actors[ReplWorld.PLAYER_BASE]
	if me != null:
		check(absf(me.x - server_me.x) < 400.0, "позиция аватара у клиента близка к серверной")
	hl.close()
	cl.close()


func t_lab() -> void:
	var lab := ReplLab.new()
	lab.start("optimized", 3, 0)       # вне дерева: проверяем логику без окна
	for i in 150:
		lab._tick()
	check(lab.cfg.active().size() == 7, "стартовый набор — все оптимизации")
	check(lab.clients.size() == 3 and lab.clients[0].client_id == 0, "три клиента вошли")
	var known_opt: int = lab.clients[0].actors.size()
	check(known_opt >= 6 and known_opt < lab.world.count() / 2, "оптимизированный режим: клиенту 0 реплицируется %d из %d" % [known_opt, lab.world.count()])
	lab.apply_preset_name("baseline")
	for i in 120:
		lab._tick()
	check(lab.cfg.active().is_empty() and lab.clients[0].actors.size() == lab.world.count(), "набор «до»: клиент знает все %d акторов" % lab.world.count())
	lab.set_flag("relevancy", true)
	for i in 90:
		lab._tick()
	check(lab.clients[0].actors.size() < lab.world.count() / 2, "переключатель релевантности работает на лету")
	lab.set_flag("relevancy", false)
	check(not lab.cfg.custom_relevance, "выключение релевантности выключает и IsNetRelevantFor")
	lab.set_flag("custom_relevance", true)
	check(lab.cfg.relevancy and lab.cfg.custom_relevance, "включение IsNetRelevantFor включает релевантность")
	# эмуляция сети из настроек игры действует на каналы лаборатории
	lab.apply_net_preset(2)
	check(lab.host_link.lag_ms == 175.0 and lab.host_link.loss == 0.04 and (lab.clients[1].net.link as Link).lag_ms == 175.0, "профиль сети применён к каналам")
	for i in 240:
		lab._tick()
	check(lab.clients[0].actors.size() >= 6, "при 175±25 мс и 4% потерь клиент по-прежнему получает мир")
	lab.free()


func t_lab_in_game() -> void:
	## Лаборатория как режим самой игры: меню → кнопка → переключатели UI → замер → выход.
	var app: App = load("res://scenes/main.tscn").instantiate()
	root.add_child(app)
	await process_frame
	check(app.screen == "menu" and app.ui.menu.visible, "стартовый экран — меню")
	app.ui.repl_open_requested.emit("baseline")
	await process_frame
	check(app.screen == "lab" and app.ui.lab.visible and not app.ui.menu.visible and app.lab != null, "кнопка меню открыла лабораторию")
	check(not app.view.visible, "арена скрыта")
	for i in 120:
		app.lab._tick()
	check(app.lab.cfg.active().is_empty(), "старт с набором «до»")
	# переключатель в настройках игры
	(app.ui._repl_checks["dormancy"] as CheckButton).button_pressed = true
	check(app.lab.cfg.dormancy and app.lab.cfg.active().size() == 1, "переключатель в настройках включил Net Dormancy")
	app.ui.repl_preset_changed.emit("optimized")
	check(app.lab.cfg.active().size() == 7 and (app.ui._repl_checks["push"] as CheckButton).button_pressed, "набор «после» включил всё, переключатели синхронизированы")
	app.lab.apply_preset_name("baseline")
	check((app.ui._repl_checks["quantize"] as CheckButton).button_pressed == false, "панель отражает набор «до»")
	app.ui.lab_net_opt.item_selected.emit(1)
	check(app.preset == 1 and app.lab.net_preset == 1, "профиль сети из настроек применён к лаборатории")
	app.ui.lab_net_opt.item_selected.emit(0)
	# замер «до/после»
	var got := {"res": {}}
	app.lab.measure_done.connect(func(r: Dictionary) -> void: got["res"] = r)
	app.ui.repl_measure_btn.pressed.emit()
	check(app.ui.repl_measure_btn.disabled, "кнопка замера блокируется на время замера")
	var ok := await _wait_until(func() -> bool: return not (got["res"] as Dictionary).is_empty(), 90.0)
	check(ok, "замер завершился")
	if ok:
		var r: Dictionary = got["res"]
		var rows: Array = r["rows"]
		check(rows.size() == 8 and rows[0]["key"] == "baseline" and rows[1]["key"] == "optimized", "в таблице 8 строк: до, после, текущий, 5 техник")
		check(rows[1]["less_pct"] > 90.0, "«после» снижает трафик на %.1f%%" % rows[1]["less_pct"])
		check(r["same_checksum"], "контрольные суммы мира совпали")
		check(app.ui.repl_result.visible and app.ui.repl_result_grid.get_child_count() == 5 * 9 and not app.ui.repl_measure_btn.disabled, "таблица результатов показана")
		check(rows[2]["active"] == 0, "строка «ваш набор» отражает текущие переключатели (набор «до»)")
	_key(app, KEY_ESCAPE, true)
	check(app.screen == "menu" and app.lab == null and app.view.visible and app.ui.menu.visible, "Esc возвращает в меню и в арену")
	app.queue_free()
	await process_frame


func _key(app: App, code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	app._input(ev)


func _wait_until(cond: Callable, timeout_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return false
