class_name PState
extends RefCounted
## Полное состояние игрока (целые числа). Копируется, сериализуется в «ownerState» снимка и сравнивается побайтно.

var x := 0
var y := 0
var vx := 0
var vy := 0
var hp := 100
var alive := true
var facing := 1
var on_ground := false
var jumping := false
var coyote := 0
var jump_buf := 0
var drop_t := 0
var dash_left := 0
var dash_cd := 0
var dash_dir := 1
var stamina := 100000
var atk_kind := 0        # 0 нет, 1 лёгкий, 2 тяжёлый
var atk_tick := 0
var atk_cd := 0
var hit_mask := 0        # жертвы, уже получившие удар в текущей атаке (бит = id игрока)
var stun := 0
var slow := 0            # дебафф «замедление»
var invert := 0          # дебафф «инверсия управления»
var buffs: Array[int] = []


func _init() -> void:
	buffs.resize(GC.NUM_RUNES)
	buffs.fill(0)


static func spawn(slot: int) -> PState:
	var s := PState.new()
	var sp := GC.spawn_u(slot)
	s.x = sp[0]
	s.y = sp[1]
	s.hp = GC.HP_MAX
	s.stamina = GC.STAMINA_MAX
	s.facing = 1 if sp[0] < 640 * GC.SUB else -1
	s.on_ground = true
	return s


func copy() -> PState:
	var c := PState.new()
	c.x = x; c.y = y; c.vx = vx; c.vy = vy; c.hp = hp; c.alive = alive; c.facing = facing
	c.on_ground = on_ground; c.jumping = jumping; c.coyote = coyote; c.jump_buf = jump_buf; c.drop_t = drop_t
	c.dash_left = dash_left; c.dash_cd = dash_cd; c.dash_dir = dash_dir; c.stamina = stamina
	c.atk_kind = atk_kind; c.atk_tick = atk_tick; c.atk_cd = atk_cd; c.hit_mask = hit_mask
	c.stun = stun; c.slow = slow; c.invert = invert
	c.buffs = buffs.duplicate()
	return c


func equals(o: PState) -> bool:
	return to_bytes() == o.to_bytes()


func flag_byte() -> int:
	var f := 0
	if alive: f |= 1
	if facing > 0: f |= 2
	if on_ground: f |= 4
	if dash_left > 0: f |= 8
	if atk_kind == 1: f |= 16
	if atk_kind == 2: f |= 32
	if stun > 0: f |= 64
	if slow > 0 or invert > 0: f |= 128
	return f


## Маска активных рун (биты 0..10) + дебаффы (бит 11 замедление, бит 12 инверсия) — для аур у всех игроков.
func buff_mask() -> int:
	var m := 0
	for i in GC.NUM_RUNES:
		if buffs[i] > 0:
			m |= 1 << i
	if slow > 0: m |= 1 << 11
	if invert > 0: m |= 1 << 12
	return m


func to_bytes() -> PackedByteArray:
	var b := PackedByteArray()
	Wire.w_i32(b, x); Wire.w_i32(b, y); Wire.w_i32(b, vx); Wire.w_i32(b, vy)
	Wire.w_u8(b, hp)
	var bits := 0
	if alive: bits |= 1
	if on_ground: bits |= 2
	if jumping: bits |= 4
	if facing > 0: bits |= 8
	if dash_dir > 0: bits |= 16
	Wire.w_u8(b, bits)
	Wire.w_u8(b, coyote); Wire.w_u8(b, jump_buf); Wire.w_u8(b, drop_t)
	Wire.w_u8(b, dash_left); Wire.w_u8(b, dash_cd); Wire.w_u32(b, stamina)
	Wire.w_u8(b, atk_kind); Wire.w_u8(b, atk_tick); Wire.w_u8(b, atk_cd); Wire.w_u8(b, hit_mask)
	Wire.w_u8(b, stun); Wire.w_u16(b, slow); Wire.w_u16(b, invert)
	for i in GC.NUM_RUNES:
		Wire.w_u16(b, buffs[i])
	return b


## Размер блока ownerState (без префикса фазы): 16+1+1+3+2+4+4+1+4+22 = 58 байт (< 96).
static func from_bytes(d: PackedByteArray) -> PState:
	var r := Wire.Reader.new(d)
	var s := PState.new()
	s.x = r.i32(); s.y = r.i32(); s.vx = r.i32(); s.vy = r.i32()
	s.hp = r.u8()
	var bits := r.u8()
	s.alive = bits & 1 != 0
	s.on_ground = bits & 2 != 0
	s.jumping = bits & 4 != 0
	s.facing = 1 if bits & 8 != 0 else -1
	s.dash_dir = 1 if bits & 16 != 0 else -1
	s.coyote = r.u8(); s.jump_buf = r.u8(); s.drop_t = r.u8()
	s.dash_left = r.u8(); s.dash_cd = r.u8(); s.stamina = r.u32()
	s.atk_kind = r.u8(); s.atk_tick = r.u8(); s.atk_cd = r.u8(); s.hit_mask = r.u8()
	s.stun = r.u8(); s.slow = r.u16(); s.invert = r.u16()
	for i in GC.NUM_RUNES:
		s.buffs[i] = r.u16()
	if not r.ok or r.left() != 0:
		return null
	return s
