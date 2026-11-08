extends SceneTree
## ПР №5: профилирование репликации «до/после». Запуск (из папки godot):
##   godot --headless --path . --script tests/run_repl_profile.gd -- [--out=<папка>] [--seconds=30] [--clients=3] [--quick]
## Прогоняет идентичный сценарий (seed 7, 3 клиента, 30 с игры + 2 с входа) для набора конфигураций и пишет JSON:
##   baseline.json, optimized.json, results.json (все прогоны), saturation.json (проверка NetPriority при нехватке бюджета).
## Отчёты docs/Replication_Baseline.md и docs/Replication_Optimization.md строит tools/repl_report.py из этих JSON.

const SAT_BUDGET := 600


func _init() -> void:
	var out_dir := ProjectSettings.globalize_path("res://").path_join("../docs/repl").simplify_path()
	var seconds := 30
	var clients := 3
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--seconds="):
			seconds = int(a.substr(10))
		elif a.begins_with("--clients="):
			clients = int(a.substr(10))
	DirAccess.make_dir_recursive_absolute(out_dir)
	var opts := {"seconds": seconds, "clients": clients, "seed": 7}

	var runs: Array = []
	var configs: Array = []
	configs.append(ReplCfg.baseline())
	configs.append(ReplCfg.optimized())
	for k in ["relevancy", "dormancy", "push", "quantize", "freq", "priority"]:
		configs.append(ReplCfg.only([k], "only_" + k))
	var chain: Array = []
	for k in ["relevancy", "custom_relevance", "dormancy", "push", "quantize", "freq", "priority"]:
		chain.append(k)
		configs.append(ReplCfg.only(chain.duplicate(), "chain_" + str(chain.size()) + "_" + k))

	print("ПР №5 · профиль репликации: %d с, %d клиентов, %d конфигураций" % [seconds, clients, configs.size()])
	for cfg: ReplCfg in configs:
		var t0 := Time.get_ticks_msec()
		var r := ReplScenario.run(cfg, opts)
		r["wall_ms"] = Time.get_ticks_msec() - t0
		runs.append(r)
		var s: Dictionary = r["steady"]
		print("  %-26s %8.1f КБ/с всего | %7.2f КБ/с на клиента | акторов у клиента %5.1f | ошибка %.2f px | %d мс" % [
			cfg.name, s["kb_s_total"], s["kb_s_per_client"], s["known_avg"], r["quality"]["err_avg_px"], r["wall_ms"]])

	var base: Dictionary = runs[0]
	var same := true
	for r: Dictionary in runs:
		if int(r["checksum"]) != int(base["checksum"]):
			same = false
	print("Контрольная сумма мира одинакова во всех прогонах: %s (%d)" % ["да" if same else "НЕТ", base["checksum"]])

	# Нехватка бюджета: NetPriority выкл/вкл при одинаковом бюджете (без релевантности — спрос 1491 Б/тик против бюджета)
	var sat: Array = []
	for pr in [false, true]:
		var c := ReplCfg.new()
		c.name = "saturated_priority_" + ("on" if pr else "off")
		c.priority = pr
		c.budget_bytes = SAT_BUDGET
		sat.append(ReplScenario.run(c, opts))
	for r: Dictionary in sat:
		var pe: Dictionary = r["quality"]["per_class_err_px"]
		print("  %-26s ошибка по классам, px: бот %.1f, снаряд %.1f, игрок %.1f, дерево %.1f" % [r["config"], pe["bot"], pe["projectile"], pe["player"], pe["tree"]])

	_save(out_dir.path_join("baseline.json"), runs[0])
	_save(out_dir.path_join("optimized.json"), runs[1])
	_save(out_dir.path_join("results.json"), {"seconds": seconds, "clients": clients, "same_checksum": same, "runs": runs})
	_save(out_dir.path_join("saturation.json"), {"budget": SAT_BUDGET, "runs": sat})
	print("Результаты записаны: " + out_dir)
	quit(0 if same else 1)


func _save(path: String, data: Variant) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("не удалось записать " + path)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
