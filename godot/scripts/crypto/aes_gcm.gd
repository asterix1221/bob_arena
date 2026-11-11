class_name AesGcm
extends RefCounted
## AES-256-GCM (NIST SP 800-38D) для nonce 96 бит. В Godot есть только AES в режимах ECB и CBC (AESContext), поэтому GCM собран
## из них: режим счётчика (CTR) = шифрование ECB последовательных блоков-счётчиков, аутентификация — GHASH (умножение в GF(2^128)).
## Формат совпадает с C++ (OpenSSL): seal() возвращает «шифртекст + tag 16», nonce передаётся отдельно (в пакете он идёт перед шифртекстом).
## Один экземпляр = один ключ; подкол H = AES(0) и таблица умножения считаются один раз на сессию.
##   seal(nonce, aad, plain)        -> PackedByteArray (шифртекст || tag)
##   open(nonce, aad, ct_and_tag)   -> PackedByteArray, либо null, если тег не сошёлся (открытый текст при этом не возвращается)

const TAG_SIZE := 16
const _R := 0xE1 << 56          # полином редукции GCM (старшая половина), с переносом в знак — int64 всё равно «кольцо»

var _key: PackedByteArray
var _h_hi := 0
var _h_lo := 0
var _tab_hi := PackedInt64Array()   # 16 значений i*H (i = 4 бита), hi/lo
var _tab_lo := PackedInt64Array()
var _rem := PackedInt64Array()      # редукция при сдвиге на 4 бита (старшие 16 бит hi)


func _init(key: PackedByteArray) -> void:
	assert(key.size() == 32)
	_key = key.duplicate()
	var zero := PackedByteArray()
	zero.resize(16)
	var h := _ecb(zero)
	_h_hi = _be64(h, 0)
	_h_lo = _be64(h, 8)
	_build_table()


func _ecb(blocks: PackedByteArray) -> PackedByteArray:
	var ctx := AESContext.new()
	ctx.start(AESContext.MODE_ECB_ENCRYPT, _key)
	var out := ctx.update(blocks)
	ctx.finish()
	return out


static func _be64(b: PackedByteArray, off: int) -> int:
	var v := 0
	for i in 8:
		v = (v << 8) | b[off + i]
	return v


static func _put64(b: PackedByteArray, off: int, v: int) -> void:
	for i in 8:
		b[off + i] = (v >> (56 - 8 * i)) & 0xFF


## Сдвиг 128-битного (hi, lo) вправо на 1 с редукцией GCM; возвращает [hi, lo].
static func _shr1(hi: int, lo: int) -> Array:
	var carry := lo & 1
	var nlo := ((lo >> 1) & 0x7FFFFFFFFFFFFFFF) | ((hi & 1) << 63)
	var nhi := (hi >> 1) & 0x7FFFFFFFFFFFFFFF
	if carry == 1:
		nhi ^= _R
	return [nhi, nlo]


func _build_table() -> void:
	# Таблица Шоупа (4 бита): T[8] = H, T[4] = H*x^-1 ..., остальные — XOR. Индекс = значение полубайта в «зеркальном» порядке GCM.
	_tab_hi.resize(16)
	_tab_lo.resize(16)
	_tab_hi[8] = _h_hi
	_tab_lo[8] = _h_lo
	var i := 4
	while i > 0:
		var s := _shr1(_tab_hi[i * 2], _tab_lo[i * 2])
		_tab_hi[i] = s[0]
		_tab_lo[i] = s[1]
		i >>= 1
	i = 2
	while i < 16:
		for j in range(1, i):
			_tab_hi[i + j] = _tab_hi[i] ^ _tab_hi[j]
			_tab_lo[i + j] = _tab_lo[i] ^ _tab_lo[j]
		i <<= 1
	# last4[k]: что добавляется к hi при выдвижении 4 младших бит (редукция), значение для старших 16 бит
	_rem = PackedInt64Array([
		0x0000, 0x1c20, 0x3840, 0x2460, 0x7080, 0x6ca0, 0x48c0, 0x54e0,
		0xe100, 0xfd20, 0xd940, 0xc560, 0x9180, 0x8da0, 0xa9c0, 0xb5e0])


