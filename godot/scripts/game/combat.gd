class_name Combat
extends RefCounted
## Серверная часть боя и рун: попадания, урон, отталкивание, подбор. Клиент это НЕ считает —
## последствия приходят в снимке (ownerState) и применяются сверкой (reconciliation).


static func _overlap(a1: int, a2: int, b1: int, b2: int) -> bool:
	return a1 < b2 and b1 < a2


## Хитбокс активной атаки атакующего: [x1, x2, y1, y2] в u.
static func hitbox(a: PState) -> Array:
	var reach := (GC.LIGHT_REACH_PX if a.atk_kind == 1 else GC.HEAVY_REACH_PX) * GC.SUB
	var hw := GC.HALF_W_PX * GC.SUB
	var back := 4 * GC.SUB
	var y2 := a.y - 4 * GC.SUB
	var y1 := a.y - 44 * GC.SUB
	if a.facing > 0:
		return [a.x + hw - back, a.x + hw + reach, y1, y2]
	return [a.x - hw - reach, a.x - hw + back, y1, y2]


static func body(s: PState) -> Array:
	var hw := GC.HALF_W_PX * GC.SUB
	return [s.x - hw, s.x + hw, s.y - GC.HEIGHT_PX * GC.SUB, s.y]


## Разбор попаданий за тик. players: id -> PState (живые и мёртвые), порядок обхода — по возрастанию id (детерминизм).
## last_hit: id жертвы -> {by, tick} (для засчёта убийства при падении). stats: id -> {damage, kills}.
## Возвращает массив событий [{kind,a,b,x,y,v}].
static func resolve_hits(players: Dictionary, tick: int, last_hit: Dictionary, stats: Dictionary) -> Array:
	var events: Array = []
	var ids: Array = players.keys()
	ids.sort()
	for aid in ids:
		var a: PState = players[aid]
		if not a.alive or not PlatSim.attack_active(a):
			continue
		var hb := hitbox(a)
		for vid in ids:
			if vid == aid:
				continue
			var v: PState = players[vid]
			if not v.alive or (a.hit_mask & (1 << vid)) != 0:
				continue
			var bb := body(v)
			if not (_overlap(hb[0], hb[1], bb[0], bb[1]) and _overlap(hb[2], hb[3], bb[2], bb[3])):
				continue
			a.hit_mask |= 1 << vid
			var heavy := a.atk_kind == 2
			var dmg := GC.HEAVY_DAMAGE if heavy else GC.LIGHT_DAMAGE
			var kbx := GC.HEAVY_KB_X if heavy else GC.LIGHT_KB_X
			var kby := GC.HEAVY_KB_Y if heavy else GC.LIGHT_KB_Y
			var stun := GC.HEAVY_STUN if heavy else GC.LIGHT_STUN
			if a.buffs[GC.R_DAMAGE] > 0:
				dmg = dmg * (100 + GC.DAMAGE_BONUS_PCT) / 100
			if v.buffs[GC.R_ARMOR] > 0:
				dmg = maxi(dmg * (100 - GC.ARMOR_REDUCTION_PCT) / 100, 1)
			if a.buffs[GC.R_KNOCKBACK] > 0:
				kbx = kbx * (100 + GC.KNOCKBACK_BONUS_PCT) / 100
				kby = kby * (100 + GC.KNOCKBACK_BONUS_PCT) / 100
			if v.buffs[GC.R_STEADY] > 0:
				kbx = kbx * (100 - GC.STEADY_REDUCTION_PCT) / 100
				kby = kby * (100 - GC.STEADY_REDUCTION_PCT) / 100
			var dir := 1 if v.x > a.x else (-1 if v.x < a.x else a.facing)
			v.hp = maxi(v.hp - dmg, 0)
			v.vx = dir * kbx
			v.vy = -kby
			v.on_ground = false
			v.jumping = false
			v.stun = stun
			v.atk_kind = 0
			v.atk_tick = 0
			v.dash_left = 0
			if a.buffs[GC.R_VAMPIRE] > 0:
				a.hp = mini(a.hp + maxi(dmg * GC.VAMPIRE_HEAL_PCT / 100, 1), GC.HP_MAX)
			if a.buffs[GC.R_SLOWHIT] > 0:
				v.slow = GC.DEBUFF_TICKS
			if a.buffs[GC.R_INVERTHIT] > 0:
				v.invert = GC.DEBUFF_TICKS
			last_hit[vid] = {"by": aid, "tick": tick}
			if stats.has(aid):
				stats[aid]["damage"] += dmg
			events.append({"kind": GC.EV_HIT, "a": aid, "b": vid, "x": v.x / GC.SUB, "y": (v.y - 24 * GC.SUB) / GC.SUB, "v": dmg})
			if v.hp <= 0:
				v.alive = false
				events.append({"kind": GC.EV_DEATH, "a": vid, "b": aid, "x": v.x / GC.SUB, "y": v.y / GC.SUB, "v": 0})
				if stats.has(aid):
					stats[aid]["kills"] += 1
	return events


## Можно ли сейчас подобрать руну этого типа (здоровье не подбирается при полном HP).
static func can_pickup(s: PState, rune_type: int) -> bool:
	if not s.alive:
		return false
	if rune_type == GC.R_HEALTH and s.hp >= GC.HP_MAX:
		return false
	return true


## Применить подбор. Временные руны: максимум GC.MAX_ACTIVE_BUFFS одновременно (вытесняется самая «короткая»);
## повторный подбор той же руны обновляет таймер.
static func apply_pickup(s: PState, rune_type: int) -> void:
	if rune_type == GC.R_HEALTH:
		s.hp = mini(s.hp + GC.HEALTH_RUNE_HEAL, GC.HP_MAX)
		return
	var ticks := GC.CHAOS_TICKS if rune_type == GC.R_CHAOS else GC.BUFF_TICKS
	if s.buffs[rune_type] == 0:
		var active: Array = []
		for i in GC.NUM_RUNES:
			if s.buffs[i] > 0:
				active.append(i)
		if active.size() >= GC.MAX_ACTIVE_BUFFS:
			var weakest: int = active[0]
			for i in active:
				if s.buffs[i] < s.buffs[weakest]:
					weakest = i
			s.buffs[weakest] = 0
	s.buffs[rune_type] = ticks


## Подбор рун игроками за тик. runes: Array of {id,type,x,y} (u); возвращает события и удаляет подобранные.
static func resolve_pickups(players: Dictionary, runes: Array) -> Array:
	var events: Array = []
	var ids: Array = players.keys()
	ids.sort()
	var remaining: Array = []
	for r in runes:
		var taken := false
		var rh := GC.RUNE_HALF_PX * GC.SUB
		for pid in ids:
			var p: PState = players[pid]
			if not can_pickup(p, r["type"]):
				continue
			var bb := body(p)
			if _overlap(bb[0], bb[1], r["x"] - rh, r["x"] + rh) and _overlap(bb[2], bb[3], r["y"] - 2 * rh, r["y"]):
				apply_pickup(p, r["type"])
				events.append({"kind": GC.EV_PICKUP, "a": pid, "b": r["type"], "x": r["x"] / GC.SUB, "y": r["y"] / GC.SUB, "v": r["id"]})
				taken = true
				break
		if not taken:
			remaining.append(r)
	runes.clear()
	runes.append_array(remaining)
	return events
