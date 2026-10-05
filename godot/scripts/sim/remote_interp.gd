class_name RemoteInterp
extends RefCounted
## Простая интерполяция чужих персонажей по серверным снимкам (аналог Simulated Proxy + smoothing):
## рисуем с небольшим отставанием, чтобы всегда было между чем интерполировать.

const TICK_MS := 1000.0 / 60.0
const BUFFER_MAX := 40

var buf: Array = []         # {"tick": float, "pos": Vector2, "dash": bool}
var newest_arrival_ms := 0.0
var dashing := false


func push(tick: int, pos: Vector2, dash: bool, now_ms: float) -> void:
	if not buf.is_empty() and tick <= buf.back()["tick"]:
		return
	buf.append({"tick": float(tick), "pos": pos, "dash": dash})
	if buf.size() > BUFFER_MAX:
		buf.pop_front()
	newest_arrival_ms = now_ms


func sample(now_ms: float, delay_ticks: float = 6.0) -> Vector2:
	if buf.is_empty():
		return Vector2.ZERO
	var est: float = buf.back()["tick"] + (now_ms - newest_arrival_ms) / TICK_MS
	var rt := est - delay_ticks
	dashing = buf.back()["dash"]
	if buf.size() == 1 or rt <= buf[0]["tick"]:
		return buf[0]["pos"]
	for i in range(buf.size() - 1):
		var a: Dictionary = buf[i]
		var b: Dictionary = buf[i + 1]
		if rt <= b["tick"]:
			var t: float = (rt - a["tick"]) / maxf(0.0001, b["tick"] - a["tick"])
			return a["pos"].lerp(b["pos"], clampf(t, 0.0, 1.0))
	return buf.back()["pos"]
