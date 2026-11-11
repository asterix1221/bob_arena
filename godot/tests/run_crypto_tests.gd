extends SceneTree
## Тесты ПР №6 (шифрование): примитивы на GDScript, совместимость байт-в-байт с OpenSSL (C++), слой SecureSession,
## защищённый NetNode (handshake, потери, подмена, повтор, отказ в открытом тексте) и игра поверх шифрования.
##   godot --headless --path godot -s res://tests/run_crypto_tests.gd
##   godot --headless --path godot -s res://tests/run_crypto_tests.gd -- --cpp-port=27095   (+ запущенный secure_server_app)

var passed := 0
var failed := 0
var current := ""
var vec := {}


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


func hx(s: String) -> PackedByteArray:
	return s.hex_decode()


func _init() -> void:
	var f := FileAccess.open("res://tests/crypto_vectors.json", FileAccess.READ)
	vec = JSON.parse_string(f.get_as_text())
	run("X25519: векторы RFC 7748 §6.1", t_x25519_rfc)
	run("X25519: ключи и общий секрет совпадают с OpenSSL", t_x25519_golden)
	run("X25519: точка малого порядка отклоняется", t_x25519_lowOrder)
	run("HKDF-SHA256: ключ сессии совпадает с OpenSSL", t_hkdf_golden)
	run("AES-256-GCM: векторы NIST (тест-кейсы 13, 14, 16)", t_gcm_nist)
	run("AES-256-GCM: байты пакетов совпадают с OpenSSL (10 длин)", t_gcm_golden)
	run("AES-GCM: подмена любого байта/AAD/ключа отклоняется", t_gcm_tamper)
	run("SecureSession: запечатанные пакеты совпадают с C++ побайтно и открываются", t_sealed_golden)
	run("KEY_EXCHANGE: байты совпадают с C++, разбор строгий", t_key_exchange)
	run("SecureSession: туда-обратно для всех типов, seq и requiresAck открыты", t_roundtrip)
	run("SecureSession: подмена заголовка/шифртекста, повтор, перестановка, направление, мусор", t_attacks)
	_net_tests()
	print("\n%d тестов, %d провалено" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)


func _net_tests() -> void:
	run("NetNode+шифрование: handshake, Hello из очереди, Welcome, ACK — всё зашифровано", t_net_basic)
	run("NetNode+шифрование: потери 30%, задержка и джиттер — handshake и надёжные пакеты доходят без дублей", t_net_loss)
	run("NetNode+шифрование: в сети нет открытого текста (имя игрока не видно), без шифрования — видно", t_net_wire)
	run("NetNode+шифрование: подмена байта в пути отклоняется, повторная передача доставляет", t_net_tamper)
	run("NetNode+шифрование: повтор перехваченного пакета (replay) не срабатывает второй раз", t_net_replay)
	run("NetNode+шифрование: открытый текст хосту, шифрование клиенту без хоста-шифровальщика", t_net_plain_mismatch)
	run("NetNode+шифрование: поддельный KEY_EXCHANGE (нулевой ключ), подмена сессии, лимит handshake", t_net_handshake_abuse)
	run("NetNode+шифрование: Ping/Pong, RTT и таймаут работают поверх шифрования", t_net_keepalive)
	run("Игра ПР №4 поверх шифрования: 2 клиента, 30 мс, 3% потерь, бой, ни одного AUTH_FAIL", t_game_encrypted)
	run("Реальный UDP на localhost: handshake и обмен", t_udp_encrypted)
	var cpp_port := 0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--cpp-port="):
			cpp_port = int(a.substr(11))
	if cpp_port > 0:
		run("совместимость: GDScript-клиент <-> C++ secure_server_app (handshake, ACK, Pong)", func() -> void: t_cpp_secure(cpp_port))
	else:
		print("  --   совместимость с C++ пропущена (нет --cpp-port)")


# ------------------------------------------------------------------ сеть

const TICK_US := 8333


## Звено, записывающее исходящие датаграммы и умеющее портить их «в пути».
class TapLink extends LoopLink:
	var log: Array = []                   # все исходящие датаграммы (как их видел бы Wireshark)
	var tamper_types: Array = []          # если не пусто — портим байт шифртекста у датаграмм ENCRYPTED
	var tampered := 0

	func _raw_send(peer: int, data: PackedByteArray) -> void:
		log.append(data.duplicate())
		if not tamper_types.is_empty() and data.size() > 24 and data[0] == Proto.T_ENCRYPTED:
			var d := data.duplicate()
			d[8 + 12] ^= 0x01
			tampered += 1
			super._raw_send(peer, d)
			return
		super._raw_send(peer, data)


