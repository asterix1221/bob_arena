extends SceneTree
## Тесты протокола и транспорта (порт ПР №2-3 на GDScript). Запуск из корня репозитория:
##   godot --headless --path godot -s res://tests/run_net_tests.gd
## Часть 1 — байтовая совместимость с C++ (golden_vectors.json генерирует tools/gen_golden_vectors.cpp).
## Часть 2 — устойчивость разбора (усечённые/удлинённые/случайные датаграммы).
## Часть 3 — NetNode на виртуальном времени (LoopHub): handshake, потери, дубликаты, RTT, обрыв, переход seq.

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
	fn.call()
	if failed == before:
		passed += 1
		print("  ok   %s" % name)


func _init() -> void:
	print("== Часть 1: совместимость с C++ ==")
	run("golden: сборка пакетов даёт байты C++", t_golden_build)
	run("golden: разбор байтов C++ даёт те же поля", t_golden_parse)
	run("golden: AdaptiveTimeout совпадает с C++", t_golden_adaptive)
	run("golden: DedupWindow совпадает с C++", t_golden_dedup)
	run("golden: ReliableChannel совпадает с C++", t_golden_reliable)
	print("== Часть 2: устойчивость разбора ==")
	run("Reader: выход за границу не падает, ok=false", t_reader)
	run("строгие правила requiresAck и типа", t_strict)
	run("усечённые и удлинённые пакеты отклоняются", t_truncated)
	run("20000 случайных датаграмм не ломают разбор", t_fuzz)
	run("лимиты: имя 16 байт, 16 команд, снимок < 500 байт", t_limits)
	print("== Часть 3: NetNode ==")
	run("handshake Hello -> Welcome", t_handshake)
	run("RTT по Ping/Pong ~ 2*lag, RTO адаптируется", t_rtt)
	run("надёжные события при 30%% потерь в обе стороны: все, ровно по разу", t_reliable_loss)
	run("дубликат пакета доставляется один раз, ACK повторяется", t_duplicate)
	run("переход seq через 65535", t_wrap)
	run("обрыв: тишина 3 с -> peer_lost(timeout)", t_timeout)
	run("доставка провалена после MAX_ATTEMPTS", t_reliable_failed)
	run("неизвестный адрес и мусор отбрасываются", t_unknown_and_garbage)
	run("оценка входящих потерь ~ реальным", t_rx_loss)
	run("ненадёжные Input идут без ACK и без повторов", t_unreliable)
	print("\n%d тестов, %d провалено" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)


# ------------------------------------------------------------------ вспомогательное

func _vectors() -> Dictionary:
	var f := FileAccess.open("res://tests/golden_vectors.json", FileAccess.READ)
	return JSON.parse_string(f.get_as_text())


func _hex(b: PackedByteArray) -> String:
	return b.hex_encode()


func _from_hex(s: String) -> PackedByteArray:
	return s.hex_decode()


func _vec(name: String) -> Dictionary:
	for p in _vectors()["packets"]:
		if p["name"] == name:
			return p
	return {}


# ------------------------------------------------------------------ часть 1

func t_golden_build() -> void:
	var v: Array = _vectors()["packets"]
	var by := {}
	for p in v:
		by[p["name"]] = p
	var f: Dictionary
	f = by["ping"]["fields"];       check(_hex(Proto.ping(f["seq"], int(f["t"]))) == by["ping"]["hex"], "ping")
	f = by["pong"]["fields"];       check(_hex(Proto.pong(f["seq"], int(f["t_client"]), int(f["t_srv_rx"]), int(f["t_srv_tx"]))) == by["pong"]["hex"], "pong")
	f = by["movement"]["fields"];   check(_hex(Proto.movement(f["seq"], f["x"], f["y"], f["ack"])) == by["movement"]["hex"], "movement")
	f = by["shoot"]["fields"];      check(_hex(Proto.shoot(f["seq"], f["angle"], f["weapon"], f["ack"])) == by["shoot"]["hex"], "shoot")
	f = by["ack"]["fields"];        check(_hex(Proto.ack(f["seq"], f["acked"])) == by["ack"]["hex"], "ack")
	f = by["hello"]["fields"];      check(_hex(Proto.hello(f["seq"], f["proto"], f["color"], _from_hex(f["name_hex"]))) == by["hello"]["hex"], "hello")
	f = by["welcome"]["fields"];    check(_hex(Proto.welcome(f["seq"], f["status"], f["proto"], f["id"], f["tick"], f["rate"], int(f["seed"]))) == by["welcome"]["hex"], "welcome")
	f = by["input"]["fields"];      check(_hex(Proto.input(f["seq"], f["first"], f["cmds"])) == by["input"]["hex"], "input")
	f = by["snapshot"]["fields"];   check(_hex(Proto.snapshot(f["seq"], f["tick"], f["ack"], f["players"], PackedByteArray(f["owner"]), f["runes"])) == by["snapshot"]["hex"], "snapshot")
	f = by["gameevent"]["fields"];  check(_hex(Proto.game_event(f["seq"], f["id"], f["kind"], f["tick"], f["a"], f["b"], f["x"], f["y"], f["v"])) == by["gameevent"]["hex"], "gameevent")
	f = by["roster"]["fields"]
	var ents := []
	for e in f["entries"]:
		ents.append([e[0], e[1], e[2], _from_hex(e[3])])
	check(_hex(Proto.roster(f["seq"], ents)) == by["roster"]["hex"], "roster")
	f = by["leave"]["fields"];      check(_hex(Proto.leave(f["seq"], f["reason"])) == by["leave"]["hex"], "leave")


