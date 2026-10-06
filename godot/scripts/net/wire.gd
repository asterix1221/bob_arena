class_name Wire
extends RefCounted
## Примитивы формата протокола: все числа big-endian (как в protocol/protocol.cpp).
## Запись — статические функции над PackedByteArray; чтение — Reader с флагом ok:
## при выходе за границу данных ok становится false и дальше возвращаются нули,
## поэтому разбор мусора никогда не падает, а лишь помечается как невалидный.


static func w_u8(b: PackedByteArray, v: int) -> void:
	b.append(v & 0xFF)


static func w_u16(b: PackedByteArray, v: int) -> void:
	b.append((v >> 8) & 0xFF)
	b.append(v & 0xFF)


static func w_u32(b: PackedByteArray, v: int) -> void:
	for shift in [24, 16, 8, 0]:
		b.append((v >> shift) & 0xFF)


static func w_u64(b: PackedByteArray, v: int) -> void:
	for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
		b.append((v >> shift) & 0xFF)


static func w_i16(b: PackedByteArray, v: int) -> void:
	w_u16(b, v & 0xFFFF)


static func w_i8(b: PackedByteArray, v: int) -> void:
	b.append(v & 0xFF)


class Reader extends RefCounted:
	var data: PackedByteArray
	var pos := 0
	var ok := true

	func _init(d: PackedByteArray, start: int = 0) -> void:
		data = d
		pos = start

	func left() -> int:
		return data.size() - pos

	func u8() -> int:
		if left() < 1:
			ok = false
			return 0
		pos += 1
		return data[pos - 1]

	func u16() -> int:
		if left() < 2:
			ok = false
			return 0
		pos += 2
		return (data[pos - 2] << 8) | data[pos - 1]

	func u32() -> int:
		if left() < 4:
			ok = false
			return 0
		var v := 0
		for i in 4:
			v = (v << 8) | data[pos + i]
		pos += 4
		return v

	func u64() -> int:
		## Значения до 2^63 (микросекунды) помещаются в int GDScript без потерь.
		if left() < 8:
			ok = false
			return 0
		var v := 0
		for i in 8:
			v = (v << 8) | data[pos + i]
		pos += 8
		return v

	func i8() -> int:
		var v := u8()
		return v - 256 if v >= 128 else v

	func i16() -> int:
		var v := u16()
		return v - 65536 if v >= 32768 else v

	func bytes(n: int) -> PackedByteArray:
		if n < 0 or left() < n:
			ok = false
			return PackedByteArray()
		pos += n
		return data.slice(pos - n, pos)