class Rig extends RefCounted:
	var hub := LoopHub.new()
	var host_link: TapLink
	var host: NetNode
	var clients: Array = []     # [{link: TapLink, net: NetNode, got: Array}]
	var host_got: Array = []

	func _init(enc_host: bool = true) -> void:
		host_link = TapLink.new(hub, 1)
		host = NetNode.new(host_link)
		host.encryption = enc_host
		host.accept_new_peers = true
		host.message.connect(func(_p: int, m: Dictionary) -> void: host_got.append(m))

	func add_client(enc: bool = true, hello_name: String = "Игрок") -> Dictionary:
		var l := TapLink.new(hub, 100 + clients.size())
		var n := NetNode.new(l)
		n.encryption = enc
		var c := {"link": l, "net": n, "got": [], "failed": 0}
		n.message.connect(func(_p: int, m: Dictionary) -> void: c["got"].append(m))
		n.reliable_failed.connect(func(_p: int, _s: int) -> void: c["failed"] += 1)
		n.add_peer(host_link.link_id)
		var nm := hello_name.to_utf8_buffer()
		n.send(host_link.link_id, func(q: int) -> PackedByteArray: return Proto.hello(q, Proto.GAME_PROTO, 1, nm), true)
		clients.append(c)
		return c

	func step(ms: int) -> void:
		for i in ms:
			hub.advance_us(1000)
			host.process()
			for c in clients:
				c["net"].process()

	func count(list: Array, type: int) -> int:
		var n := 0
		for m in list:
			if m["type"] == type:
				n += 1
		return n


func t_net_basic() -> void:
	var r := Rig.new()
	var c := r.add_client()
	r.step(200)
	check(r.count(r.host_got, Proto.T_HELLO) == 1, "Hello (стоял в очереди до конца handshake) дошёл: %d" % r.count(r.host_got, Proto.T_HELLO))
	var cid := 100 + 0
	check(r.host.peers.has(cid) or r.host.peers.size() == 1, "хост создал собеседника по KEY_EXCHANGE")
	var hid: int = r.host.peers.keys()[0]
	r.host.send(hid, func(q: int) -> PackedByteArray: return Proto.welcome(q, 0, 1, 3, 100, 120, 777), true)
	r.step(200)
	check(r.count(c["got"], Proto.T_WELCOME) == 1, "Welcome дошёл до клиента")
	var hs := r.host.stats(hid)
	var cs: Dictionary = c["net"].stats(r.host_link.link_id)
	check(hs["enc"] and cs["enc"], "обе стороны в зашифрованной сессии")
	check(hs["reliable_pending"] == 0 and cs["reliable_pending"] == 0, "ACK пришли (надёжные пакеты подтверждены)")
	check(hs["retransmits"] == 0 and cs["retransmits"] == 0, "без потерь повторов нет")
	check(r.host.handshakes_done == 1 and c["net"].handshakes_done == 1, "по одному handshake")
	check(r.host.plaintext_rejected == 0 and cs["auth_fail"] == 0 and hs["auth_fail"] == 0, "ни отказов, ни AUTH_FAIL")
	# нет открытых игровых пакетов: первый пакет клиента — KEY_EXCHANGE, дальше только ENCRYPTED
	var types: Array = []
	for d in (c["link"] as TapLink).log:
		types.append(d[0])
	check(types[0] == Proto.T_KEY_EXCHANGE, "первым уходит KEY_EXCHANGE")
	for i in range(1, types.size()):
		check(types[i] == Proto.T_ENCRYPTED, "пакет %d после handshake — ENCRYPTED, а не %d" % [i, types[i]])


func t_net_loss() -> void:
	var r := Rig.new()
	r.host_link.set_emulation(25.0, 10.0, 0.30)
	var cs: Array = []
	for i in 3:
		var c := r.add_client()
		(c["link"] as TapLink).set_emulation(25.0, 10.0, 0.30)
		cs.append(c)
	r.step(3000)
	check(r.host.handshakes_done == 3, "все 3 handshake прошли при 30%% потерь: %d" % r.host.handshakes_done)
	check(r.count(r.host_got, Proto.T_HELLO) == 3, "каждый Hello доставлен ровно один раз (дубли отброшены): %d" % r.count(r.host_got, Proto.T_HELLO))
	for hid in r.host.peers.keys():
		for k in 20:
			r.host.send(hid, func(q: int) -> PackedByteArray: return Proto.game_event(q, k, 1, 0, 0, 0, 0, 0, 0), true)
	r.step(6000)
	for c in cs:
		check(r.count(c["got"], Proto.T_GAME_EVENT) == 20, "клиент получил все 20 надёжных событий ровно по разу: %d" % r.count(c["got"], Proto.T_GAME_EVENT))
		check(c["failed"] == 0, "доставка не провалена")
	var retr := 0
	for hid in r.host.peers.keys():
		retr += int(r.host.stats(hid)["retransmits"])
	check(retr > 0, "потери были, повторы работали (%d)" % retr)
	for hid in r.host.peers.keys():
		check(r.host.stats(hid)["auth_fail"] == 0, "потери не дают AUTH_FAIL")


