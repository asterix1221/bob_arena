class_name ReplCodec
extends RefCounted
## Формат пакетов репликации (ПР №5). Заголовок — общий, 8 байт (Proto). Все числа big-endian.
##
## T_WORLD_UPDATE (13, Unreliable): tick u16 | fmt u8 | count u8 | записи
##   fmt бит0 = FMT_DELTA, бит1 = FMT_QUANT.
##   запись без дельты (наивная):  id u16 | cls u8 | x y vx vy | st u8 | hp u8            — 21 байт во float32
##   запись с дельтой (push):      id u16 | mask u8 | только поля из маски (X,Y,VX,VY,ST,HP по порядку)
##   поля: float32 (без квантования) или x,y = u16 (шаг 0,25 px), vx,vy = i8 (шаг 8 px/с).
## T_WORLD_RELIABLE (14, Reliable): tick u16 | fmt u8 | count u8 | записи
##   OP_UPSERT: op u8 | id u16 | cls u8 | все 6 полей   (появление актора или его новое состояние после «сна»)
##   OP_DESTROY: op u8 | id u16 | reason u8
## Состояние в OP_UPSERT полное, поэтому потерянный или опоздавший «spawn» не страшен (клиент создаёт актор и по «пробуждению»);
## порядок пакетов не гарантирован — клиент сверяет tick записи с последним применённым и ведёт «надгробия» удалённых id.


static func is_quant(fmt: int) -> bool:
	return (fmt & ReplDefs.FMT_QUANT) != 0


## Размер набора полей по маске.
static func fields_size(mask: int, q: bool) -> int:
	var n := 0
	if mask & ReplDefs.F_X:
		n += 2 if q else 4
	if mask & ReplDefs.F_Y:
		n += 2 if q else 4
	if mask & ReplDefs.F_VX:
		n += 1 if q else 4
	if mask & ReplDefs.F_VY:
		n += 1 if q else 4
	if mask & ReplDefs.F_ST:
		n += 1
	if mask & ReplDefs.F_HP:
		n += 1
	return n


## Размер записи в T_WORLD_UPDATE.
static func update_entry_size(fmt: int, mask: int) -> int:
	var m := mask if (fmt & ReplDefs.FMT_DELTA) != 0 else ReplDefs.F_ALL
	return 3 + fields_size(m, is_quant(fmt))


static func upsert_entry_size(fmt: int) -> int:
	return 4 + fields_size(ReplDefs.F_ALL, is_quant(fmt))


const DESTROY_ENTRY_SIZE := 4


static func write_fields(b: PackedByteArray, a: ReplActor, mask: int, q: bool) -> void:
	if mask & ReplDefs.F_X:
		if q:
			Wire.w_u16(b, ReplDefs.q_pos(a.x))
		else:
			Wire.w_f32(b, a.x)
	if mask & ReplDefs.F_Y:
		if q:
			Wire.w_u16(b, ReplDefs.q_pos(a.y))
		else:
			Wire.w_f32(b, a.y)
	if mask & ReplDefs.F_VX:
		if q:
			Wire.w_i8(b, ReplDefs.q_vel(a.vx))
		else:
			Wire.w_f32(b, a.vx)
	if mask & ReplDefs.F_VY:
		if q:
			Wire.w_i8(b, ReplDefs.q_vel(a.vy))
		else:
			Wire.w_f32(b, a.vy)
	if mask & ReplDefs.F_ST:
		Wire.w_u8(b, a.st)
	if mask & ReplDefs.F_HP:
		Wire.w_u8(b, a.hp)


static func read_fields(r: Wire.Reader, mask: int, q: bool, out: Dictionary) -> void:
	if mask & ReplDefs.F_X:
		out["x"] = ReplDefs.dq_pos(r.u16()) if q else r.f32()
	if mask & ReplDefs.F_Y:
		out["y"] = ReplDefs.dq_pos(r.u16()) if q else r.f32()
	if mask & ReplDefs.F_VX:
		out["vx"] = ReplDefs.dq_vel(r.i8()) if q else r.f32()
	if mask & ReplDefs.F_VY:
		out["vy"] = ReplDefs.dq_vel(r.i8()) if q else r.f32()
	if mask & ReplDefs.F_ST:
		out["st"] = r.u8()
	if mask & ReplDefs.F_HP:
		out["hp"] = r.u8()


