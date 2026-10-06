class_name UdpLink
extends Link
## Реальный UDP на PacketPeerUDP. Режимы:
##   listen(port)          — хост: принимает от любых адресов, каждому новому адресу даёт peer-id 1, 2, 3...
##   connect_to(ip, port)  — клиент: единственный собеседник — хост, peer-id = 1.
## Адрес собеседника хранится по строке "ip:port". Потеря/дубликаты/перестановка — обычное поведение UDP.

var _sock := PacketPeerUDP.new()
var _peer_by_addr := {}      # "ip:port" -> peer id
var _addr_by_peer := {}      # peer id -> [ip, port]
var _next_peer := 1
var is_open := false


func listen(port: int) -> Error:
	var err := _sock.bind(port, "*")
	is_open = err == OK
	return err


func connect_to(ip: String, port: int) -> Error:
	# bind на случайный порт, адрес хоста запоминаем сами (connect у PacketPeerUDP нужен не всегда).
	var err := _sock.bind(0, "*")
	if err != OK:
		return err
	_peer_by_addr["%s:%d" % [ip, port]] = 1
	_addr_by_peer[1] = [ip, port]
	_next_peer = 2
	is_open = true
	return OK


func _raw_send(peer: int, data: PackedByteArray) -> void:
	if not is_open or not _addr_by_peer.has(peer):
		return
	var a: Array = _addr_by_peer[peer]
	_sock.set_dest_address(a[0], a[1])
	_sock.put_packet(data)


func _raw_poll() -> Array:
	var out: Array = []
	if not is_open:
		return out
	while _sock.get_available_packet_count() > 0:
		var data := _sock.get_packet()
		if _sock.get_packet_error() != OK:
			continue
		var key := "%s:%d" % [_sock.get_packet_ip(), _sock.get_packet_port()]
		if not _peer_by_addr.has(key):
			_peer_by_addr[key] = _next_peer
			_addr_by_peer[_next_peer] = [_sock.get_packet_ip(), _sock.get_packet_port()]
			_next_peer += 1
		out.append({"peer": _peer_by_addr[key], "data": data})
	return out


func forget_peer(peer: int) -> void:
	## После отключения: адрес освобождается, чтобы новый вход получил новый id.
	if _addr_by_peer.has(peer):
		var a: Array = _addr_by_peer[peer]
		_peer_by_addr.erase("%s:%d" % [a[0], a[1]])
		_addr_by_peer.erase(peer)


func close() -> void:
	super()
	_sock.close()
	is_open = false