func t_net_wire() -> void:
	var secret := "Секрет"        # 12 байт UTF-8 (в Hello имя не длиннее 16 байт)
	var needle := secret.to_utf8_buffer()
	for enc in [false, true]:
		var r := Rig.new(enc)
		var c := r.add_client(enc, secret)
		r.step(300)
		var found := false
		for d in (c["link"] as TapLink).log:
			if _contains(d, needle):
				found = true
		check(found == (not enc), "имя игрока %s в датаграммах при enc=%s" % ["видно" if found else "не видно", str(enc)])
		check(r.count(r.host_got, Proto.T_HELLO) == 1, "Hello дошёл (enc=%s)" % str(enc))


func _contains(hay: PackedByteArray, needle: PackedByteArray) -> bool:
	for i in range(0, hay.size() - needle.size() + 1):
		var ok := true
		for j in needle.size():
			if hay[i + j] != needle[j]:
				ok = false
				break
		if ok:
			return true
	return false


func t_net_tamper() -> void:
	var r := Rig.new()
	var c := r.add_client()
	r.step(100)
	var hid: int = r.host.peers.keys()[0]
	var link: TapLink = c["link"]
	link.tamper_types = [Proto.T_ENCRYPTED]          # «прокси-скрипт» портит один байт шифртекста каждого пакета клиента
	var before := r.count(r.host_got, Proto.T_SHOOT)
	c["net"].send(r.host_link.link_id, func(q: int) -> PackedByteArray: return Proto.shoot(q, 45, 2, true), true)
	r.step(250)                                       # RTO после handshake ~100 мс: за 250 мс уйдут 3 попытки из 6
	check(r.count(r.host_got, Proto.T_SHOOT) == before, "испорченный SHOOT сервер не принял")
	var st := r.host.stats(hid)
	check(st["auth_fail"] >= 2, "AUTH_FAIL на хосте: %d (первая отправка и повторы)" % st["auth_fail"])
	link.tamper_types = []
	r.step(1500)                                      # повторная передача идёт уже без порчи
	check(r.count(r.host_got, Proto.T_SHOOT) == before + 1, "после прекращения порчи повтор доставил SHOOT ровно один раз")
	check(r.host.peers.has(hid), "сессия жива: подделки её не сломали")


func t_net_replay() -> void:
	var r := Rig.new()
	var c := r.add_client()
	r.step(100)
	var hid: int = r.host.peers.keys()[0]
	var link: TapLink = c["link"]
	var mark := link.log.size()
	c["net"].send(r.host_link.link_id, func(q: int) -> PackedByteArray: return Proto.shoot(q, 10, 1, true), true)
	r.step(100)
	check(r.count(r.host_got, Proto.T_SHOOT) == 1, "SHOOT принят")
	var captured: PackedByteArray = PackedByteArray()
	for i in range(mark, link.log.size()):
		if link.log[i][0] == Proto.T_ENCRYPTED and link.log[i].size() == 8 + 12 + 1 + 3 + 16:
			captured = link.log[i]
	check(not captured.is_empty(), "перехвачен зашифрованный SHOOT")
	var drops_before: int = r.host.stats(hid)["replay_drops"]
	for k in 5:
		r.hub.deliver(r.host_link.link_id, link.link_id, captured)   # атакующий проигрывает перехваченный пакет
	r.step(100)
	check(r.count(r.host_got, Proto.T_SHOOT) == 1, "повтор не вызвал второй выстрел")
	check(r.host.stats(hid)["replay_drops"] == drops_before + 5, "5 повторов отброшены окном счётчиков")