## entries: Array из [ReplActor, mask].
static func update_packet(seq: int, tick: int, fmt: int, entries: Array) -> PackedByteArray:
	var q := is_quant(fmt)
	var size := 4
	for e in entries:
		size += update_entry_size(fmt, int(e[1]))
	var b := Proto._header(Proto.T_WORLD_UPDATE, seq, size, false)
	Wire.w_u16(b, tick)
	Wire.w_u8(b, fmt)
	Wire.w_u8(b, entries.size())
	for e in entries:
		var a: ReplActor = e[0]
		var mask: int = e[1]
		Wire.w_u16(b, a.id)
		if (fmt & ReplDefs.FMT_DELTA) != 0:
			Wire.w_u8(b, mask)
			write_fields(b, a, mask, q)
		else:
			Wire.w_u8(b, a.cls)
			write_fields(b, a, ReplDefs.F_ALL, q)
	return b


static func parse_update(d: PackedByteArray) -> Dictionary:
	var h := Proto._check(d, Proto.T_WORLD_UPDATE, false)
	if h.is_empty():
		return {}
	var r := Wire.Reader.new(d, Proto.HEADER_SIZE)
	var tick := r.u16()
	var fmt := r.u8()
	var n := r.u8()
	if not r.ok or (fmt & ~3) != 0:
		return {}
	var q := is_quant(fmt)
	var entries: Array = []
	for i in n:
		var e := {"id": r.u16()}
		if (fmt & ReplDefs.FMT_DELTA) != 0:
			var mask := r.u8()
			if not r.ok or mask == 0 or mask > ReplDefs.F_ALL:
				return {}
			e["mask"] = mask
			read_fields(r, mask, q, e)
		else:
			e["cls"] = r.u8()
			e["mask"] = ReplDefs.F_ALL
			read_fields(r, ReplDefs.F_ALL, q, e)
		if not r.ok:
			return {}
		entries.append(e)
	if not r.ok or r.left() != 0:
		return {}
	return h.merged({"tick": tick, "fmt": fmt, "entries": entries})


## entries: Array из [ReplDefs.OP_UPSERT, ReplActor] или [ReplDefs.OP_DESTROY, id, reason].
static func reliable_packet(seq: int, tick: int, fmt: int, entries: Array) -> PackedByteArray:
	var q := is_quant(fmt)
	var size := 4
	for e in entries:
		size += upsert_entry_size(fmt) if int(e[0]) == ReplDefs.OP_UPSERT else DESTROY_ENTRY_SIZE
	var b := Proto._header(Proto.T_WORLD_RELIABLE, seq, size, true)
	Wire.w_u16(b, tick)
	Wire.w_u8(b, fmt & ReplDefs.FMT_QUANT)
	Wire.w_u8(b, entries.size())
	for e in entries:
		Wire.w_u8(b, int(e[0]))
		if int(e[0]) == ReplDefs.OP_UPSERT:
			var a: ReplActor = e[1]
			Wire.w_u16(b, a.id)
			Wire.w_u8(b, a.cls)
			write_fields(b, a, ReplDefs.F_ALL, q)
		else:
			Wire.w_u16(b, int(e[1]))
			Wire.w_u8(b, int(e[2]))
	return b


static func parse_reliable(d: PackedByteArray) -> Dictionary:
	var h := Proto._check(d, Proto.T_WORLD_RELIABLE, true)
	if h.is_empty():
		return {}
	var r := Wire.Reader.new(d, Proto.HEADER_SIZE)
	var tick := r.u16()
	var fmt := r.u8()
	var n := r.u8()
	if not r.ok or (fmt & ~ReplDefs.FMT_QUANT) != 0:
		return {}
	var q := is_quant(fmt)
	var entries: Array = []
	for i in n:
		var op := r.u8()
		var e := {"op": op, "id": r.u16()}
		if op == ReplDefs.OP_UPSERT:
			e["cls"] = r.u8()
			if not r.ok or int(e["cls"]) >= ReplDefs.NUM_CLASSES:
				return {}
			read_fields(r, ReplDefs.F_ALL, q, e)
		elif op == ReplDefs.OP_DESTROY:
			e["reason"] = r.u8()
		else:
			return {}
		if not r.ok:
			return {}
		entries.append(e)
	if not r.ok or r.left() != 0:
		return {}
	return h.merged({"tick": tick, "fmt": fmt, "entries": entries})
