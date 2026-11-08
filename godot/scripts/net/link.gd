class_name Link
extends RefCounted
## Базовый «канал датаграмм» под протоколом. Две реализации: UdpLink (PacketPeerUDP) и LoopLink
## (память + виртуальное время для тестов). Эмуляция сети — здесь, на уровне датаграмм:
## задержка, джиттер (равномерно +-jitter, возможна перестановка пакетов) и потери исходящего трафика.
## Включив эмуляцию на обеих сторонах, получаем RTT ~ lag(A) + lag(B) и потери в обе стороны.

var lag_ms := 0.0
var jitter_ms := 0.0
var loss := 0.0                  # 0..1
var rng := RandomNumberGenerator.new()

var sent_packets := 0
var sent_bytes := 0
var dropped_by_emu := 0

var _delayed: Array = []         # [[due_us, peer, data], ...]


func _init(seed_value: int = 1) -> void:
	rng.seed = seed_value


func now_us() -> int:
	return Time.get_ticks_usec()


func set_emulation(lag: float, jitter: float, loss_fraction: float) -> void:
	lag_ms = lag
	jitter_ms = jitter
	loss = loss_fraction


## Отправка с учётом эмуляции. peer — идентификатор собеседника на этом канале.
func send(peer: int, data: PackedByteArray) -> void:
	sent_packets += 1
	sent_bytes += data.size()
	if loss > 0.0 and rng.randf() < loss:
		dropped_by_emu += 1
		return
	if lag_ms <= 0.0 and jitter_ms <= 0.0:
		_raw_send(peer, data)
		return
	var delay_ms := maxf(lag_ms + rng.randf_range(-jitter_ms, jitter_ms), 0.0)
	_delayed.append([now_us() + int(delay_ms * 1000.0), peer, data])


## Выпускает созревшие отложенные пакеты (в порядке срока), затем возвращает принятые:
## [{peer, data}, ...].
func poll() -> Array:
	if not _delayed.is_empty():
		var now := now_us()
		var rest: Array = []
		var due: Array = []
		for item in _delayed:
			if item[0] <= now:
				due.append(item)
			else:
				rest.append(item)
		_delayed = rest
		due.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		for item in due:
			_raw_send(item[1], item[2])
	return _raw_poll()


func close() -> void:
	_delayed.clear()


# Реализуются наследниками.
func _raw_send(_peer: int, _data: PackedByteArray) -> void:
	pass


func _raw_poll() -> Array:
	return []
