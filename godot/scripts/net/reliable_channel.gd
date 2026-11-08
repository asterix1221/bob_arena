class_name ReliableChannel
extends RefCounted
## Порт reliability/reliable_channel.{hpp,cpp}: учёт неподтверждённых пакетов отправителя.
## Время — микросекунды (int). Повторы только по таймауту; после max_attempts попыток пакет
## считается проваленным. Доставка НЕ упорядочена: получатель обязан быть идемпотентным.

var max_attempts: int
var _pending := {}      # seq -> {raw, last_sent_us, first_sent_us, attempts}
var failed: Array[int] = []


func _init(attempts: int = 5) -> void:
	max_attempts = attempts


func on_sent(seq: int, raw: PackedByteArray, now_us: int) -> void:
	_pending[seq] = {"raw": raw, "last_sent_us": now_us, "first_sent_us": now_us, "attempts": 1}


## Возвращает {} для неизвестного/дублирующего ACK, иначе {attempts, time_to_ack_us}.
func on_ack(seq: int, now_us: int) -> Dictionary:
	if not _pending.has(seq):
		return {}
	var p: Dictionary = _pending[seq]
	_pending.erase(seq)
	return {"attempts": p["attempts"], "time_to_ack_us": maxi(now_us - int(p["first_sent_us"]), 0)}


## Пакеты, которые пора отправить повторно: [{seq, raw}], в порядке первой отправки.
## Исчерпавшие попытки уходят в failed (и в out_failed, если передан).
func collect_for_retransmission(now_us: int, rto_us: int, out_failed: Array = []) -> Array:
	var due := []
	var exhausted: Array[int] = []
	for seq in _pending:
		var p: Dictionary = _pending[seq]
		if now_us < int(p["last_sent_us"]) or now_us - int(p["last_sent_us"]) < rto_us:
			continue
		if int(p["attempts"]) >= max_attempts:
			exhausted.append(seq)
		else:
			due.append(seq)
	exhausted.sort()
	for seq in exhausted:
		_pending.erase(seq)
		failed.append(seq)
		out_failed.append(seq)
	due.sort_custom(func(a: int, b: int) -> bool:
		var fa: int = _pending[a]["first_sent_us"]
		var fb: int = _pending[b]["first_sent_us"]
		return fa < fb if fa != fb else a < b)
	var result := []
	for seq in due:
		var p: Dictionary = _pending[seq]
		p["attempts"] = int(p["attempts"]) + 1
		p["last_sent_us"] = now_us
		result.append({"seq": seq, "raw": p["raw"]})
	return result


func pending_count() -> int:
	return _pending.size()
