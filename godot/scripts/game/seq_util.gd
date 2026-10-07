class_name SeqUtil
extends RefCounted
## Арифметика 16-битных счётчиков (номера тиков и команд переполняются каждые ~9 минут при 120 Гц).


## Разворачивает 16-битное значение v в целое, ближайшее к ref (ref — «развёрнутое» значение рядом).
static func unwrap16(v: int, ref: int) -> int:
	return ref + (((v - ref + 32768) & 0xFFFF) - 32768)


## true, если a новее b (на полуокружности 0..32767).
static func newer(a: int, b: int) -> bool:
	var d := (a - b) & 0xFFFF
	return d >= 1 and d < 32768
