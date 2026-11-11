class_name X25519
extends RefCounted
## X25519 (RFC 7748) на чистом GDScript: в Godot нет ни эллиптических кривых Curve25519, ни AES-GCM (есть только AES-ECB/CBC, RSA и HMAC),
## поэтому алгоритм перенесён из TweetNaCl (D. J. Bernstein et al.): поле GF(2^255 - 19), 16 «ножек» по 16 бит в int64,
## лестница Монтгомери, без ветвлений по секрету (выбор sel25519 через маску). Корректность проверяется векторами RFC 7748
## и байтами, которые выдаёт OpenSSL в C++-части (godot/tests/run_crypto_tests.gd).
##   public_key(priv)       — открытый ключ (32 байта) = priv * G
##   shared(priv, peer_pub) — общий секрет (32 байта); пустой массив, если результат нулевой (точка малого порядка)

const _121665 := [0xDB41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]


static func _car(o: PackedInt64Array) -> void:
	for i in 16:
		o[i] += 65536
		var c := o[i] >> 16
		if i < 15:
			o[i + 1] += c - 1
		else:
			o[0] += c - 1 + 37 * (c - 1)
		o[i] -= c << 16


static func _sel(p: PackedInt64Array, q: PackedInt64Array, b: int) -> void:
	var c := ~(b - 1)
	for i in 16:
		var t := c & (p[i] ^ q[i])
		p[i] ^= t
		q[i] ^= t


static func _pack(n: PackedInt64Array) -> PackedByteArray:
	var t := n.duplicate()
	_car(t)
	_car(t)
	_car(t)
	var m := PackedInt64Array()
	m.resize(16)
	for _j in 2:
		m[0] = t[0] - 0xffed
		for i in range(1, 15):
			m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
			m[i - 1] &= 0xffff
		m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
		var b := (m[15] >> 16) & 1
		m[14] &= 0xffff
		_sel(t, m, 1 - b)
	var o := PackedByteArray()
	o.resize(32)
	for i in 16:
		o[2 * i] = t[i] & 0xff
		o[2 * i + 1] = (t[i] >> 8) & 0xff
	return o


static func _unpack(n: PackedByteArray) -> PackedInt64Array:
	var o := PackedInt64Array()
	o.resize(16)
	for i in 16:
		o[i] = n[2 * i] + (n[2 * i + 1] << 8)
	o[15] &= 0x7fff
	return o


static func _mul(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var t := PackedInt64Array()
	t.resize(31)
	for i in 16:
		var ai := a[i]
		for j in 16:
			t[i + j] += ai * b[j]
	for i in 15:
		t[i] += 38 * t[i + 16]
	var o := PackedInt64Array()
	o.resize(16)
	for i in 16:
		o[i] = t[i]
	_car(o)
	_car(o)
	return o


static func _add(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var o := PackedInt64Array()
	o.resize(16)
	for i in 16:
		o[i] = a[i] + b[i]
	return o


static func _sub(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var o := PackedInt64Array()
	o.resize(16)
	for i in 16:
		o[i] = a[i] - b[i]
	return o


static func _inv(i: PackedInt64Array) -> PackedInt64Array:
	var c := i.duplicate()
	for a in range(253, -1, -1):
		c = _mul(c, c)
		if a != 2 and a != 4:
			c = _mul(c, i)
	return c


## n — закрытый ключ (32 байта, «зажим» делается здесь), p — u-координата точки (32 байта). Возвращает 32 байта.
static func scalarmult(n: PackedByteArray, p: PackedByteArray) -> PackedByteArray:
	var z := n.duplicate()
	z[31] = (n[31] & 127) | 64
	z[0] &= 248
	var x := _unpack(p)
	var a := PackedInt64Array()
	a.resize(16)
	var b := x.duplicate()
	var c := PackedInt64Array()
	c.resize(16)
	var d := PackedInt64Array()
	d.resize(16)
	a[0] = 1
	d[0] = 1
	var k121665 := PackedInt64Array(_121665)
	for i in range(254, -1, -1):
		var r := (z[i >> 3] >> (i & 7)) & 1
		_sel(a, b, r)
		_sel(c, d, r)
		var e := _add(a, c)
		a = _sub(a, c)
		c = _add(b, d)
		b = _sub(b, d)
		d = _mul(e, e)
		var f := _mul(a, a)
		a = _mul(c, a)
		c = _mul(b, e)
		e = _add(a, c)
		a = _sub(a, c)
		b = _mul(a, a)
		c = _sub(d, f)
		a = _mul(c, k121665)
		a = _add(a, d)
		c = _mul(c, a)
		a = _mul(d, f)
		d = _mul(b, x)
		b = _mul(e, e)
		_sel(a, b, r)
		_sel(c, d, r)
	var inv := _inv(c)
	return _pack(_mul(a, inv))


static func public_key(priv: PackedByteArray) -> PackedByteArray:
	var base := PackedByteArray()
	base.resize(32)
	base[0] = 9
	return scalarmult(priv, base)


static func shared(priv: PackedByteArray, peer_pub: PackedByteArray) -> PackedByteArray:
	if priv.size() != 32 or peer_pub.size() != 32:
		return PackedByteArray()
	var s := scalarmult(priv, peer_pub)
	var acc := 0
	for v in s:
		acc |= v
	if acc == 0:
		return PackedByteArray()      # точка малого порядка: такой «открытый ключ» присылает только атакующий
	return s