## Умножение (hi, lo) на H в GF(2^128). Возвращает [hi, lo].
func _gmul(hi: int, lo: int) -> Array:
	var zh := 0
	var zl := 0
	var first := true
	for k in 32:       # 32 полубайта, с младшего (последний байт, младшая половина) к старшему
		var byte_index := 15 - (k >> 1)
		var b := (lo >> ((15 - byte_index) * 8)) & 0xFF if byte_index >= 8 else (hi >> ((7 - byte_index) * 8)) & 0xFF
		var nib := (b & 0x0F) if (k & 1) == 0 else (b >> 4)
		if not first:
			var rem := zl & 0x0F
			zl = ((zl >> 4) & 0x0FFFFFFFFFFFFFFF) | ((zh & 0x0F) << 60)
			zh = ((zh >> 4) & 0x0FFFFFFFFFFFFFFF) ^ (_rem[rem] << 48)
		first = false
		zh ^= _tab_hi[nib]
		zl ^= _tab_lo[nib]
	return [zh, zl]


func _ghash(aad: PackedByteArray, ct: PackedByteArray) -> PackedByteArray:
	var yh := 0
	var yl := 0
	for data in [aad, ct]:
		var d: PackedByteArray = data
		var n := d.size()
		var pos := 0
		while pos < n:
			var blk := d.slice(pos, mini(pos + 16, n))
			blk.resize(16)
			yh ^= _be64(blk, 0)
			yl ^= _be64(blk, 8)
			var r := _gmul(yh, yl)
			yh = r[0]
			yl = r[1]
			pos += 16
	yh ^= aad.size() * 8
	yl ^= ct.size() * 8
	var r2 := _gmul(yh, yl)
	var out := PackedByteArray()
	out.resize(16)
	_put64(out, 0, r2[0])
	_put64(out, 8, r2[1])
	return out


## Блоки-счётчики J0, J0+1, ...: nonce (12 байт) || счётчик u32 big-endian. Возвращает keystream (E(J0) первым блоком).
func _keystream(nonce: PackedByteArray, blocks: int) -> PackedByteArray:
	var ctrs := PackedByteArray()
	ctrs.resize(16 * (blocks + 1))
	for i in blocks + 1:
		for j in 12:
			ctrs[16 * i + j] = nonce[j]
		var c := i + 1            # J0 = nonce || 1, дальше 2, 3, ...
		ctrs[16 * i + 12] = (c >> 24) & 0xFF
		ctrs[16 * i + 13] = (c >> 16) & 0xFF
		ctrs[16 * i + 14] = (c >> 8) & 0xFF
		ctrs[16 * i + 15] = c & 0xFF
	return _ecb(ctrs)


func seal(nonce: PackedByteArray, aad: PackedByteArray, plain: PackedByteArray) -> PackedByteArray:
	assert(nonce.size() == 12)
	var n := plain.size()
	var ks := _keystream(nonce, (n + 15) / 16)
	var ct := PackedByteArray()
	ct.resize(n)
	for i in n:
		ct[i] = plain[i] ^ ks[16 + i]
	var s := _ghash(aad, ct)
	for i in 16:
		s[i] ^= ks[i]
	ct.append_array(s)
	return ct


func open(nonce: PackedByteArray, aad: PackedByteArray, ct_and_tag: PackedByteArray) -> Variant:
	if nonce.size() != 12 or ct_and_tag.size() < TAG_SIZE:
		return null
	var n := ct_and_tag.size() - TAG_SIZE
	var ct := ct_and_tag.slice(0, n)
	var ks := _keystream(nonce, (n + 15) / 16)
	var s := _ghash(aad, ct)
	var diff := 0
	for i in 16:
		diff |= (s[i] ^ ks[i]) ^ ct_and_tag[n + i]       # сравнение без раннего выхода
	if diff != 0:
		return null
	var plain := PackedByteArray()
	plain.resize(n)
	for i in n:
		plain[i] = ct[i] ^ ks[16 + i]
	return plain