func t_net_plain_mismatch() -> void:
	# открытый клиент -> шифрующий хост
	var r := Rig.new(true)
	var c := r.add_client(false)
	r.step(4000)
	check(r.host.plaintext_rejected > 0, "хост отбросил открытый текст: %d" % r.host.plaintext_rejected)
	check(r.host.peers.is_empty() and r.host_got.is_empty(), "собеседник не создан, Hello не принят")
	check(c["net"].peers.is_empty(), "открытый клиент не получил ни ACK, ни ответа и сдался по таймауту")
	# шифрующий клиент -> хост без шифрования
	var r2 := Rig.new(false)
	var c2 := r2.add_client(true)
	r2.step(4500)
	check(r2.host.bad_packets > 0 and r2.host.peers.is_empty(), "хост без шифрования не понял KEY_EXCHANGE")
	check(c2["failed"] == 1, "клиент сообщил о провале handshake (reliable_failed)")


func t_net_handshake_abuse() -> void:
	var r := Rig.new()
	# 1. KEY_EXCHANGE с нулевым ключом (точка малого порядка)
	var zero := PackedByteArray()
	zero.resize(32)
	r.hub.deliver(r.host_link.link_id, 999, Proto.key_exchange(0, zero))
	r.step(50)
	check(r.host.peers.is_empty() and r.host.handshakes_rejected == 1, "нулевой ключ отклонён, собеседник не создан")
	# 2. честный клиент подключается; чужой KEY_EXCHANGE с другим ключом «от его имени» не подменяет сессию
	var c := r.add_client()
	r.step(200)
	var hid: int = r.host.peers.keys()[0]
	var evil_pub := X25519.public_key(SecureSession.generate_private())
	r.hub.deliver(r.host_link.link_id, hid, Proto.key_exchange(0, evil_pub))
	r.step(50)
	check(r.host.stats(hid)["enc"] and r.host.handshakes_rejected == 2, "подмена сессии отклонена")
	c["net"].send(r.host_link.link_id, func(q: int) -> PackedByteArray: return Proto.shoot(q, 1, 1, true), true)
	r.step(200)
	check(r.count(r.host_got, Proto.T_SHOOT) == 1, "прежняя сессия продолжает работать")
	# 3. лимит handshake: 6 клиентов сразу -> не более handshake_rate в секунду, остальные добираются повторами
	var r3 := Rig.new()
	for i in 6:
		r3.add_client()
	r3.step(900)
	check(r3.host.handshakes_done <= r3.host.handshake_rate, "за первую секунду принято не больше %d: %d" % [r3.host.handshake_rate, r3.host.handshakes_done])
	check(r3.host.handshakes_rejected > 0, "лишние запросы отклонены")
	r3.step(2500)
	check(r3.host.handshakes_done == 6, "все 6 подключились повторами: %d" % r3.host.handshakes_done)


func t_net_keepalive() -> void:
	var r := Rig.new()
	r.host_link.set_emulation(20.0, 0.0, 0.0)
	var c := r.add_client()
	c["link"].set_emulation(20.0, 0.0, 0.0)
	r.step(6000)
	var hid: int = r.host.peers.keys()[0]
	check(r.host.peers.has(hid) and c["net"].peers.has(r.host_link.link_id), "за 6 с (дольше таймаута 3 с) никто не отвалился")
	var cs: Dictionary = c["net"].stats(r.host_link.link_id)
	check(cs["rtt_last"] > 35.0 and cs["rtt_last"] < 60.0, "RTT через шифрование ~40 мс: %.1f" % cs["rtt_last"])
	check(cs["pkts_out_s"] > 2.0, "пинги идут")


