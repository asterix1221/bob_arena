class_name LoopHub
extends RefCounted
## Виртуальная «сеть» в памяти для тестов: общее время и почтовые ящики каналов.
## Время двигает тест: hub.advance_us(...). Никаких сокетов и реальных часов.

var now_us := 0
var _boxes := {}   # link_id -> Array[{peer, data}]
var _next_id := 1


func advance_us(dt: int) -> void:
	now_us += dt


func register() -> int:
	var id := _next_id
	_next_id += 1
	_boxes[id] = []
	return id


func deliver(to_link: int, from_link: int, data: PackedByteArray) -> void:
	if _boxes.has(to_link):
		_boxes[to_link].append({"peer": from_link, "data": data})


func take(link_id: int) -> Array:
	var out: Array = _boxes[link_id]
	_boxes[link_id] = []
	return out
