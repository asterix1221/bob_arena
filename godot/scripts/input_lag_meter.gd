class_name InputLagMeter
extends RefCounted
## Измеряет программную часть задержки управления на реальных кадрах:
##   «событие → тик»  : от получения события нажатия до тика симуляции, применившего его;
##   «событие → кадр» : до завершения отрисовки кадра, в котором этот тик виден (frame_post_draw).
## НЕ включает задержку ОС до доставки события, монитора и драйвера — их программно не измерить.

const WINDOW := 60

var to_tick_ms: Array[float] = []
var to_draw_ms: Array[float] = []
var _waiting: Array = []        # [t_event, t_tick] — применены в тике, ждут отрисовки


func on_tick(event_times: Array, tick_us: int) -> void:
	for t in event_times:
		_waiting.append([int(t), tick_us])
		_push(to_tick_ms, float(tick_us - int(t)) / 1000.0)


func on_frame_drawn(now_us: int) -> void:
	for w in _waiting:
		_push(to_draw_ms, float(now_us - int(w[0])) / 1000.0)
	_waiting.clear()


func _push(arr: Array[float], v: float) -> void:
	arr.append(v)
	if arr.size() > WINDOW:
		arr.pop_front()


static func _avg(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


func stats() -> Dictionary:
	return {
		"tick_avg": _avg(to_tick_ms), "tick_max": (to_tick_ms.max() if not to_tick_ms.is_empty() else 0.0),
		"draw_avg": _avg(to_draw_ms), "draw_max": (to_draw_ms.max() if not to_draw_ms.is_empty() else 0.0),
		"samples": to_draw_ms.size(),
	}