func t_game_encrypted() -> void:
	var hub := LoopHub.new()
	var hl := LoopLink.new(hub, 5)
	hl.set_emulation(30.0, 4.0, 0.03)
	var hn := NetNode.new(hl)
	hn.encryption = true
	var host := GameHost.new(hn, 5)
	var clients: Array = []
	var nets: Array = [hn]
	var events := []
	for i in 2:
		var l := LoopLink.new(hub, 100 + i)
		l.set_emulation(30.0, 4.0, 0.03)
		var n := NetNode.new(l)
		n.encryption = true
		n.add_peer(hl.link_id)
		var c := GameClient.new(n, hl.link_id)
		c.event.connect(func(k: int, _a: int, _b: int, _x: int, _y: int, _v: int) -> void: events.append(k))
		clients.append(c)
		nets.append(n)
		c.join("Игрок%d" % i, i)
	var tick := 0
	var chase := func(c: GameClient) -> Array:
		var best := 1e9
		var axis := 0
		var btn := 0
		for id in c.pub.keys():
			if id == c.my_id or (int(c.pub[id]["flags"]) & 1) == 0:
				continue
			var dx: float = c.pub[id]["x"] - c.state.x / 256.0
			if absf(dx) < best:
				best = absf(dx)
				axis = 127 if dx > 25.0 else (-127 if dx < -25.0 else 0)
				if absf(dx) < 70.0 and tick % 14 == 0:
					btn = Proto.BTN_LIGHT
		return [axis, btn]
	for i in 240:
		tick += 1
		hub.advance_us(TICK_US)
		for c in clients:
			c.process_net()
			var cmd: Array = chase.call(c)
			c.local_tick(cmd[0], cmd[1])
		host.tick_once()
	check(clients[0].my_id >= 0 and clients[1].my_id >= 0 and clients[0].my_id != clients[1].my_id, "оба клиента получили Welcome и id")
	check(host.start_match(), "матч стартовал")
	for i in GC.COUNTDOWN_TICKS + 1500:
		tick += 1
		hub.advance_us(TICK_US)
		for c in clients:
			c.process_net()
			var cmd2: Array = chase.call(c)
			c.local_tick(cmd2[0], cmd2[1])
		host.tick_once()
	check(clients[0].snapshots_in > 500 and clients[1].snapshots_in > 500, "снимки идут по шифрованному каналу: %d / %d" % [clients[0].snapshots_in, clients[1].snapshots_in])
	check(events.size() > 0, "игровые события (попадания и т. п.) дошли: %d" % events.size())
	var bad := 0
	for n in nets:
		for pid in n.peers.keys():
			var st: Dictionary = n.stats(pid)
			bad += int(st["auth_fail"])
			check(st["enc"], "сессия шифруется")
	check(bad == 0 and hn.plaintext_rejected == 0, "ни одного AUTH_FAIL и открытого пакета: %d" % bad)
	check(clients[0].max_error_px < 200.0, "предсказание работает поверх шифрования (макс. ошибка %.1f px)" % clients[0].max_error_px)


func _spin(nodes: Array, ms: int, until: Callable = Callable()) -> void:
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < end:
		for n in nodes:
			n.process()
		if until.is_valid() and until.call():
			return
		OS.delay_msec(2)


func t_udp_encrypted() -> void:
	var hl := UdpLink.new(1)
	check(hl.listen(27096) == OK, "bind 27096")
	var cl := UdpLink.new(2)
	check(cl.connect_to("127.0.0.1", 27096) == OK, "client socket")
	var host := NetNode.new(hl)
	host.accept_new_peers = true
	host.encryption = true
	var cli := NetNode.new(cl)
	cli.encryption = true
	var got := {"hello": 0, "welcome": 0}
	host.message.connect(func(p: int, m: Dictionary) -> void:
		if m["type"] == Proto.T_HELLO:
			got["hello"] += 1
			host.send(p, func(q: int) -> PackedByteArray: return Proto.welcome(q, 0, 1, 2, 100, 120, 5), true))
	cli.message.connect(func(_p: int, m: Dictionary) -> void:
		if m["type"] == Proto.T_WELCOME:
			got["welcome"] += 1)
	var t0 := Time.get_ticks_usec()
	cli.add_peer(1)
	var hs_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	cli.send(1, func(q: int) -> PackedByteArray: return Proto.hello(q, Proto.GAME_PROTO, 0, "Игрок".to_utf8_buffer()), true)
	_spin([host, cli], 3000, func() -> bool: return got["welcome"] >= 1 and cli.stats(1)["reliable_pending"] == 0)
	check(got["hello"] == 1 and got["welcome"] == 1, "Hello -> Welcome по реальному UDP через шифрование: %s" % str(got))
	var st := cli.stats(1)
	check(st["enc"] and st["reliable_pending"] == 0, "сессия шифруется, ACK получены")
	print("       запуск handshake у клиента (X25519 на GDScript): %.0f мс" % hs_ms)
	hl.close()
	cl.close()


func t_cpp_secure(port: int) -> void:
	var cl := UdpLink.new(2)
	check(cl.connect_to("127.0.0.1", port) == OK, "client socket")
	var cli := NetNode.new(cl)
	cli.encryption = true
	cli.add_peer(1)
	for i in 3:
		cli.send(1, func(q: int) -> PackedByteArray: return Proto.shoot(q, 30 * (i + 1), 1, true), true)
	cli.send(1, func(q: int) -> PackedByteArray: return Proto.movement(q, 111, 222, false), false)
	_spin([cli], 3500, func() -> bool: return cli.stats(1).get("reliable_pending", 1) == 0 and (cli.peers[1] as NetNode.Peer).pongs_recv >= 3)
	var p: NetNode.Peer = cli.peers.get(1)
	check(p != null and p.sec != null, "handshake с C++ прошёл (ключи X25519/HKDF совпали с OpenSSL)")
	if p != null:
		check(p.acks_ok == 3, "C++ подтвердил 3 SHOOT зашифрованными ACK: %d" % p.acks_ok)
		check(p.pongs_recv >= 3, "зашифрованные Pong от C++: %d" % p.pongs_recv)
		check(p.sec != null and p.sec.auth_fail == 0, "ни одного AUTH_FAIL: наш AES-GCM принимает пакеты OpenSSL")
		print("       C++ secure_server_app: ACK %d, Pong %d, RTT %.1f мс" % [p.acks_ok, p.pongs_recv, cli.stats(1)["rtt_last"]])
	cl.close()