func t_golden_parse() -> void:
	var m: Dictionary
	m = Proto.parse(_from_hex(_vec("ping")["hex"]));      check(m["t_client"] == 0x0102030405060708 and m["seq"] == 258, "ping")
	m = Proto.parse(_from_hex(_vec("pong")["hex"]));      check(m["t_srv_tx"] == 3000 and m["t_client"] == 1000, "pong")
	m = Proto.parse(_from_hex(_vec("ack")["hex"]));       check(m["acked"] == 258, "ack")
	m = Proto.parse(_from_hex(_vec("hello")["hex"]));     check(m["name"].get_string_from_utf8() == "Бob" and m["color"] == 2, "hello (кириллица)")
	m = Proto.parse(_from_hex(_vec("welcome")["hex"]));   check(m["seed"] == 0xDEADBEEF and m["tick"] == 65535 and m["rate"] == 120, "welcome")
	m = Proto.parse(_from_hex(_vec("input")["hex"]));     check(m["first"] == 65534 and m["cmds"][0] == [-127, 33] and m["cmds"][2] == [127, 6], "input")
	m = Proto.parse(_from_hex(_vec("snapshot")["hex"]))
	check(m["tick"] == 1234 and m["ack"] == 4321 and m["players"][0] == [1, -300, 800, -1500, 2000, 100, 53, 1027] and m["players"][1][1] == 12345, "snapshot players")
	check(m["owner"] == PackedByteArray([1, 2, 3, 4, 5]) and m["runes"][0] == [9, 3, -50, 600], "snapshot owner/runes")
	m = Proto.parse(_from_hex(_vec("gameevent")["hex"])); check(m["id"] == 513 and m["v"] == -30 and m["x"] == -10, "gameevent")
	m = Proto.parse(_from_hex(_vec("roster")["hex"]))
	check(m["entries"].size() == 2 and m["entries"][0][3].get_string_from_utf8() == "Хо" and m["entries"][1][3].get_string_from_utf8() == "bob", "roster")
	m = Proto.parse(_from_hex(_vec("leave")["hex"]));     check(m["reason"] == 2, "leave")


func t_golden_adaptive() -> void:
	var a: Dictionary = _vectors()["adaptive_timeout"]
	var at := AdaptiveTimeout.new()
	check(absf(at.rto_ms() - float(a["initial_rto"])) < 1e-9, "initial rto")
	for s in a["steps"]:
		at.on_sample(s[0])
		check(absf(at.srtt_ms - s[1]) < 1e-6 and absf(at.rttvar_ms - s[2]) < 1e-6 and absf(at.rto_ms() - s[3]) < 1e-6, "step %s" % str(s))


func t_golden_dedup() -> void:
	var d: Dictionary = _vectors()["dedup"]
	var w := DedupWindow.new(int(d["capacity"]))
	for s in d["steps"]:
		check(w.mark_processed(int(s[0])) == s[1], "seq %d" % s[0])


