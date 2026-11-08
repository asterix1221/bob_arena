extends SceneTree
## Тесты на РЕАЛЬНЫХ UDP-сокетах (localhost) и совместимость с C++-сервером ПР №2.
##   godot --headless --path godot -s res://tests/run_udp_tests.gd
##   godot --headless --path godot -s res://tests/run_udp_tests.gd -- --cpp-port=27090   (+ запущенный pong_server_app)
## Тесты идут в реальном времени (по секунде-две каждый).

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
	run("UDP localhost: Hello -> Welcome -> события", t_udp_basic)
	run("UDP localhost + эмуляция 30 мс: RTT ~ 60 мс", t_udp_emu)
	var cpp_port := 0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--cpp-port="):
			cpp_port = int(a.substr(11))
	if cpp_port > 0:
		run("совместимость: наш Ping -> C++ pong_server_app -> Pong", func() -> void: t_cpp_pong(cpp_port))
	else:
		print("  --   совместимость с C++ пропущена (нет --cpp-port)")
	print("\n%d тестов, %d провалено" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)


## Крутит оба узла в реальном времени ms миллисекунд.
func _spin(nodes: Array, ms: int, until: Callable = Callable()) -> void:
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < end:
		for n in nodes:
			n.process()
		if until.is_valid() and until.call():
			return
		OS.delay_msec(2)


func t_udp_basic() -> void:
	var hl := UdpLink.new(1)
	check(hl.listen(27091) == OK, "bind 27091")
	var cl := UdpLink.new(2)
	check(cl.connect_to("127.0.0.1", 27091) == OK, "client socket")
	var host := NetNode.new(hl)
	host.accept_new_peers = true
	var cli := NetNode.new(cl)
	cli.add_peer(1)
	var got := {"hello": false, "welcome": false, "events": 0, "cli_id": 0}
	host.message.connect(func(peer: int, m: Dictionary) -> void:
		if m["type"] == Proto.T_HELLO:
			got["hello"] = (m["name"].get_string_from_utf8() == "Тест")
			got["cli_id"] = peer
			host.send(peer, func(s: int) -> PackedByteArray: return Proto.welcome(s, 0, 1, 2, 0, 120, 5), true)
			for i in 5:
				var id := i
				host.send(peer, func(s: int) -> PackedByteArray: return Proto.game_event(s, id, 1, 0, 0, 0, 0, 0, 0), true))
	cli.message.connect(func(_p: int, m: Dictionary) -> void:
		if m["type"] == Proto.T_WELCOME:
			got["welcome"] = true
		elif m["type"] == Proto.T_GAME_EVENT:
			got["events"] += 1)
	cli.send(1, func(s: int) -> PackedByteArray: return Proto.hello(s, 1, 0, "Тест".to_utf8_buffer()), true)
	_spin([host, cli], 3000, func() -> bool: return got["welcome"] and got["events"] >= 5)
	check(got["hello"], "Hello с кириллицей дошёл по реальному UDP")
	check(got["welcome"] and got["events"] == 5, "Welcome и 5 событий: welcome=%s events=%d" % [got["welcome"], got["events"]])
	_spin([host, cli], 300)
	check(cli.stats(1)["reliable_pending"] == 0, "клиент: нечего повторять")
	hl.close()
	cl.close()


func t_udp_emu() -> void:
	var hl := UdpLink.new(1)
	hl.listen(27092)
	hl.set_emulation(30.0, 0.0, 0.0)
	var cl := UdpLink.new(2)
	cl.connect_to("127.0.0.1", 27092)
	cl.set_emulation(30.0, 0.0, 0.0)
	var host := NetNode.new(hl)
	host.accept_new_peers = true
	var cli := NetNode.new(cl)
	cli.add_peer(1)
	cli.send(1, func(s: int) -> PackedByteArray: return Proto.hello(s, 1, 0, PackedByteArray()), true)
	_spin([host, cli], 2500)
	var st := cli.stats(1)
	check(st["rtt_last"] > 55.0 and st["rtt_last"] < 90.0, "rtt_last %.1f (ожидалось ~60)" % st["rtt_last"])
	hl.close()
	cl.close()


func t_cpp_pong(port: int) -> void:
	var cl := UdpLink.new(2)
	check(cl.connect_to("127.0.0.1", port) == OK, "client socket")
	var cli := NetNode.new(cl)
	cli.add_peer(1)
	# NetNode сам шлёт Ping каждые 250 мс; C++ сервер отвечает Pong, наш парсер его принимает.
	_spin([cli], 2200)
	var p: NetNode.Peer = cli.peers.get(1)
	check(p != null, "собеседник жив (C++ отвечает)")
	if p != null:
		check(p.pongs_recv >= 5, "получено Pong от C++: %d" % p.pongs_recv)
		check(cli.bad_packets == 0, "наш разбор принял все пакеты C++ (bad=%d)" % cli.bad_packets)
		var st := cli.stats(1)
		check(st["rtt_last"] > 0.0 and st["rtt_last"] < 500.0, "RTT до C++: %.1f мс" % st["rtt_last"])
		print("       C++ pong_server_app: Pong получено %d, RTT %.1f мс" % [p.pongs_recv, st["rtt_last"]])
	cl.close()
