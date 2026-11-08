class_name NetNode
extends RefCounted
## Сеансовый слой вашего протокола (ПР №2-3), общий для хоста и клиента.
##  * заголовок/пакеты — Proto; канал датаграмм — Link (UDP или память);
##  * requiresAck-пакеты: получатель отвечает ACK и отбрасывает дубликаты (DedupWindow);
##    отправитель повторяет по таймауту (ReliableChannel + AdaptiveTimeout, Karn: RTT только с пакетов
##    без повторов) и после MAX_ATTEMPTS объявляет доставку проваленной;
##  * keepalive: Ping 4 раза в секунду каждому собеседнику -> Pong -> RTT/джиттер/потери; молчание 3 с = обрыв;
##  * статистика для net_graph: stats(peer).
## Нумерация seq — общий счётчик на собеседника (кроме ACK: seq ACK = подтверждаемый seq), 16 бит с переходом через 65535.

signal peer_added(peer_id: int)
signal peer_lost(peer_id: int, reason: String)
signal message(peer_id: int, msg: Dictionary)
signal reliable_failed(peer_id: int, seq: int)

const PING_INTERVAL_US := 250_000
const MAX_ATTEMPTS := 6
const RTT_WINDOW := 120
const PING_LOSS_WINDOW := 40
const RX_WINDOW := 128

var link: Link
var peers := {}                     # id -> Peer
var timeout_us := 3_000_000          # молчание дольше этого = обрыв
var accept_new_peers := false       # хост: новый собеседник создаётся только по Hello
var bad_packets := 0
var unknown_peer_drops := 0


class Peer extends RefCounted:
	var id: int
	var next_seq := 1
	var channel := ReliableChannel.new(6)
	var rto := AdaptiveTimeout.new()
	var dedup := DedupWindow.new(1024)
	var last_rx_us := 0
	var last_ping_us := 0
	var pending_pings := {}         # seq -> sent_us
	var ping_hist: Array[bool] = [] # true = ответ получен
	var pings_sent := 0
	var pongs_recv := 0
	var rtt_hist: Array[float] = []
	var rtt_last := 0.0
	var jitter := 0.0
	var bytes_in := RateMeter.new()
	var bytes_out := RateMeter.new()
	var pkts_in := RateMeter.new()
	var pkts_out := RateMeter.new()
	var bytes_out_total := 0         # накопительно (ПР №5: профилировщик репликации), с учётом +28 байт IP/UDP
	var pkts_out_total := 0
	var bytes_in_total := 0
	var retransmits := 0
	var acks_ok := 0
	var ack_time_sum_us := 0
	var failed_count := 0
	var dup_dropped := 0
	var rx_high := -1
	var rx_seen := {}
	var rx_total := 0

	func note_rx_seq(seq: int) -> void:
		rx_total += 1
		if rx_high < 0:
			rx_high = seq
			rx_seen[seq] = true
			return
		var d := (seq - rx_high) & 0xFFFF
		if d >= 1 and d < 32768:        # новее
			rx_high = seq
			rx_seen[seq] = true
			for k in rx_seen.keys():
				if ((rx_high - k) & 0xFFFF) >= 128:
					rx_seen.erase(k)
		elif ((rx_high - seq) & 0xFFFF) < 128:   # поздний (переставленный) в пределах окна
			rx_seen[seq] = true

	## Потери входящего потока в процентах за последние ~128 номеров (оценка по разрывам seq).
	func rx_loss_pct() -> float:
		if rx_high < 0 or rx_total < 8:
			return 0.0
		var span := mini(rx_total, 128)
		var got := 0
		for k in rx_seen:
			if ((rx_high - k) & 0xFFFF) < span:
				got += 1
		return clampf(100.0 * float(span - got) / float(span), 0.0, 100.0)

	func add_rtt(ms: float) -> void:
		var d := absf(ms - rtt_last)
		if not rtt_hist.is_empty():
			jitter += (d - jitter) / 16.0     # как в RFC 3550
		rtt_last = ms
		rtt_hist.append(ms)
		if rtt_hist.size() > 120:
			rtt_hist.pop_front()


func _init(l: Link) -> void:
	link = l


func add_peer(id: int) -> Peer:
	var p := Peer.new()
	p.id = id
	p.last_rx_us = link.now_us()
	p.last_ping_us = p.last_rx_us
	peers[id] = p
	peer_added.emit(id)
	return p


func remove_peer(id: int, reason: String = "") -> void:
	if not peers.has(id):
		return
	peers.erase(id)
	if link.has_method("forget_peer"):
		link.call("forget_peer", id)
	peer_lost.emit(id, reason)


## Отправка. builder(seq) -> PackedByteArray (например func(s): return Proto.hello(s, ...)).
## reliable=true ставит пакет в ReliableChannel (в заголовке requiresAck должен быть 1 — так у надёжных типов).
func send(peer_id: int, builder: Callable, reliable: bool) -> int:
	if not peers.has(peer_id):
		return -1
	var p: Peer = peers[peer_id]
	var seq := p.next_seq
	p.next_seq = (p.next_seq + 1) & 0xFFFF
	var raw: PackedByteArray = builder.call(seq)
	if reliable:
		p.channel.on_sent(seq, raw, link.now_us())
	_transmit(p, raw)
	return seq


func broadcast(builder: Callable, reliable: bool) -> void:
	for id in peers.keys():
		send(id, builder, reliable)


func _transmit(p: Peer, raw: PackedByteArray) -> void:
	var now := link.now_us()
	p.bytes_out.add(raw.size() + 28, now)   # +28: IPv4 + UDP заголовки
	p.pkts_out.add(1, now)
	p.bytes_out_total += raw.size() + 28
	p.pkts_out_total += 1
	link.send(p.id, raw)