func t_golden_reliable() -> void:
	var r: Dictionary = _vectors()["reliable"]
	var ch := ReliableChannel.new(int(r["max_attempts"]))
	for e in r["events"]:
		match e[0]:
			"sent":
				ch.on_sent(int(e[1]), PackedByteArray([int(e[1])]), int(e[2]))
			"ack":
				var info := ch.on_ack(int(e[1]), int(e[2]))
				check((not info.is_empty()) == e[3] and int(info["attempts"]) == int(e[4]) and int(info["time_to_ack_us"]) == int(e[5]), "ack")
			"poll":
				var failed_seqs: Array = []
				var due := ch.collect_for_retransmission(int(e[1]), int(r["rto_us"]), failed_seqs)
				var got: Array = []
				for it in due:
					got.append(it["raw"][0])
				var want_due: Array = []
				for x in e[2]:
					want_due.append(int(x))
				var want_failed: Array = []
				for x in e[3]:
					want_failed.append(int(x))
				check(got == want_due, "poll %d due: %s != %s" % [e[1], str(got), str(want_due)])
				check(failed_seqs == want_failed, "poll %d failed: %s != %s" % [e[1], str(failed_seqs), str(want_failed)])


# ------------------------------------------------------------------ часть 2

func t_reader() -> void:
	var r := Wire.Reader.new(PackedByteArray([1, 2, 3]))
	check(r.u16() == 0x0102 and r.ok, "u16")
	check(r.u16() == 0 and not r.ok, "u16 за границей -> 0, ok=false")
	check(r.u64() == 0 and r.u32() == 0 and r.bytes(5).is_empty(), "дальнейшие чтения безопасны")
	var neg := Wire.Reader.new(PackedByteArray([0xFF, 0x80, 0x80, 0x00]))
	check(neg.i8() == -1 and neg.i8() == -128 and neg.i16() == -32768, "знаковые")


func t_strict() -> void:
	var hello := Proto.hello(1, 1, 0, "a".to_utf8_buffer());      hello[7] = 0
	var inp := Proto.input(1, 0, [[1, 1]]);                         inp[7] = 1
	var snap := Proto.snapshot(1, 0, 0, [], PackedByteArray(), []); snap[7] = 1
	var ev := Proto.game_event(1, 1, 1, 1, 1, 1, 1, 1, 1);          ev[7] = 0
	var lv := Proto.leave(1, 0);                                     lv[7] = 0
	var ro := Proto.roster(1, []);                                   ro[7] = 0
	for pkt in [hello, inp, snap, ev, lv, ro]:
		check(Proto.parse(pkt).is_empty(), "неверный requiresAck принят")
	var bad_ver := Proto.ack(1, 1); bad_ver[5] = 0; bad_ver[6] = 3
	check(Proto.parse(bad_ver).is_empty(), "чужая версия принята")
	var bad_type := Proto.ack(1, 1); bad_type[0] = 13
	check(Proto.parse(bad_type).is_empty(), "тип 13 принят")
	bad_type[0] = 0
	check(Proto.parse(bad_type).is_empty(), "тип 0 принят")
	var flag2 := Proto.ack(1, 1); flag2[7] = 2
	check(Proto.parse(flag2).is_empty(), "requiresAck=2 принят")


func _all_samples() -> Array:
	return [
		Proto.ping(1, 5), Proto.pong(1, 1, 2, 3), Proto.ack(1, 1),
		Proto.hello(1, 1, 0, "name".to_utf8_buffer()), Proto.welcome(1, 0, 1, 1, 1, 60, 5),
		Proto.input(1, 5, [[1, 2], [3, 4]]),
		Proto.snapshot(1, 1, 1, [[1, 1, 2, 3, 4, 5, 6, 7]], PackedByteArray([9, 9]), [[1, 1, 1, 1]]),
		Proto.game_event(1, 1, 1, 1, 1, 1, 1, 1, 1), Proto.leave(1, 1),
		Proto.roster(1, [[0, 1, 3, "ab".to_utf8_buffer()], [1, 2, 0, PackedByteArray()]]),
	]


func t_truncated() -> void:
	for pkt in _all_samples():
		for cut in pkt.size():
			check(Proto.parse(pkt.slice(0, cut)).is_empty(), "усечённый до %d принят (тип %d)" % [cut, pkt[0]])
		var longer: PackedByteArray = pkt.duplicate()
		longer.append(0)
		check(Proto.parse(longer).is_empty(), "удлинённый принят (тип %d)" % pkt[0])
		check(not Proto.parse(pkt).is_empty(), "исходный пакет не разобрался (тип %d)" % pkt[0])


