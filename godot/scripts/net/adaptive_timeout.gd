class_name AdaptiveTimeout
extends RefCounted
## Порт reliability/adaptive_timeout.{hpp,cpp}: оценка RTO по Jacobson/Karels (RFC 6298).
## SRTT, RTTVAR, RTO = SRTT + 4*RTTVAR в пределах [100, 3000] мс; до первого замера RTO = 1000 мс.
## Алгоритм Карна соблюдает вызывающий код: RTT берётся только с пакетов, не отправлявшихся повторно.

const ALPHA := 0.125
const BETA := 0.25
const MIN_RTO_MS := 100.0
const MAX_RTO_MS := 3000.0
const INITIAL_RTO_MS := 1000.0

var srtt_ms := 0.0
var rttvar_ms := 0.0
var initialized := false


func on_sample(rtt_ms: float) -> void:
	if not (rtt_ms >= 0.0):  # отрицательные и NaN игнорируются
		return
	if not initialized:
		srtt_ms = rtt_ms
		rttvar_ms = rtt_ms / 2.0
		initialized = true
		return
	rttvar_ms = (1.0 - BETA) * rttvar_ms + BETA * absf(srtt_ms - rtt_ms)
	srtt_ms = (1.0 - ALPHA) * srtt_ms + ALPHA * rtt_ms


func rto_ms() -> float:
	var raw := (srtt_ms + 4.0 * rttvar_ms) if initialized else INITIAL_RTO_MS
	return clampf(raw, MIN_RTO_MS, MAX_RTO_MS)


func rto_us() -> int:
	return int(rto_ms() * 1000.0)
