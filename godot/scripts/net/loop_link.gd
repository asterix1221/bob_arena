class_name LoopLink
extends Link
## Канал в памяти поверх LoopHub. peer = id канала собеседника (link_id).

var hub: LoopHub
var link_id: int


func _init(h: LoopHub, seed_value: int = 1) -> void:
	super(seed_value)
	hub = h
	link_id = h.register()


func now_us() -> int:
	return hub.now_us


func _raw_send(peer: int, data: PackedByteArray) -> void:
	hub.deliver(peer, link_id, data)


func _raw_poll() -> Array:
	return hub.take(link_id)
