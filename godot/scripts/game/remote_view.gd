class_name RemoteView
extends RefCounted
## Отображение ЧУЖИХ игроков: буфер снимков + интерполяция по серверным тикам (Simulated Proxy).
## Рисуем состояние на render_tick = (оценка серверного тика) - delay; если данных нет — экстраполяция по скорости
## не дольше MAX_EXTRAPOLATE тиков (дальше замираем, чтобы не «улетали»).

const MAX_SAMPLES := 64
const MAX_EXTRAPOLATE := 12

var delay_ticks := 8                 # ~67 мс при 120 Гц (2 снимка + запас на джиттер)
var samples := {}                    # id -> Array[{t, x, y, vx, vy, flags, hp, buffs}] (t — «развёрнутый» серверный тик)
var underruns := 0                   # сколько раз пришлось экстраполировать (нехватка снимков)
var last_mode := "none"


func add(id: int, t: int, x_px: float, y_px: float, vx_px_tick: float, vy_px_tick: float, flags: int, hp: int, buffs: int) -> void:
	if not samples.has(id):
		samples[id] = []
	var arr: Array = samples[id]
	if not arr.is_empty() and arr.back()["t"] >= t:
		return                       # старый или повторный снимок
	arr.append({"t": t, "x": x_px, "y": y_px, "vx": vx_px_tick, "vy": vy_px_tick, "flags": flags, "hp": hp, "buffs": buffs})
	if arr.size() > MAX_SAMPLES:
		arr.pop_front()


func forget(id: int) -> void:
	samples.erase(id)


func clear() -> void:
	samples.clear()


## Состояние игрока id на тике render_t (float). {} если снимков нет.
func sample(id: int, render_t: float) -> Dictionary:
	if not samples.has(id) or samples[id].is_empty():
		return {}
	var arr: Array = samples[id]
	if render_t <= arr[0]["t"]:
		last_mode = "first"
		return arr[0].duplicate()
	for i in range(arr.size() - 1, 0, -1):
		var b: Dictionary = arr[i]
		var a: Dictionary = arr[i - 1]
		if render_t >= a["t"] and render_t <= b["t"]:
			var k: float = (render_t - a["t"]) / float(b["t"] - a["t"])
			var out := b.duplicate()
			out["x"] = lerpf(a["x"], b["x"], k)
			out["y"] = lerpf(a["y"], b["y"], k)
			last_mode = "interp"
			return out
	var last: Dictionary = arr.back()
	var ahead: float = minf(render_t - last["t"], MAX_EXTRAPOLATE)
	var ex := last.duplicate()
	ex["x"] = last["x"] + last["vx"] * ahead
	ex["y"] = last["y"] + last["vy"] * ahead
	last_mode = "extrap"
	underruns += 1
	return ex
