class_name ReplProfiler
extends RefCounted
## Профилировщик исходящего трафика репликации — аналог `netprofile enable` + Network Profiler из Unreal Engine.
## Считает на сервере: байты «на проводе» (8 байт заголовка протокола + полезная нагрузка + 28 байт IPv4/UDP — так же, как NetNode),
## пакеты, записи (обновления акторов), поля, разбивку по классам и по отдельным акторам («тяжёлые» акторы), число известных
## клиенту акторов, КБ/с по секундам и пик за 100 мс, время сетевого тика сервера. Данные делятся на фазы: join (начальная
## синхронизация) и steady (установившаяся игра) — сравнение «до/после» делается по steady.

const WINDOW_TICKS := 6         # окно для пика: 100 мс при 60 Гц

var enabled := true
var clients := 1
var phases := {}                # имя -> Phase
var cur: Phase = null


class Phase extends RefCounted:
	var name := ""
	var start_tick := 0
	var ticks := 0
	var wire_bytes := 0
	var payload_bytes := 0
	var overhead_bytes := 0
	var packets := 0
	var entries := 0
	var fields := 0
	var per_class := {}         # cls -> {entries, bytes}
	var per_actor := {}         # id -> {bytes, cls, entries}
	var per_kind := {}          # "update"/"reliable" -> {packets, bytes, entries}
	var reliable_ops := {"spawn": 0, "state": 0, "destroy": 0}
	var series: Array = []      # байт за каждую секунду мира (все клиенты)
	var win_acc := 0
	var win_peak := 0
	var known_sum := 0
	var known_samples := 0
	var known_max := 0
	var cpu_us := 0
	var cpu_samples := 0
	var cpu_max := 0
	var relevance_checks := 0
	var cells_visited := 0


func begin(phase_name: String, tick: int) -> void:
	var p := Phase.new()
	p.name = phase_name
	p.start_tick = tick
	phases[phase_name] = p
	cur = p


func tick(world_tick: int) -> void:
	if cur == null or not enabled:
		return
	cur.ticks = world_tick - cur.start_tick
	var sec := maxi(cur.ticks - 1, 0) / ReplDefs.WORLD_HZ
	while cur.series.size() <= sec:
		cur.series.append(0)
	if cur.ticks % WINDOW_TICKS == 0:
		cur.win_peak = maxi(cur.win_peak, cur.win_acc)
		cur.win_acc = 0


func add_bytes(n: int) -> void:
	if cur == null or not enabled:
		return
	cur.wire_bytes += n
	cur.win_acc += n
	var sec := maxi(cur.ticks, 0) / ReplDefs.WORLD_HZ
	while cur.series.size() <= sec:
		cur.series.append(0)
	cur.series[sec] += n


## Пакет целиком: kind — "update"/"reliable"; payload — размер полезной нагрузки (после заголовка в 8 байт).
func packet(kind: String, payload: int, n_entries: int) -> void:
	if cur == null or not enabled:
		return
	var total := payload + ReplDefs.WIRE_OVERHEAD
	cur.packets += 1
	cur.payload_bytes += payload
	cur.overhead_bytes += ReplDefs.WIRE_OVERHEAD
	cur.entries += n_entries
	var k: Dictionary = cur.per_kind.get(kind, {"packets": 0, "bytes": 0, "entries": 0})
	k["packets"] += 1
	k["bytes"] += total
	k["entries"] += n_entries
	cur.per_kind[kind] = k
	add_bytes(total)


## Одна запись (актор) внутри пакета.
func entry(actor_id: int, cls: int, bytes: int, n_fields: int) -> void:
	if cur == null or not enabled:
		return
	cur.fields += n_fields
	var c: Dictionary = cur.per_class.get(cls, {"entries": 0, "bytes": 0})
	c["entries"] += 1
	c["bytes"] += bytes
	cur.per_class[cls] = c
	var a: Dictionary = cur.per_actor.get(actor_id, {"bytes": 0, "cls": cls, "entries": 0})
	a["bytes"] += bytes
	a["entries"] += 1
	cur.per_actor[actor_id] = a


func reliable_op(kind: String) -> void:
	if cur != null and enabled:
		cur.reliable_ops[kind] = int(cur.reliable_ops.get(kind, 0)) + 1


func known(n: int) -> void:
	if cur == null or not enabled:
		return
	cur.known_sum += n
	cur.known_samples += 1
	cur.known_max = maxi(cur.known_max, n)


func cpu(us: int) -> void:
	if cur == null or not enabled:
		return
	cur.cpu_us += us
	cur.cpu_samples += 1
	cur.cpu_max = maxi(cur.cpu_max, us)


func relevance(checks: int, cells: int) -> void:
	if cur != null and enabled:
		cur.relevance_checks += checks
		cur.cells_visited += cells


## Сводка фазы для JSON/отчёта. КБ = 1024 байта; скорости — на всех клиентов и на одного клиента.
func summary(phase_name: String, n_clients: int) -> Dictionary:
	var p: Phase = phases.get(phase_name)
	if p == null:
		return {}
	var secs := maxf(float(p.ticks) / float(ReplDefs.WORLD_HZ), 0.001)
	var per_class := {}
	for cls in ReplDefs.NUM_CLASSES:
		var c: Dictionary = p.per_class.get(cls, {"entries": 0, "bytes": 0})
		per_class[ReplDefs.CLASS_KEYS[cls]] = {
			"entries": c["entries"], "bytes": c["bytes"],
			"entries_per_s": float(c["entries"]) / secs, "kb_s": float(c["bytes"]) / 1024.0 / secs,
		}
	var heavy: Array = []
	for id in p.per_actor.keys():
		var a: Dictionary = p.per_actor[id]
		heavy.append({"id": int(id), "cls": ReplDefs.CLASS_KEYS[int(a["cls"])], "bytes": int(a["bytes"]), "entries": int(a["entries"])})
	heavy.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return int(x["bytes"]) > int(y["bytes"]) or (int(x["bytes"]) == int(y["bytes"]) and int(x["id"]) < int(y["id"])))
	var series_kb: Array = []
	for i in p.series.size():
		series_kb.append(float(p.series[i]) / 1024.0)
	var k := maxi(n_clients, 1)
	return {
		"seconds": secs,
		"clients": n_clients,
		"wire_bytes": p.wire_bytes,
		"payload_bytes": p.payload_bytes,
		"overhead_bytes": p.overhead_bytes,
		"kb_s_total": float(p.wire_bytes) / 1024.0 / secs,
		"kb_s_per_client": float(p.wire_bytes) / 1024.0 / secs / float(k),
		"packets": p.packets,
		"packets_per_s_per_client": float(p.packets) / secs / float(k),
		"entries": p.entries,
		"entries_per_s_per_client": float(p.entries) / secs / float(k),
		"fields": p.fields,
		"avg_bytes_per_entry": float(p.payload_bytes) / float(maxi(p.entries, 1)),
		"per_class": per_class,
		"per_kind": p.per_kind.duplicate(true),
		"reliable_ops": p.reliable_ops.duplicate(),
		"heavy_actors": heavy.slice(0, 10),
		"known_avg": float(p.known_sum) / float(maxi(p.known_samples, 1)),
		"known_max": p.known_max,
		"peak_100ms_kb_s_total": float(p.win_peak) / 1024.0 / 0.1,
		"cpu_us_avg_per_client_nettick": float(p.cpu_us) / float(maxi(p.cpu_samples, 1)),
		"cpu_us_max": p.cpu_max,
		"relevance_checks": p.relevance_checks,
		"cells_visited": p.cells_visited,
		"series_kb": series_kb,
	}
