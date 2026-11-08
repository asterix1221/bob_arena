class_name Shots
extends Node
## Автоматизация для проверки интерфейса без человека: проходит экраны и сохраняет скриншоты (PNG), либо замеряет инпутлаг.
## Запуск (под виртуальным дисплеем на сервере сборки): godot --path godot -- --shots=<каталог> [--shot-role=client --join=... --port=...]
## Роли: solo (по умолчанию) — хост + бот в одном процессе, все экраны; client — подключается к хосту и снимает net_graph клиента.

var app: App
var dir := ""


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [dir, name])
	print("[SHOT] %s" % name)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _wait_until(cond: Callable, timeout: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)


func run(out_dir: String) -> void:
	dir = out_dir
	DirAccess.make_dir_recursive_absolute(dir)
	var role := String(app._args.get("shot-role", "solo"))
	if app._args.has("lag-test"):
		await _lag_test()
	elif role == "client":
		await _role_client()
	elif role == "host":
		await _role_host()
	elif role == "host2":
		await _role_host2()
	else:
		await _role_solo()
	get_tree().quit()


func _role_solo() -> void:
	await _wait(0.6)
	await _shot("01_menu")
	app.set_net_preset(0)
	app.start_host("Алиса", 1, app._free_port(), true)
	await _wait_until(func() -> bool: return app.host != null and app.host.slots.size() >= 2, 5.0)
	await _wait(0.4)
	await _shot("02_lobby")
	app.host.start_match()
	await _wait(1.3)
	await _shot("03_countdown")
	await _wait_until(func() -> bool: return app.host.phase == GC.PHASE_PLAYING, 6.0)
	await _wait(0.6)
	var me: PState = app.host.slots[app.my_id].state
	# руны на земле (по одной каждого типа вдоль платформ)
	app.host.rune_interval = 0
	app.bots[0]["brain"].enabled = false        # бот стоит, чтобы кадры были спокойными
	var spots := [[90, 330], [150, 330], [210, 330], [270, 330], [1010, 330], [1070, 330], [1130, 330], [1190, 330], [560, 460], [640, 460], [720, 460]]
	for i in spots.size():
		app.host.runes.append({"id": i + 1, "type": i, "x": spots[i][0] * GC.SUB, "y": spots[i][1] * GC.SUB})
	await _wait(0.5)
	await _shot("04_runes_on_ground")
	app.host.runes.clear()
	# ауры: наборы по три руны на игроке-хосте, второй (бот) тоже получает набор для сравнения
	var sets := [[GC.R_SPEED, GC.R_JUMP, GC.R_DAMAGE], [GC.R_KNOCKBACK, GC.R_VAMPIRE, GC.R_ARMOR], [GC.R_STEADY, GC.R_SLOWHIT, GC.R_INVERTHIT], [GC.R_CHAOS]]
	var bot_state: PState = app.host.slots[1].state
	for si in sets.size():
		for k in GC.NUM_RUNES:
			me.buffs[k] = 0
		for r in sets[si]:
			Combat.apply_pickup(me, r)
		await _wait(0.5)
		await _shot("05_auras_%d" % (si + 1))
	for k in GC.NUM_RUNES:
		me.buffs[k] = 0
	bot_state.slow = 300
	bot_state.invert = 300
	Combat.apply_pickup(me, GC.R_SPEED)
	Combat.apply_pickup(me, GC.R_DAMAGE)
	await _wait(0.4)
	await _shot("06_debuffs_on_bot")
	# переключатель здоровья (H)
	me.hp = 64
	bot_state.hp = 37
	await _wait(0.3)
	await _shot("07_hp_on")
	app._input(_press(KEY_H))
	await _wait(0.3)
	await _shot("08_hp_off")
	app._input(_press(KEY_H))
	# net_graph (F3) в режиме хоста
	app._input(_press(KEY_F3))
	await _wait(1.2)
	await _shot("09_netgraph_host")
	app._input(_press(KEY_F3))
	# бой: бот атакует, хост стоит — всплески, оглушение
	bot_state.x = me.x + 30 * GC.SUB
	bot_state.y = me.y
	bot_state.facing = -1
	bot_state.atk_kind = 1
	bot_state.atk_tick = 0
	bot_state.hit_mask = 0
	await _wait(0.12)
	await _shot("10_hit")
	# победа: бот падает с арены
	bot_state.y = 950 * GC.SUB
	await _wait_until(func() -> bool: return app.screen == "result", 6.0)
	await _wait(0.4)
	await _shot("11_victory")
	app.host.rematch()
	await _wait(0.6)
	await _shot("12_lobby_after")
	app.host.start_match()
	await _wait_until(func() -> bool: return app.host.phase == GC.PHASE_PLAYING, 6.0)
	await _wait(0.5)
	# поражение: хост падает
	app.host.slots[app.my_id].state.y = 950 * GC.SUB
	await _wait_until(func() -> bool: return app.screen == "result", 6.0)
	await _wait(0.4)
	await _shot("13_defeat")
	# пауза не снимаем отдельно: показываем экран обрыва связи искусственно
	app._on_disconnected("timeout")
	await _wait(0.4)
	await _shot("14_disconnected")


