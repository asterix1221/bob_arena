class_name DedupWindow
extends RefCounted
## Порт reliability/dedup_window.{hpp,cpp}: окно последних обработанных номеров (FIFO-вытеснение).
## mark_processed(seq) -> true, если пакет новый (его надо обработать), false — дубликат.

var capacity: int
var _order: Array[int] = []
var _seen := {}


func _init(cap: int = 1024) -> void:
	capacity = maxi(cap, 1)


func mark_processed(seq: int) -> bool:
	if _seen.has(seq):
		return false
	if _order.size() >= capacity:
		_seen.erase(_order.pop_front())
	_order.append(seq)
	_seen[seq] = true
	return true


func contains(seq: int) -> bool:
	return _seen.has(seq)


func size() -> int:
	return _order.size()
