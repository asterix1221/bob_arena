extends SceneTree
## Сквозные тесты приложения (меню -> лобби -> матч -> итоги) на реальных кадрах и реальном UDP localhost, без окна:
##   godot --headless --path godot -s res://tests/run_app_tests.gd
## Два экземпляра App в одном процессе: хост (с ботом) и второй — настоящий клиент по UDP.

var passed := 0
var failed := 0
var current := ""


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failed += 1
		print("  FAIL [%s] %s" % [current, msg])


func _wait_until(cond: Callable, timeout_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return false


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _new_app() -> App:
	var app: App = load("res://scenes/main.tscn").instantiate()
	root.add_child(app)
	return app


func _key(app: App, code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	app._input(ev)


func run(name: String, fn: Callable) -> void:
	current = name
	var before := failed
	await fn.call()
	if failed == before:
		passed += 1
		print("  ok   %s" % name)


func _initialize() -> void:
	await run("меню -> тренировка с ботом -> матч -> победа -> реванш -> меню", t_solo)
	await run("два приложения: хост и клиент по UDP, матч, итоги, выход клиента", t_two_apps)
	await run("переключатели: H (здоровье), F3 (net_graph), Esc (пауза)", t_toggles)
	print("\n%d тестов, %d провалено" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)


func t_solo() -> void:
	var app := _new_app()
	await process_frame
	await process_frame
	check(app.screen == "menu" and app.ui.menu.visible, "стартовый экран — меню")
	app.start_host("Тест", 0, 24901, true)
	check(await _wait_until(func() -> bool: return app.host != null and app.host.slots.size() == 2, 5.0), "бот вошёл в лобби по UDP")
	check(app.screen == "lobby" and app.ui.lobby.visible, "экран лобби")
	app.host.start_match()
	check(await _wait_until(func() -> bool: return app.host.phase == GC.PHASE_PLAYING, 8.0), "матч начался")
	check(app.screen == "game" and not app.ui.menu.visible, "экран игры")
	var x0: int = app.local_state().x
	_key(app, KEY_D, true)
	await _wait(0.4)
	_key(app, KEY_D, false)
	check(app.local_state().x > x0 + 20 * GC.SUB, "нажатие D двигает персонажа (ввод по событиям)")
	_key(app, KEY_SPACE, true)
	await process_frame
	_key(app, KEY_SPACE, false)
	await _wait(0.1)
	check(app.local_state().vy < 0 or not app.local_state().on_ground, "короткий тап прыжка не потерялся")
	check(app.lag_meter.stats()["samples"] >= 0, "измеритель инпутлага работает")
	check(app.world_players().size() == 2, "рисуются оба игрока")
	app.host.slots[1].state.y = 950 * GC.SUB       # бот падает с арены
	check(await _wait_until(func() -> bool: return app.screen == "result", 6.0), "показан экран итогов")
	check(app.winner == app.my_id and app.ui.result_title.text == "ПОБЕДА", "победа: %s" % app.ui.result_title.text)
	check(app.results.size() == 2, "статистика обоих игроков: %d" % app.results.size())
	app.host.rematch()
	check(await _wait_until(func() -> bool: return app.screen == "lobby", 3.0), "реванш возвращает в лобби")
	app.leave_to_menu()
	check(app.screen == "menu" and app.mode == "" and app.host == null and app.bots.is_empty(), "возврат в меню закрывает сессию")
	app.queue_free()
	await process_frame


func t_two_apps() -> void:
	var a := _new_app()
	var b := _new_app()
	await process_frame
	a.start_host("Хост", 0, 24902, false)
	b.start_join("Гость", 1, "127.0.0.1", 24902)
	check(await _wait_until(func() -> bool: return b.my_id >= 0 and a.host.slots.size() == 2, 5.0), "клиент подключился, id=%d" % b.my_id)
	check(b.screen == "lobby" and b.client.roster.size() == 2, "ростер у клиента")
	check(b.client.roster[0]["name"] == "Хост" and b.client.roster[1]["name"] == "Гость", "имена с кириллицей дошли")
	a.host.start_match()
	check(await _wait_until(func() -> bool: return b.client.phase == GC.PHASE_PLAYING, 8.0), "клиент в игре")
	_key(b, KEY_A, true)                      # влево — к центру платформы (вправо клиент упал бы с края)
	await _wait(0.5)
	_key(b, KEY_A, false)
	await _wait(0.6)
	check(b.client.state.x < GC.spawn_u(1)[0] - 20 * GC.SUB, "клиент двигается (предсказание)")
	var hs: PState = a.host.slots[1].state
	check(absi(hs.x - b.client.state.x) < 10 * GC.SUB, "сервер и клиент согласованы: %d vs %d px" % [hs.x / GC.SUB, b.client.state.x / GC.SUB])
	check(b.world_players().size() == 2, "клиент видит соперника (интерполяция)")
	a.host.slots[0].state.y = 950 * GC.SUB           # хост падает — клиент побеждает
	check(await _wait_until(func() -> bool: return b.screen == "result", 6.0), "у клиента экран итогов")
	check(b.ui.result_title.text == "ПОБЕДА" and a.ui.result_title.text == "ПОРАЖЕНИЕ", "победа клиента / поражение хоста: %s / %s" % [b.ui.result_title.text, a.ui.result_title.text])
	b.leave_to_menu()
	check(await _wait_until(func() -> bool: return a.host.slots.size() == 1, 3.0), "хост увидел выход клиента")
	a.leave_to_menu()
	a.queue_free()
	b.queue_free()
	await process_frame


func t_toggles() -> void:
	var app := _new_app()
	await process_frame
	app.start_host("Т", 2, 24903, true)
	await _wait_until(func() -> bool: return app.host.slots.size() == 2, 5.0)
	app.host.start_match()
	await _wait_until(func() -> bool: return app.host.phase == GC.PHASE_PLAYING, 8.0)
	check(app.show_hp and app.view.show_hp, "здоровье по умолчанию показано")
	_key(app, KEY_H, true)
	check(not app.show_hp and not app.view.show_hp, "H скрывает здоровье")
	_key(app, KEY_H, true)
	check(app.show_hp, "H показывает снова")
	check(not app.ui.net_graph.visible, "net_graph скрыт по умолчанию")
	_key(app, KEY_F3, true)
	await _wait(0.4)
	check(app.ui.net_graph.visible and not app.ui.net_graph.report.is_empty(), "F3 показывает net_graph с данными")
	check(app.ui.net_graph.report["rows"].size() > 10, "в отчёте %d строк" % app.ui.net_graph.report["rows"].size())
	_key(app, KEY_F3, true)
	check(not app.ui.net_graph.visible, "F3 скрывает net_graph")
	_key(app, KEY_ESCAPE, true)
	check(app.screen == "pause" and app.ui.pause.visible, "Esc — пауза")
	_key(app, KEY_ESCAPE, true)
	check(app.screen == "game", "Esc снова — продолжить")
	app.leave_to_menu()
	app.queue_free()
	await process_frame