## Хост для двухпроцессной проверки по реальному UDP: ждёт клиента, играет бота-«манекена», отдаёт победу клиенту, закрывает игру.
func _role_host2() -> void:
	app.start_host(String(app._args.get("name", "Хост")), int(app._args.get("color", 0)), int(app._args.get("port", App.DEFAULT_PORT)), false)
	await _wait_until(func() -> bool: return app.host != null and app.host.slots.size() >= 2, 40.0)
	await _wait(1.0)
	await _shot("h01_lobby_host")
	app.host.start_match()
	await _wait_until(func() -> bool: return app.host.phase == GC.PHASE_PLAYING, 6.0)
	await _wait(16.0)
	await _shot("h02_playing_host")
	app.host.slots[app.my_id].state.y = 950 * GC.SUB       # хост «падает» — клиент побеждает
	await _wait(6.0)
	await _shot("h03_result_host")
	await _wait(2.0)
	app.leave_to_menu()
	await _wait(2.0)


func _press(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = true
	return ev


func _role_host() -> void:
	## Хост без бота: ждёт настоящего клиента (другой процесс), играет с ним, затем «падает» — клиент видит победу, потом обрыв.
	app.set_net_preset(int(app._args.get("preset", 0)))
	app.start_host("Хост", 0, int(app._args.get("port", 24680)), false)
	await _wait_until(func() -> bool: return app.host != null and app.host.slots.size() >= 2, 30.0)
	await _wait(0.5)
	await _shot("h01_lobby_two_processes")
	app.host.start_match()
	await _wait_until(func() -> bool: return app.host.phase == GC.PHASE_PLAYING, 8.0)
	await _wait(9.0)
	await _shot("h02_playing_with_real_client")
	app.host.slots[app.my_id].state.y = 950 * GC.SUB
	await _wait_until(func() -> bool: return app.screen == "result", 8.0)
	await _wait(4.0)
	await _shot("h03_host_result")


func _role_client() -> void:
	app.set_net_preset(int(app._args.get("preset", 2)))
	app.start_join(String(app._args.get("name", "Клиент")), int(app._args.get("color", 2)), String(app._args.get("join", "127.0.0.1")), int(app._args.get("port", App.DEFAULT_PORT)))
	await _wait_until(func() -> bool: return app.my_id >= 0, 8.0)
	await _wait(0.5)
	await _shot("c01_lobby_client")
	await _wait_until(func() -> bool: return app.screen == "game" and app.client != null and app.client.phase == GC.PHASE_PLAYING, 20.0)
	await _wait(1.5)
	# побегать влево-вправо (в пределах платформы) и попрыгать, чтобы в статистике был ввод
	for i in 6:
		var dir: Key = KEY_D if i % 2 == 0 else KEY_A
		_key(dir, true)
		_key(KEY_SPACE, true)
		await _wait(0.06)
		_key(KEY_SPACE, false)
		await _wait(0.2)
		_key(dir, false)
		await _wait(0.05)
	app._input(_press(KEY_F3))
	await _wait(1.5)
	await _shot("c02_netgraph_client")
	await _wait_until(func() -> bool: return app.screen == "result" or app.screen == "disconnected", 40.0)
	await _wait(0.5)
	await _shot("c03_client_final_screen")
	await _wait_until(func() -> bool: return app.screen == "disconnected", 10.0)
	await _wait(0.4)
	await _shot("c04_client_disconnected")


func _lag_test() -> void:
	app.set_vsync(int(app._args.get("vsync", 3)))
	app.start_host("Тест", 0, app._free_port(), true)
	await _wait_until(func() -> bool: return app.host != null and app.host.slots.size() >= 2, 5.0)
	app.host.start_match()
	await _wait_until(func() -> bool: return app.host.phase == GC.PHASE_PLAYING, 6.0)
	await _wait(0.5)
	app.lag_meter = InputLagMeter.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for i in 120:
		await _wait(rng.randf_range(0.02, 0.09))
		await get_tree().process_frame       # события ОС приходят в начале кадра — имитируем так же
		var code: Key = KEY_SPACE if i % 2 == 0 else KEY_SHIFT
		_key(code, true)
		await get_tree().process_frame
		_key(code, false)
	await _wait(0.3)
	var st := app.lag_meter.stats()
	print("[LAG] samples=%d event->tick avg=%.2f max=%.2f ms | event->frame avg=%.2f max=%.2f ms | fps=%d ticks_last_frame=%d" % [
		st["samples"], st["tick_avg"], st["tick_max"], st["draw_avg"], st["draw_max"], int(app.fps_smooth), app.ticks_last_frame])
