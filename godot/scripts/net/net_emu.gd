class_name NetEmu
extends RefCounted
## Встроенная эмуляция сети (как эмуляция сервера в ПР №2–3): задержка в ОДНУ сторону, джиттер,
## потери. Все игровые RPC отправляются через send(); каждая сторона эмулирует свой исходящий
## трафик, поэтому RTT ≈ 2 × lag. Время передаёт вызывающий (в игре — реальное, в тестах — виртуальное).

var lag_ms := 0.0
var jitter_ms := 0.0
var loss_pct := 0.0
var rng := RandomNumberGenerator.new()
var queue: Array = []        # {"t": float, "fn": Callable}, отсортирована по t
var sent := 0
var dropped := 0


func _init(seed_value: int = 1) -> void:
	rng.seed = seed_value


func configure(lag: float, jitter: float, loss: float) -> void:
	lag_ms = lag
	jitter_ms = jitter
	loss_pct = loss


## reliable=true — потери не применяются (как у reliable RPC в ENet, который перепосылает сам).
func send(now_ms: float, fn: Callable, reliable: bool = false) -> void:
	sent += 1
	if not reliable and loss_pct > 0.0 and rng.randf() * 100.0 < loss_pct:
		dropped += 1
		return
	var delay := lag_ms
	if jitter_ms > 0.0:
		delay += rng.randf_range(-jitter_ms, jitter_ms)
	var due := now_ms + maxf(0.0, delay)
	var i := queue.size()
	while i > 0 and queue[i - 1]["t"] > due:
		i -= 1
	queue.insert(i, {"t": due, "fn": fn})


func poll(now_ms: float) -> void:
	while not queue.is_empty() and queue[0]["t"] <= now_ms:
		var item: Dictionary = queue.pop_front()
		item["fn"].call()