func t_fuzz() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var accepted := 0
	for i in 20000:
		var junk := PackedByteArray()
		junk.resize(rng.randi() % 64)
		for k in junk.size():
			junk[k] = rng.randi() & 0xFF
		if junk.size() >= 8 and i % 2 == 0:
			junk[0] = 6 + rng.randi() % 7
			junk[5] = 0
			junk[6] = 2
			junk[3] = 0
			junk[4] = junk.size() - 8
		if not Proto.parse(junk).is_empty():
			accepted += 1
	check(accepted >= 0, "разбор отработал без падений")   # главное — отсутствие ошибок выполнения


func t_limits() -> void:
	var long_name := "0123456789ABCDEFGHIJ".to_utf8_buffer()
	check(Proto.parse(Proto.hello(1, 1, 0, long_name))["name"].size() == 16, "имя обрезано до 16")
	check(Proto.parse(Proto.hello(1, 1, 0, PackedByteArray()))["name"].size() == 0, "пустое имя")
	var cmds := []
	for i in 20:
		cmds.append([1, 1])
	check(Proto.parse(Proto.input(1, 0, cmds))["cmds"].size() == 16, "команд не больше 16")
	check(Proto.parse(Proto.input(1, 0, [])).is_empty(), "0 команд отклонено")
	var pl := []
	for i in 8:
		pl.append([i, 0, 0, 0, 0, 100, 0, 0])
	var rn := []
	for i in 8:
		rn.append([i, 1, 0, 0])
	var owner := PackedByteArray()
	owner.resize(96)
	var raw := Proto.snapshot(1, 0, 0, pl, owner, rn)
	check(raw.size() < 500 and not Proto.parse(raw).is_empty(), "максимальный снимок %d байт" % raw.size())


# ------------------------------------------------------------------ часть 3: NetNode

class Pair:
	var hub := LoopHub.new()
	var host_link: LoopLink
	var cli_link: LoopLink
	var host: NetNode
	var cli: NetNode
	var host_msgs: Array = []
	var cli_msgs: Array = []
	var host_lost: Array = []
	var cli_lost: Array = []
	var cli_failed: Array = []
	var cli_peer := 0     # id хоста в таблице клиента
	var host_peer := 0    # id клиента в таблице хоста

	func _init(lag: float = 0.0, jitter: float = 0.0, loss: float = 0.0, seed_value: int = 7) -> void:
		host_link = LoopLink.new(hub, seed_value)
		cli_link = LoopLink.new(hub, seed_value + 1)
		host_link.set_emulation(lag, jitter, loss)
		cli_link.set_emulation(lag, jitter, loss)
		host = NetNode.new(host_link)
		host.accept_new_peers = true
		cli = NetNode.new(cli_link)
		cli_peer = host_link.link_id
		cli.add_peer(cli_peer)
		host.message.connect(func(p: int, m: Dictionary) -> void:
			host_peer = p
			host_msgs.append(m))
		cli.message.connect(func(_p: int, m: Dictionary) -> void: cli_msgs.append(m))
		host.peer_lost.connect(func(p: int, r: String) -> void: host_lost.append([p, r]))
		cli.peer_lost.connect(func(p: int, r: String) -> void: cli_lost.append([p, r]))
		cli.reliable_failed.connect(func(_p: int, s: int) -> void: cli_failed.append(s))

	## Шаг виртуального времени (по умолчанию 2 мс): обе стороны обрабатывают сеть.
	func step(us: int = 2000) -> void:
		hub.advance_us(us)
		host.process()
		cli.process()

	func run_ms(ms: int) -> void:
		for i in ms / 2:
			step()


func t_handshake() -> void:
	var p := Pair.new(20.0)
	var name := "Игрок1".to_utf8_buffer()
	p.cli.send(p.cli_peer, func(s: int) -> PackedByteArray: return Proto.hello(s, Proto.GAME_PROTO, 3, name), true)
	p.run_ms(100)
	check(p.host_msgs.size() == 1 and p.host_msgs[0]["type"] == Proto.T_HELLO, "хост получил Hello")
	check(p.host_msgs[0]["name"].get_string_from_utf8() == "Игрок1", "кириллица в имени дошла")
	check(p.host.peers.size() == 1, "хост создал собеседника по Hello")
	p.host.send(p.host_peer, func(s: int) -> PackedByteArray: return Proto.welcome(s, 0, Proto.GAME_PROTO, 2, 0, 120, 99), true)
	p.run_ms(100)
	check(p.cli_msgs.size() == 1 and p.cli_msgs[0]["id"] == 2 and p.cli_msgs[0]["rate"] == 120, "клиент получил Welcome")
	check(p.cli.stats(p.cli_peer)["reliable_pending"] == 0 and p.host.stats(p.host_peer)["reliable_pending"] == 0, "оба Hello/Welcome подтверждены")


