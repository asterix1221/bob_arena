class_name SecureSession
extends RefCounted
## Сессия шифрования одного собеседника (порт crypto/secure_channel.{h,cpp}; байты пакетов совпадают с C++, это проверяют golden-векторы).
## Обмен ключами: X25519 (эфемерные пары) -> HKDF-SHA256 (info "game-udp-v1") -> ключ AES-256-GCM, один на сессию.
## Пакет ENCRYPTED: [заголовок 8 Б, открыт, = AAD][nonce 12][шифртекст = тип внутр. пакета + его payload][tag 16].
## nonce = 4 нулевых байта + счётчик (u64 big-endian); старший бит счётчика — направление (0 клиент->хост, 1 хост->клиент).
## Счётчик растёт на КАЖДУЮ отправку, включая повторную передачу: повтор уходит с новым nonce, а получатель дедуплицирует его по seq.

enum {OK, MALFORMED, WRONG_DIRECTION, REPLAY, AUTH_FAIL}
const NAMES := ["OK", "MALFORMED", "WRONG_DIRECTION", "REPLAY", "AUTH_FAIL"]
const KEY_INFO := "game-udp-v1"
const OVERHEAD := 12 + 1 + 16
const REPLAY_WINDOW := 1024

var gcm: AesGcm
var is_server := false
var send_counter := 0
var replay := ReplayRing.new(REPLAY_WINDOW)
var sealed_count := 0
var opened_count := 0
var auth_fail := 0
var replay_drops := 0
var malformed := 0


## Окно приёма (защита от повтора): как ReplayWindow в C++. Счётчик принимается, если он новее всех виденных
## либо ещё не встречался и не старше окна (UDP переставляет пакеты). Запись — только после успешной проверки тега.
class ReplayRing extends RefCounted:
	var ring := PackedInt64Array()
	var highest := 0
	var any := false

	func _init(size: int = 1024) -> void:
		ring.resize(maxi(size, 1))
		ring.fill(-1)

	func would_accept(c: int) -> bool:
		if not any or c > highest:
			return true
		if highest - c >= ring.size():
			return false
		return ring[c % ring.size()] != c

	func commit(c: int) -> void:
		if not any or c > highest:
			highest = c
			any = true
		ring[c % ring.size()] = c


func _init(key: PackedByteArray, server: bool) -> void:
	gcm = AesGcm.new(key)
	is_server = server


## Закрытый ключ X25519: 32 случайных байта из криптостойкого генератора (Crypto, mbedTLS).
static func generate_private() -> PackedByteArray:
	return Crypto.new().generate_random_bytes(32)


## Ключ сессии из своего закрытого и чужого открытого ключей; пустой массив, если чужой ключ недопустим (малый порядок).
static func derive_key(priv: PackedByteArray, peer_pub: PackedByteArray) -> PackedByteArray:
	var s := X25519.shared(priv, peer_pub)
	if s.is_empty():
		return PackedByteArray()
	return Hkdf.derive(s, KEY_INFO.to_utf8_buffer(), 32)


static func _nonce(counter: int, from_server: bool) -> PackedByteArray:
	var n := PackedByteArray()
	n.resize(12)
	for i in 8:
		n[4 + i] = (counter >> (56 - 8 * i)) & 0xFF
	if from_server:
		n[4] |= 0x80
	return n


## Внутренний пакет (любой Proto.*) -> ENCRYPTED. Пустой массив, если пакет некорректен либо это handshake/ENCRYPTED.
func seal(inner: PackedByteArray) -> PackedByteArray:
	var h := Proto.read_header(inner)
	if h.is_empty() or inner.size() != Proto.HEADER_SIZE + int(h["payload_size"]):
		return PackedByteArray()
	var t: int = h["type"]
	if t == Proto.T_KEY_EXCHANGE or t == Proto.T_ENCRYPTED:
		return PackedByteArray()
	var plain := PackedByteArray()
	plain.append(t)
	plain.append_array(inner.slice(Proto.HEADER_SIZE))
	var sealed_size := 12 + plain.size() + 16
	if sealed_size > 0xFFFF:
		return PackedByteArray()
	var header := Proto.encrypted_header(int(h["seq"]), bool(h["requires_ack"]), sealed_size)
	send_counter += 1
	var nonce := _nonce(send_counter, is_server)
	var out := header.duplicate()
	out.append_array(nonce)
	out.append_array(gcm.seal(nonce, header, plain))
	sealed_count += 1
	return out


## ENCRYPTED -> {"result": OK|..., "inner": восстановленный внутренний пакет (только при OK)}.
func open(data: PackedByteArray) -> Dictionary:
	var h := Proto.check_encrypted(data)
	if h.is_empty():
		malformed += 1
		return {"result": MALFORMED}
	var nonce := data.slice(Proto.HEADER_SIZE, Proto.HEADER_SIZE + 12)
	if nonce[0] != 0 or nonce[1] != 0 or nonce[2] != 0 or nonce[3] != 0:
		malformed += 1
		return {"result": MALFORMED}
	var from_server := (nonce[4] & 0x80) != 0
	if from_server == is_server:       # пакет должен идти В нашу сторону (иначе это эхо наших же пакетов)
		malformed += 1
		return {"result": WRONG_DIRECTION}
	var counter := nonce[4] & 0x7F
	for i in range(5, 12):
		counter = (counter << 8) | nonce[i]
	if not replay.would_accept(counter):
		replay_drops += 1
		return {"result": REPLAY}
	var aad := data.slice(0, Proto.HEADER_SIZE)
	var plain: Variant = gcm.open(nonce, aad, data.slice(Proto.HEADER_SIZE + 12))
	if plain == null:
		auth_fail += 1
		return {"result": AUTH_FAIL}
	replay.commit(counter)             # записываем только после успешной проверки тега
	var p: PackedByteArray = plain
	if p.is_empty():
		malformed += 1
		return {"result": MALFORMED}
	var inner := PackedByteArray()
	Wire.w_u8(inner, p[0])
	Wire.w_u16(inner, int(h["seq"]))
	Wire.w_u16(inner, p.size() - 1)
	Wire.w_u16(inner, Proto.VERSION)
	Wire.w_u8(inner, 1 if h["requires_ack"] else 0)
	inner.append_array(p.slice(1))
	var ih := Proto.read_header(inner)
	if ih.is_empty() or int(ih["type"]) == Proto.T_KEY_EXCHANGE or int(ih["type"]) == Proto.T_ENCRYPTED:
		malformed += 1
		return {"result": MALFORMED}
	opened_count += 1
	return {"result": OK, "inner": inner}
