class_name RateMeter
extends RefCounted
## Скользящая скорость за последнюю секунду (10 корзин по 100 мс). add(n, now) — прибавить n,
## per_sec(now) — сумма за последнюю секунду. Время — микросекунды.

const BUCKETS := 10
const BUCKET_US := 100_000

var _b: Array[int] = []
var _idx := 0
var _bucket_start := -1


func _init() -> void:
	_b.resize(BUCKETS)
	_b.fill(0)


func _advance(now_us: int) -> void:
	if _bucket_start < 0:
		_bucket_start = now_us
		return
	var steps := (now_us - _bucket_start) / BUCKET_US
	if steps <= 0:
		return
	for i in mini(steps, BUCKETS):
		_idx = (_idx + 1) % BUCKETS
		_b[_idx] = 0
	_bucket_start += steps * BUCKET_US


func add(n: int, now_us: int) -> void:
	_advance(now_us)
	_b[_idx] += n


func per_sec(now_us: int) -> int:
	_advance(now_us)
	var s := 0
	for v in _b:
		s += v
	return s