func t_rtt() -> void:
	var p := Pair.new(50.0)
	p.cli.send(p.cli_peer, func(s: int) -> PackedByteArray: return Proto.hello(s, 1, 0, PackedByteArray()), true)
	p.run_ms(3000)
	var st := p.cli.stats(p.cli_peer)
	check(absf(st["rtt_last"] - 100.0) < 6.0, "rtt_last %.1f" % st["rtt_last"])
	check(absf(st["srtt"] - 100.0) < 6.0, "srtt %.1f" % st["srtt"])
	check(st["rto"] >= 100.0 and st["rto"] < 250.0, "rto %.1f" % st["rto"])
	check(st["jitter"] < 2.0 and st["ping_loss_pct"] == 0.0, "джиттер %.2f, потери пингов %.1f" % [st["jitter"], st["ping_loss_pct"]])


func t_reliable_loss() -> void:
	var p := Pair.new(40.0, 10.0, 0.30, 11)
	p.cli.send(p.cli_peer, func(s: int) -> PackedByteArray: return Proto.hello(s, 1, 0, PackedByteArray()), true)
	# Hello может потеряться — повторяется; ждём появления собеседника на хосте.
	p.run_ms(3000)
	check(p.host.peers.size() == 1, "Hello дошёл через потери")
	var n := 40
	for i in n:
		var id := i
		p.host.send(p.host_peer, func(s: int) -> PackedByteArray: return Proto.game_event(s, id, 1, 0, 0, 0, 0, 0, 0), true)
	p.run_ms(15000)
	var seen := {}
	for m in p.cli_msgs:
		if m["type"] == Proto.T_GAME_EVENT:
			seen[m["id"]] = int(seen.get(m["id"], 0)) + 1
	var missing := 0
	var dups := 0
	for i in n:
		if not seen.has(i):
			missing += 1
		elif seen[i] > 1:
			dups += 1
	var hp: NetNode.Peer = p.host.peers[p.host_peer]
	check(dups == 0, "дубликатов доставлено: %d" % dups)
	# MAX_ATTEMPTS=6 при 30%% потерь в каждую сторону: провал одного события маловероятен, но возможен;
	# событие, объявленное проваленным, не считается ошибкой доставки — сверяем с учётом failed.
	check(missing <= hp.failed_count, "потеряно %d, объявлено проваленными %d" % [missing, hp.failed_count])
	check(missing <= 2, "потеряно слишком много событий: %d" % missing)
	check(hp.retransmits > 0, "повторов не было — потери не эмулировались?")


func t_duplicate() -> void:
	var p := Pair.new(0.0)
	p.cli.send(p.cli_peer, func(s: int) -> PackedByteArray: return Proto.hello(s, 1, 0, PackedByteArray()), true)
	p.run_ms(50)
	p.host.send(p.host_peer, func(s: int) -> PackedByteArray: return Proto.game_event(s, 7, 1, 0, 0, 0, 0, 0, 0), true)
	var raw := Proto.game_event(p.host.peers[p.host_peer].next_seq - 1, 7, 1, 0, 0, 0, 0, 0, 0)
	p.host_link.send(p.host_peer, raw)   # дубликат того же seq (host_peer = id канала клиента)
	p.host_link.send(p.host_peer, raw)
	p.run_ms(100)
	var n := 0
	for m in p.cli_msgs:
		if m["type"] == Proto.T_GAME_EVENT:
			n += 1
	check(n == 1, "событие доставлено %d раз" % n)
	check(p.cli.stats(p.cli_peer)["dup_dropped"] == 2, "дубликатов отброшено: %d" % p.cli.stats(p.cli_peer)["dup_dropped"])
	check(p.host.stats(p.host_peer)["reliable_pending"] == 0, "отправитель получил ACK")