# ------------------------------------------------------------------ примитивы

func t_x25519_rfc() -> void:
	var a := hx("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	var b := hx("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	var pa := X25519.public_key(a)
	var pb := X25519.public_key(b)
	check(pa.hex_encode() == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", "pub A")
	check(pb.hex_encode() == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f", "pub B")
	var exp := "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
	check(X25519.shared(a, pb).hex_encode() == exp, "shared A")
	check(X25519.shared(b, pa).hex_encode() == exp, "shared B")


func t_x25519_golden() -> void:
	var g: Dictionary = vec["x25519"]
	var pa := X25519.public_key(hx(g["priv_a"]))
	var pb := X25519.public_key(hx(g["priv_b"]))
	check(pa.hex_encode() == g["pub_a"], "pub A = OpenSSL")
	check(pb.hex_encode() == g["pub_b"], "pub B = OpenSSL")
	check(X25519.shared(hx(g["priv_a"]), pb).hex_encode() == g["shared"], "shared = OpenSSL")
	# случайные пары: обе стороны получают один ключ
	for i in 3:
		var x := SecureSession.generate_private()
		var y := SecureSession.generate_private()
		var kx := SecureSession.derive_key(x, X25519.public_key(y))
		var ky := SecureSession.derive_key(y, X25519.public_key(x))
		check(kx.size() == 32 and kx == ky, "случайная пара даёт общий ключ")


func t_x25519_lowOrder() -> void:
	var priv := SecureSession.generate_private()
	var zero := PackedByteArray()
	zero.resize(32)
	check(X25519.shared(priv, zero).is_empty(), "u = 0")
	var one := zero.duplicate()
	one[0] = 1
	check(X25519.shared(priv, one).is_empty(), "u = 1")
	check(SecureSession.derive_key(priv, zero).is_empty(), "derive_key отказывает")


func t_hkdf_golden() -> void:
	var g: Dictionary = vec["x25519"]
	var key := SecureSession.derive_key(hx(g["priv_a"]), hx(g["pub_b"]))
	check(key.hex_encode() == g["session_key"], "ключ сессии = OpenSSL (%s)" % key.hex_encode())
	check(SecureSession.derive_key(hx(g["priv_b"]), hx(g["pub_a"])).hex_encode() == g["session_key"], "со стороны B")


func t_gcm_nist() -> void:
	var z32 := PackedByteArray()
	z32.resize(32)
	var iv0 := PackedByteArray()
	iv0.resize(12)
	var g := AesGcm.new(z32)
	check(g.seal(iv0, PackedByteArray(), PackedByteArray()).hex_encode() == "530f8afbc74536b9a963b4f1c4cb738b", "TC13")
	var z16 := PackedByteArray()
	z16.resize(16)
	check(g.seal(iv0, PackedByteArray(), z16).hex_encode() == "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919", "TC14")
	var g2 := AesGcm.new(hx("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"))
	var iv := hx("cafebabefacedbaddecaf888")
	var p := hx("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
	var a := hx("feedfacedeadbeeffeedfacedeadbeefabaddad2")
	var exp := "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f66276fc6ece0f4e1768cddf8853bb2d551b"
	var out := g2.seal(iv, a, p)
	check(out.hex_encode() == exp, "TC16 (60 байт + AAD)")
	var back: Variant = g2.open(iv, a, out)
	check(back != null and (back as PackedByteArray) == p, "TC16 расшифровка")


func _nonce_of(counter: int) -> PackedByteArray:
	var n := PackedByteArray()
	n.resize(12)
	for i in 8:
		n[4 + i] = (counter >> (56 - 8 * i)) & 0xFF
	return n


func t_gcm_golden() -> void:
	var key := hx(vec["x25519"]["session_key"])
	var g := AesGcm.new(key)
	for item in vec["gcm"]:
		var counter := int(item["counter"])
		var plain := hx(item["plain"])
		var aad := hx(item["aad"])
		var packet := hx(item["packet"])
		var nonce := packet.slice(0, 12)
		check(nonce == _nonce_of(counter), "nonce длины %d" % plain.size())
		var mine := nonce.duplicate()
		mine.append_array(g.seal(nonce, aad, plain))
		check(mine == packet, "байты пакета, длина %d" % plain.size())
		var back: Variant = g.open(nonce, aad, packet.slice(12))
		check(back != null and (back as PackedByteArray) == plain, "расшифровка пакета OpenSSL, длина %d" % plain.size())


func t_gcm_tamper() -> void:
	var key := hx(vec["x25519"]["session_key"])
	var g := AesGcm.new(key)
	var aad := hx("1000010020000200")
	var nonce := _nonce_of(5)
	var plain := "SHOOT angle=271 weapon=4".to_utf8_buffer()
	var ct := g.seal(nonce, aad, plain)
	check(g.open(nonce, aad, ct) != null, "оригинал открывается")
	for i in ct.size():
		var bad := ct.duplicate()
		bad[i] ^= 1
		check(g.open(nonce, aad, bad) == null, "подмена байта %d принята" % i)
	var aad2 := aad.duplicate()
	aad2[3] ^= 1
	check(g.open(nonce, aad2, ct) == null, "подмена AAD принята")
	var n2 := nonce.duplicate()
	n2[11] ^= 1
	check(g.open(n2, aad, ct) == null, "подмена nonce принята")
	var k2 := key.duplicate()
	k2[0] ^= 1
	check(AesGcm.new(k2).open(nonce, aad, ct) == null, "чужой ключ принят")
	check(g.open(nonce, aad, ct.slice(0, 10)) == null, "короче tag")
	check(g.open(nonce, aad, ct.slice(0, ct.size() - 1)) == null, "обрезан")


# ------------------------------------------------------------------ SecureSession

func _pair() -> Array:
	var key := hx(vec["x25519"]["session_key"])
	return [SecureSession.new(key, false), SecureSession.new(key, true)]


func t_sealed_golden() -> void:
	var p := _pair()
	var client: SecureSession = p[0]
	var server: SecureSession = p[1]
	for item in vec["sealed"]:
		var inner := hx(item["inner"])
		var dg := hx(item["datagram"])
		var sender: SecureSession = client if item["from"] == "client" else server
		var receiver: SecureSession = server if item["from"] == "client" else client
		check(sender.seal(inner) == dg, "seal %s: байты как у C++" % item["from"])
		var r := receiver.open(dg)
		check(r["result"] == SecureSession.OK, "open датаграммы C++")
		check(r.get("inner", PackedByteArray()) == inner, "внутренний пакет восстановлен побайтно")


func t_key_exchange() -> void:
	var k: Dictionary = vec["key_exchange"]
	var pub := hx(k["pub"])
	check(Proto.key_exchange(int(k["seq"]), pub) == hx(k["datagram"]), "сборка = C++")
	var m := Proto.parse(hx(k["datagram"]))
	check(not m.is_empty() and m["pub"] == pub and m["seq"] == int(k["seq"]), "разбор")
	var d := hx(k["datagram"])
	check(Proto.parse_key_exchange(d.slice(0, d.size() - 1)).is_empty(), "короткий ключ")
	var longer := d.duplicate()
	longer.append(0)
	check(Proto.parse_key_exchange(longer).is_empty(), "лишний байт")
	var ack := d.duplicate()
	ack[7] = 1
	check(Proto.parse_key_exchange(ack).is_empty(), "requiresAck у KEY_EXCHANGE должен быть 0")
	for t in [13, 14, 15, 16]:
		var q := d.duplicate()
		q[0] = t
		check(not Proto.read_header(q).is_empty(), "тип %d известен заголовку" % t)
	var u := d.duplicate()
	u[0] = 17
	check(Proto.read_header(u).is_empty(), "тип 17 неизвестен")


func t_roundtrip() -> void:
	var p := _pair()
	var client: SecureSession = p[0]
	var server: SecureSession = p[1]
	var inners: Array = [
		Proto.ping(1, 123456789), Proto.movement(2, 1280, 720, true), Proto.shoot(300, 271, 4, true),
		Proto.ack(7, 7), Proto.hello(8, 1, 2, PackedByteArray([0xD0, 0x91, 0x6F, 0x62])), Proto.leave(9, 1),
		Proto.input(10, 65534, [[-127, 33], [127, 6]]),
	]
	for inner in inners:
		var dg := client.seal(inner)
		check(dg.size() == inner.size() + SecureSession.OVERHEAD, "накладные расходы +29 Б")
		var h := Proto.check_encrypted(dg)
		var ih := Proto.read_header(inner)
		check(h["seq"] == ih["seq"] and h["requires_ack"] == ih["requires_ack"], "seq и requiresAck открыты")
		var r := server.open(dg)
		check(r["result"] == SecureSession.OK and r["inner"] == inner, "round-trip типа %d" % ih["type"])
	check(client.seal(Proto.key_exchange(0, hx(vec["key_exchange"]["pub"]))).is_empty(), "handshake вкладывать нельзя")
	check(client.seal(client.seal(inners[0])).is_empty(), "ENCRYPTED вкладывать нельзя")
	check(client.seal(PackedByteArray([1, 2, 3])).is_empty(), "мусор не запечатывается")


func t_attacks() -> void:
	var p := _pair()
	var client: SecureSession = p[0]
	var server: SecureSession = p[1]
	var dg := client.seal(Proto.shoot(300, 271, 4, true))
	var bad := dg.duplicate()
	bad[2] ^= 1
	check(server.open(bad)["result"] == SecureSession.AUTH_FAIL, "подмена seq")
	bad = dg.duplicate()
	bad[7] = 0
	check(server.open(bad)["result"] == SecureSession.AUTH_FAIL, "подмена requiresAck")
	bad = dg.duplicate()
	bad[3] ^= 1
	check(server.open(bad)["result"] == SecureSession.MALFORMED, "подмена payloadSize")
	bad = dg.duplicate()
	bad[8 + 12] ^= 0x80
	check(server.open(bad)["result"] == SecureSession.AUTH_FAIL, "подмена байта шифртекста (негативный тест из задания)")
	check(server.open(dg)["result"] == SecureSession.OK, "оригинал принят: подделка не сожгла счётчик")
	check(server.open(dg)["result"] == SecureSession.REPLAY, "повтор того же датаграмма отклонён")
	# повторная передача: новый nonce, тот же seq
	var inner := Proto.shoot(42, 90, 1, true)
	var first := client.seal(inner)
	var again := client.seal(inner)
	check(first != again, "повтор запечатан с новым nonce")
	var r1 := server.open(first)
	var r2 := server.open(again)
	check(r1["result"] == SecureSession.OK and r2["result"] == SecureSession.OK, "обе копии приняты")
	check(r2.has("inner") and Proto.read_header(r2["inner"])["seq"] == 42, "seq тот же — дедупликация сверху")
	# перестановка
	var sent: Array = []
	for i in 6:
		sent.append(client.seal(Proto.movement(i, 1, 2)))
	for i in [3, 1, 5, 0, 4, 2]:
		check(server.open(sent[i])["result"] == SecureSession.OK, "переставленный %d" % i)
	for i in 6:
		check(server.open(sent[i])["result"] == SecureSession.REPLAY, "повтор %d" % i)
	var old := client.seal(Proto.movement(100, 1, 2))
	for i in 1100:
		server.open(client.seal(Proto.movement(101, 1, 2)))
	check(server.open(old)["result"] == SecureSession.REPLAY, "старше окна")
	# направление
	var c2s := client.seal(Proto.movement(1, 1, 2))
	check(client.open(c2s)["result"] == SecureSession.WRONG_DIRECTION, "эхо своего пакета")
	var s2c := server.seal(Proto.ack(1, 1))
	check(server.open(s2c)["result"] == SecureSession.WRONG_DIRECTION, "пакет не в ту сторону")
	check(client.open(s2c)["result"] == SecureSession.OK, "сервер -> клиент работает")
	# чужой ключ и мусор
	var other_key := hx(vec["x25519"]["session_key"])
	other_key[0] ^= 1
	check(SecureSession.new(other_key, true).open(dg)["result"] != SecureSession.OK, "чужой ключ")
	var rng := RandomNumberGenerator.new()
	rng.seed = 6
	var fresh := _pair()
	var fs: SecureSession = fresh[1]
	var real: PackedByteArray = (fresh[0] as SecureSession).seal(Proto.shoot(1, 2, 3, true))
	for i in 600:
		var junk := PackedByteArray()
		junk.resize(rng.randi() % 90)
		for k in junk.size():
			junk[k] = rng.randi() % 256
		if i % 3 == 0 and junk.size() > 0:
			junk[0] = Proto.T_ENCRYPTED
		check(fs.open(junk)["result"] != SecureSession.OK, "мусор принят")
	for n in real.size():
		check(fs.open(real.slice(0, n))["result"] != SecureSession.OK, "обрезанный до %d принят" % n)
	check(fs.open(real)["result"] == SecureSession.OK, "настоящий принят после мусора")