## Вызывать часто (каждый тик симуляции и каждый кадр): приём, ACK, повторы, keepalive, таймауты.
func process() -> void:
	var now := link.now_us()
	for d in link.poll():
		_on_datagram(int(d["peer"]), d["data"], now)
	for p in peers.values():
		_retransmit(p, now)
		_keepalive(p, now)
	for id in peers.keys():
		var p: Peer = peers[id]
		if now - p.last_rx_us > timeout_us:
			remove_peer(id, "timeout")


func _on_datagram(peer_id: int, data: PackedByteArray, now: int) -> void:
	var msg := Proto.parse(data)
	if msg.is_empty():
		bad_packets += 1
		return
	if not peers.has(peer_id):
		if accept_new_peers and msg["type"] == Proto.T_HELLO:
			add_peer(peer_id)
		else:
			unknown_peer_drops += 1
			return
	var p: Peer = peers[peer_id]
	p.last_rx_us = now
	p.bytes_in.add(data.size() + 28, now)
	p.pkts_in.add(1, now)
	p.bytes_in_total += data.size() + 28
	var t: int = msg["type"]
	if t == Proto.T_ACK:
		var info := p.channel.on_ack(int(msg["acked"]), now)
		if not info.is_empty():
			p.acks_ok += 1
			p.ack_time_sum_us += int(info["time_to_ack_us"])
			if int(info["attempts"]) == 1:   # Karn: RTT только с пакетов без повторов
				p.rto.on_sample(float(info["time_to_ack_us"]) / 1000.0)
		return
	var seq: int = msg["seq"]
	if msg["requires_ack"]:
		_transmit(p, Proto.ack(seq, seq))     # ACK шлём всегда, в т. ч. на дубликат
		if not p.dedup.mark_processed(seq):
			p.dup_dropped += 1
			return
	p.note_rx_seq(seq)
	if t == Proto.T_PING:
		var t_client: int = msg["t_client"]
		send(peer_id, func(s: int) -> PackedByteArray: return Proto.pong(s, t_client, now, now), false)
		return
	if t == Proto.T_PONG:
		var rtt_us := now - int(msg["t_client"])
		if rtt_us >= 0 and rtt_us < 60_000_000:
			var ms := float(rtt_us) / 1000.0
			p.add_rtt(ms)
			p.rto.on_sample(ms)
			p.pongs_recv += 1
			# Ответ засчитываем самому раннему неотвеченному пингу этого времени отправки.
			for k in p.pending_pings.keys():
				if int(p.pending_pings[k]) == int(msg["t_client"]):
					p.pending_pings.erase(k)
					p.ping_hist.append(true)
					break
			if p.ping_hist.size() > PING_LOSS_WINDOW:
				p.ping_hist.pop_front()
		return
	message.emit(peer_id, msg)


func _retransmit(p: Peer, now: int) -> void:
	var failed: Array = []
	for item in p.channel.collect_for_retransmission(now, p.rto.rto_us(), failed):
		p.retransmits += 1
		_transmit(p, item["raw"])
	for seq in failed:
		p.failed_count += 1
		reliable_failed.emit(p.id, int(seq))


func _keepalive(p: Peer, now: int) -> void:
	# Пинги без ответа дольше max(1 с, 2*RTO) считаем потерянными.
	var limit := maxi(1_000_000, 2 * p.rto.rto_us())
	for k in p.pending_pings.keys():
		if now - int(p.pending_pings[k]) > limit:
			p.pending_pings.erase(k)
			p.ping_hist.append(false)
			if p.ping_hist.size() > PING_LOSS_WINDOW:
				p.ping_hist.pop_front()
	if now - p.last_ping_us >= PING_INTERVAL_US:
		p.last_ping_us = now
		var seq := send(p.id, func(s: int) -> PackedByteArray: return Proto.ping(s, now), false)
		p.pending_pings[seq] = now
		p.pings_sent += 1


## Полная статистика собеседника (для net_graph и тестов). Время/скорости считаются на момент now.
func stats(peer_id: int) -> Dictionary:
	if not peers.has(peer_id):
		return {}
	var p: Peer = peers[peer_id]
	var now := link.now_us()
	var mn := 0.0
	var mx := 0.0
	var avg := 0.0
	if not p.rtt_hist.is_empty():
		mn = p.rtt_hist.min()
		mx = p.rtt_hist.max()
		for v in p.rtt_hist:
			avg += v
		avg /= p.rtt_hist.size()
	var lost := 0
	for ok in p.ping_hist:
		if not ok:
			lost += 1
	return {
		"rtt_last": p.rtt_last, "rtt_min": mn, "rtt_max": mx, "rtt_avg": avg,
		"srtt": p.rto.srtt_ms, "rttvar": p.rto.rttvar_ms, "rto": p.rto.rto_ms(),
		"jitter": p.jitter,
		"ping_loss_pct": 100.0 * float(lost) / float(maxi(p.ping_hist.size(), 1)),
		"rx_loss_pct": p.rx_loss_pct(),
		"bytes_in_s": p.bytes_in.per_sec(now), "bytes_out_s": p.bytes_out.per_sec(now),
		"pkts_in_s": p.pkts_in.per_sec(now), "pkts_out_s": p.pkts_out.per_sec(now),
		"reliable_pending": p.channel.pending_count(), "retransmits": p.retransmits,
		"reliable_failed": p.failed_count, "dup_dropped": p.dup_dropped,
		"ack_avg_ms": (float(p.ack_time_sum_us) / 1000.0 / float(p.acks_ok)) if p.acks_ok > 0 else 0.0,
		"since_rx_ms": float(now - p.last_rx_us) / 1000.0,
		"rtt_hist": p.rtt_hist.duplicate(),
	}