func t_wrap() -> void:
	var p := Pair.new(10.0)
	p.cli.send(p.cli_peer, func(s: int) -> PackedByteArray: return Proto.hello(s, 1, 0, PackedByteArray()), true)
	p.run_ms(100)
	p.host.peers[p.host_peer].next_seq = 65530
	for i in 20:
		var id := i
		p.host.send(p.host_peer, func(s: int) -> PackedByteArray: return Proto.game_event(s, id, 1, 0, 0, 0, 0, 0, 0), true)
		p.run_ms(10)
	p.run_ms(500)
	var ids := {}
	for m in p.cli_msgs:
		if m["type"] == Proto.T_GAME_EVENT:
			ids[m["id"]] = true
	check(ids.size() == 20, "через 65535 дошло %d из 20" % ids.size())
	check(p.host.stats(p.host_peer)["reliable_pending"] == 0, "все подтверждены")


func t_timeout() -> void:
	var p := Pair.new(10.0)
	p.cli.send(p.cli_peer, func(s: int) -> PackedByteArray: return Proto.hello(s, 1, 0, PackedByteArray()), true)
	p.run_ms(500)
	check(p.cli_lost.is_empty() and p.host_lost.is_empty(), "до обрыва все живы")
	# Хост «умер»: перестаём вызывать host.process() и host-часы идут дальше.
	for i in 1800:    # 3.6 с
		p.hub.advance_us(2000)
		p.cli.process()
	check(p.cli_lost.size() == 1 and p.cli_lost[0][1] == "timeout", "клиент заметил обрыв: %s" % str(p.cli_lost))


func t_reliable_failed() -> void:
	var p := Pair.new(0.0, 0.0, 1.0)   # 100%% потерь
	p.cli.timeout_us = 60_000_000      # иначе обрыв по тишине (3 с) наступит раньше провала доставки
	p.cli.send(p.cli_peer, func(s: int) -> PackedByteArray: return Proto.hello(s, 1, 0, PackedByteArray()), true)
	p.run_ms(9000)
	check(p.cli_failed.size() == 1, "доставка объявлена проваленной: %s" % str(p.cli_failed))
	check(p.cli.stats(p.cli_peer)["reliable_failed"] == 1 and p.cli.stats(p.cli_peer)["retransmits"] == NetNode.MAX_ATTEMPTS - 1, "повторов: %d" % p.cli.stats(p.cli_peer)["retransmits"])


func t_unknown_and_garbage() -> void:
	var p := Pair.new(0.0)
	# Незнакомый адрес шлёт не Hello — хост не создаёт собеседника.
	var stranger := LoopLink.new(p.hub, 3)
	stranger.send(p.host_link.link_id, Proto.input(1, 0, [[1, 0]]))
	stranger.send(p.host_link.link_id, PackedByteArray([1, 2, 3]))
	p.run_ms(20)
	check(p.host.peers.is_empty(), "собеседник не создан без Hello")
	check(p.host.unknown_peer_drops == 1 and p.host.bad_packets == 1, "drops=%d bad=%d" % [p.host.unknown_peer_drops, p.host.bad_packets])


func t_rx_loss() -> void:
	var p := Pair.new(10.0, 0.0, 0.25, 21)   # 25%% потерь у каждой стороны
	p.cli.send(p.cli_peer, func(s: int) -> PackedByteArray: return Proto.hello(s, 1, 0, PackedByteArray()), true)
	p.run_ms(1500)
	for i in 600:    # поток ненадёжных пакетов хост -> клиент
		p.host.send(p.host_peer, func(s: int) -> PackedByteArray: return Proto.snapshot(s, 0, 0, [], PackedByteArray(), []), false)
		p.run_ms(6)
	var loss: float = p.cli.stats(p.cli_peer)["rx_loss_pct"]
	check(loss > 12.0 and loss < 40.0, "оценка потерь %.1f%% при реальных 25%%" % loss)


func t_unreliable() -> void:
	var p := Pair.new(0.0)
	p.cli.send(p.cli_peer, func(s: int) -> PackedByteArray: return Proto.hello(s, 1, 0, PackedByteArray()), true)
	p.run_ms(50)
	var before_retx: int = p.host.stats(p.host_peer)["retransmits"]
	p.host_link.loss = 1.0   # хост -> клиент: всё теряется
	p.host.send(p.host_peer, func(s: int) -> PackedByteArray: return Proto.snapshot(s, 1, 0, [], PackedByteArray(), []), false)
	p.run_ms(2000)
	check(p.host.stats(p.host_peer)["reliable_pending"] == 0, "ненадёжный пакет не попал в очередь повторов")
	check(p.host.stats(p.host_peer)["retransmits"] == before_retx, "ненадёжный пакет не повторялся")
