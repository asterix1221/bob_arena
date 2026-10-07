extends SceneTree
## Тесты платформерной симуляции, боя и рун (без сети). Запуск:
##   godot --headless --path godot -s res://tests/run_game_tests.gd

var passed := 0
var failed := 0
var current := ""

const PX := GC.SUB


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failed += 1
		print("  FAIL [%s] %s" % [current, msg])


func run(name: String, fn: Callable) -> void:
	current = name
	var before := failed
	fn.call()
	if failed == before:
		passed += 1
		print("  ok   %s" % name)


func _init() -> void:
	print("== Движение ==")
	run("состояние: сериализация, копия, размер блока", t_state)
	run("спавн стоит на платформе без дрожи", t_stand)
	run("падение на платформу сверху", t_land)
	run("разгон и торможение по земле", t_run)
	run("прыжок: высота ~150 px", t_jump_height)
	run("короткое нажатие даёт низкий прыжок", t_jump_cut)
	run("coyote time: прыжок после схода с края", t_coyote)
	run("буфер прыжка: нажатие до приземления", t_jump_buffer)
	run("спрыгивание вниз (DOWN + прыжок)", t_drop)
	run("падение с арены = смерть", t_fall_death)
	run("платформа проходима снизу", t_pass_through)
	print("== Рывок ==")
	run("рывок: скорость, дистанция, длительность", t_dash)
	run("рывок: кулдаун, выносливость, причины отказа", t_dash_rules)
	print("== Бой ==")
	run("лёгкая атака стартует в тот же тик и заканчивается по таймеру", t_light_timing)
	run("тяжёлая: замах, активные кадры 18..23", t_heavy_timing)
	run("попадание: урон, отталкивание, оглушение, один удар на атаку", t_hit)
	run("оглушённый не может действовать; удар отменяет рывок", t_stun_cancel)
	run("смерть от урона: событие и счёт убийств", t_kill)
	print("== Руны ==")
	run("руна скорости, прыжка", t_rune_move)
	run("руны урона, брони, отталкивания, устойчивости", t_rune_combat)
	run("вампиризм", t_rune_vampire)
	run("замедление и инверсия на жертве", t_rune_debuffs)
	run("здоровье: не берётся при полном HP, лечит, ограничено 100", t_rune_health)
	run("не более трёх рун: вытесняется самая короткая; повтор обновляет", t_rune_cap)
	run("подбор по пересечению, мёртвый не берёт, событие и удаление", t_pickup)
	print("== Детерминизм ==")
	run("одинаковые команды -> побайтно одинаковое состояние (5000 тиков)", t_determinism)
	print("\n%d тестов, %d провалено" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)


# ------------------------------------------------------------------ помощники

func sim(s: PState, n: int, axis: int = 0, buttons: int = 0) -> void:
	for i in n:
		PlatSim.step(s, axis, buttons)


func one(s: PState, axis: int = 0, buttons: int = 0) -> String:
	return PlatSim.step(s, axis, buttons)


func at(slot: int, x_px: int, y_px: int) -> PState:
	var s := PState.spawn(slot)
	s.x = x_px * PX
	s.y = y_px * PX
	return s


func pair(dx_px: int = 30) -> Array:
	## Атакующий смотрит вправо, жертва справа на расстоянии dx. Обе на центральной платформе.
	var a := at(0, 500, 460)
	var v := at(1, 500 + dx_px, 460)
	a.facing = 1
	return [a, v]


func players(a: PState, v: PState) -> Dictionary:
	return {0: a, 1: v}


# ------------------------------------------------------------------ движение

func t_state() -> void:
	var s := PState.spawn(2)
	s.buffs[GC.R_SPEED] = 1234
	s.stun = 7
	s.x = -123456
	s.vy = -999
	var b := s.to_bytes()
	check(b.size() == 58, "размер блока %d" % b.size())
	var r := PState.from_bytes(b)
	check(r != null and r.equals(s), "round-trip")
	check(r.x == -123456 and r.vy == -999 and r.buffs[GC.R_SPEED] == 1234, "знаковые и массив")
	check(s.copy().equals(s), "копия равна оригиналу")
	check(PState.from_bytes(b.slice(0, 57)) == null, "усечённый блок отклонён")
	var c := s.copy()
	c.buffs[0] = 5
	check(s.buffs[GC.R_SPEED] == 1234, "копия независима")


func t_stand() -> void:
	var s := PState.spawn(0)
	var y0 := s.y
	sim(s, 200)
	check(s.y == y0 and s.on_ground and s.vy == 0 and s.alive, "y=%d on_ground=%s" % [s.y, s.on_ground])


func t_land() -> void:
	var s := at(0, 600, 200)
	var landed := -1
	for i in 400:
		one(s)
		if s.on_ground and landed < 0:
			landed = i
	check(landed > 0 and s.y == 460 * PX and s.vy == 0, "приземлился на тике %d, y=%d" % [landed, s.y / PX])


func t_run() -> void:
	var s := PState.spawn(0)
	sim(s, 12, 127)
	check(s.vx == GC.RUN_MAX, "максимум скорости %d" % s.vx)
	var x_before := s.x
	sim(s, 10, 127)
	check(s.x - x_before == 10 * GC.RUN_MAX, "равномерное движение")
	sim(s, 8, 0)
	check(s.vx == 0, "остановка за 8 тиков, vx=%d" % s.vx)
	var h := PState.spawn(0)
	sim(h, 40, 64)
	check(absi(h.vx - 64 * GC.RUN_MAX / 127) <= 1, "аналоговая половина оси: %d" % h.vx)
	var t := PState.spawn(0)
	sim(t, 12, 127)
	sim(t, 1, -127)
	check(t.vx == GC.RUN_MAX - 2 * GC.GROUND_ACC, "разворот вдвое быстрее: %d" % t.vx)
	check(t.facing == -1, "разворот меняет направление")


func t_jump_height() -> void:
	var s := PState.spawn(0)
	var y0 := s.y
	var peak := 0
	one(s, 0, Proto.BTN_JUMP | Proto.BTN_JUMP_HELD)
	for i in 200:
		one(s, 0, Proto.BTN_JUMP_HELD)
		peak = maxi(peak, y0 - s.y)
	var h := peak / PX
	check(h >= 140 and h <= 165, "высота прыжка %d px" % h)
	check(s.on_ground and s.y == y0, "вернулся на платформу")


func t_jump_cut() -> void:
	var s := PState.spawn(0)
	var y0 := s.y
	var peak := 0
	one(s, 0, Proto.BTN_JUMP | Proto.BTN_JUMP_HELD)
	for i in 200:
		one(s, 0, 0)       # клавишу отпустили сразу
		peak = maxi(peak, y0 - s.y)
	var h := peak / PX
	check(h > 15 and h < 80, "короткий прыжок %d px" % h)


func t_coyote() -> void:
	var s := at(0, 938, 460)             # у правого края центральной платформы
	sim(s, 3, 127)                       # сходим с края (платформа допускает +4 px)
	var off := 0
	while s.on_ground and off < 60:
		one(s, 127)
		off += 1
	check(not s.on_ground, "сошёл с платформы")
	sim(s, 5, 127)
	var y_before := s.y
	one(s, 127, Proto.BTN_JUMP | Proto.BTN_JUMP_HELD)
	check(s.vy < 0, "прыжок в окне coyote (5 тиков): vy=%d" % s.vy)
	var late := at(0, 938, 460)
	sim(late, 60, 127)
	check(not late.on_ground, "сошёл")
	sim(late, 13, 127)
	var vy_before := late.vy
	one(late, 127, Proto.BTN_JUMP)
	check(late.vy >= vy_before, "после 12 тиков прыжка в воздухе нет")


func t_jump_buffer() -> void:
	var s := at(0, 600, 460 - 12)        # падает с 12 px (~12 тиков), буфер 12 тиков
	s.on_ground = false
	var jumped_at := -1
	for i in 60:
		var btn := Proto.BTN_JUMP if i == 4 else 0
		one(s, 0, btn | Proto.BTN_JUMP_HELD)
		if jumped_at < 0 and s.vy < 0:
			jumped_at = i
	check(jumped_at > 4, "нажатие на тике 4, прыжок при приземлении на тике %d" % jumped_at)


func t_drop() -> void:
	var s := at(0, 180, 330)             # левая платформа
	s.on_ground = true
	one(s, 0, Proto.BTN_JUMP | Proto.BTN_DOWN)
	sim(s, 30)
	check(s.y > 330 * PX + 5 * PX and not s.on_ground, "провалился сквозь платформу, y=%d" % [s.y / PX])
	var t := at(0, 180, 330)
	t.on_ground = true
	one(t, 0, Proto.BTN_JUMP)            # без DOWN — обычный прыжок
	check(t.vy < 0, "без DOWN прыжок")


func t_fall_death() -> void:
	var s := at(0, 938, 460)
	var died := -1
	for i in 600:
		one(s, 127)
		if not s.alive:
			died = i
			break
	check(died > 0 and s.y > GC.FALL_Y_PX * PX, "умер на тике %d" % died)
	var before := s.to_bytes()
	one(s, 127, Proto.BTN_JUMP)
	check(s.to_bytes() == before, "мёртвый не меняется")


func t_pass_through() -> void:
	var s := at(0, 600, 460 + 80)        # под центральной платформой, летит вверх
	s.vy = -2000
	s.on_ground = false
	var landed_on_top := false
	for i in 150:
		one(s)
		if s.on_ground:
			landed_on_top = true
	check(landed_on_top and s.y == 460 * PX, "пролетел сквозь и сел сверху")


# ------------------------------------------------------------------ рывок

func t_dash() -> void:
	var s := PState.spawn(0)
	var x0 := s.x
	one(s, 127, Proto.BTN_DASH)
	check(s.dash_left == GC.DASH_TICKS - 1 and s.vx == GC.DASH_SPEED, "старт: vx=%d" % s.vx)
	check(s.stamina == GC.STAMINA_MAX - GC.DASH_COST, "стоимость списана: %d" % s.stamina)
	sim(s, GC.DASH_TICKS - 1, 127)
	check(s.dash_left == 0, "рывок закончился")
	var dist := (s.x - x0) / PX
	check(dist >= 160 and dist <= 190, "дистанция рывка %d px" % dist)
	check(s.vy == 0 or s.on_ground, "рывок по земле без падения")
	var back := PState.spawn(0)
	one(back, 0, Proto.BTN_DASH)
	check(back.dash_dir == back.facing, "без оси — по направлению взгляда")


func t_dash_rules() -> void:
	var s := PState.spawn(0)
	check(one(s, 127, Proto.BTN_DASH) == "", "первый рывок разрешён")
	check(one(s, 127, Proto.BTN_DASH) == "already_dashing", "во время рывка — отказ")
	sim(s, GC.DASH_TICKS, 127)
	check(one(s, 127, Proto.BTN_DASH) == "cooldown", "кулдаун")
	sim(s, GC.DASH_COOLDOWN, 0)
	check(one(s, 127, Proto.BTN_DASH) == "", "после кулдауна разрешён")
	var t := PState.spawn(0)
	t.stamina = GC.DASH_COST - 300      # шаг успевает добавить ~208 регенерации
	check(one(t, 0, Proto.BTN_DASH) == "no_stamina", "не хватает выносливости")
	var u := PState.spawn(0)
	u.stun = 5
	check(one(u, 0, Proto.BTN_DASH) == "stunned", "оглушён")
	var w := PState.spawn(0)
	w.stamina = 0
	sim(w, 120)     # 1 секунда
	check(w.stamina >= 24000 and w.stamina <= 26000, "регенерация ~25 ед./с: %d" % w.stamina)
	check(one(PState.spawn(0), 0, 0) == "", "без запроса рывка причины нет")


# ------------------------------------------------------------------ бой

func t_light_timing() -> void:
	var s := PState.spawn(0)
	one(s, 0, Proto.BTN_LIGHT)
	check(s.atk_kind == 1 and s.atk_tick == 0 and PlatSim.attack_active(s), "атака началась в тот же тик")
	var active := 1
	for i in 40:
		one(s)
		if PlatSim.attack_active(s):
			active += 1
	check(active == GC.LIGHT_ACTIVE_END, "активных кадров %d" % active)
	check(s.atk_kind == 0, "атака закончилась")
	var t := PState.spawn(0)
	one(t, 0, Proto.BTN_LIGHT)
	var started_again := false
	for i in GC.LIGHT_TOTAL + GC.ATTACK_COOLDOWN + 2:
		one(t, 0, Proto.BTN_LIGHT)
		if t.atk_kind != 0 and t.atk_tick == 0:
			started_again = true
	check(started_again, "после восстановления и паузы можно бить снова")
	var u := PState.spawn(0)
	one(u, 0, Proto.BTN_LIGHT)
	one(u, 0, Proto.BTN_LIGHT)
	check(u.atk_tick == 1, "нельзя перезапустить атаку посреди неё")


func t_heavy_timing() -> void:
	var s := PState.spawn(0)
	one(s, 0, Proto.BTN_HEAVY)
	var active_ticks: Array = []
	for i in GC.HEAVY_TOTAL + 2:
		if PlatSim.attack_active(s):
			active_ticks.append(s.atk_tick)
		one(s)
	check(active_ticks == [18, 19, 20, 21, 22, 23], "активные тики %s" % str(active_ticks))
	var w := PState.spawn(0)
	one(w, 127, Proto.BTN_HEAVY)
	sim(w, 20, 127)
	check(w.vx <= GC.RUN_MAX * 30 / 100, "во время тяжёлой скорость ограничена: %d" % w.vx)


func t_hit() -> void:
	var p := pair(30)
	var a: PState = p[0]
	var v: PState = p[1]
	var last := {}
	var stats := {0: {"damage": 0, "kills": 0}, 1: {"damage": 0, "kills": 0}}
	one(a, 0, Proto.BTN_LIGHT)
	var ev := Combat.resolve_hits(players(a, v), 1, last, stats)
	check(ev.size() == 1 and ev[0]["kind"] == GC.EV_HIT and ev[0]["a"] == 0 and ev[0]["b"] == 1 and ev[0]["v"] == GC.LIGHT_DAMAGE, "событие HIT: %s" % str(ev))
	check(v.hp == 100 - GC.LIGHT_DAMAGE, "hp %d" % v.hp)
	check(v.vx == GC.LIGHT_KB_X and v.vy == -GC.LIGHT_KB_Y and v.stun == GC.LIGHT_STUN, "отталкивание вправо и вверх, оглушение")
	check(stats[0]["damage"] == GC.LIGHT_DAMAGE and last[1]["by"] == 0, "статистика и «кто бил»")
	for i in 5:
		one(a)
		check(Combat.resolve_hits(players(a, v), 2 + i, last, stats).is_empty(), "повторных ударов в этой атаке нет")
	var far := pair(120)
	one(far[0], 0, Proto.BTN_LIGHT)
	check(Combat.resolve_hits(players(far[0], far[1]), 1, {}, {}).is_empty(), "вне досягаемости не попадает")
	var behind := pair(30)
	behind[0].facing = -1
	one(behind[0], 0, Proto.BTN_LIGHT)
	check(Combat.resolve_hits(players(behind[0], behind[1]), 1, {}, {}).is_empty(), "за спиной не попадает")
	var h := pair(40)
	one(h[0], 0, Proto.BTN_HEAVY)
	sim(h[0], 18)
	var ev2 := Combat.resolve_hits(players(h[0], h[1]), 1, {}, {})
	check(ev2.size() == 1 and ev2[0]["v"] == GC.HEAVY_DAMAGE and h[1].vx == GC.HEAVY_KB_X, "тяжёлый: урон и отталкивание")


func t_stun_cancel() -> void:
	var v := PState.spawn(1)
	v.stun = 10
	check(one(v, 0, Proto.BTN_LIGHT) == "" and v.atk_kind == 0, "оглушённый не атакует")
	var d := PState.spawn(1)
	one(d, 127, Proto.BTN_DASH)
	check(d.dash_left > 0, "рывок идёт")
	var p := pair(30)
	var victim: PState = p[1]
	victim.dash_left = 10
	one(p[0], 0, Proto.BTN_LIGHT)
	Combat.resolve_hits(players(p[0], victim), 1, {}, {})
	check(victim.dash_left == 0 and victim.atk_kind == 0, "удар прерывает рывок и атаку")
	var vx_before := victim.vx
	one(victim, -127, 0)
	check(abs(victim.vx) >= abs(vx_before) - GC.STUN_DRAG, "в оглушении управление не гасит отталкивание")


func t_kill() -> void:
	var p := pair(30)
	var a: PState = p[0]
	var v: PState = p[1]
	v.hp = 5
	var stats := {0: {"damage": 0, "kills": 0}, 1: {"damage": 0, "kills": 0}}
	one(a, 0, Proto.BTN_LIGHT)
	var ev := Combat.resolve_hits(players(a, v), 1, {}, stats)
	check(ev.size() == 2 and ev[1]["kind"] == GC.EV_DEATH and ev[1]["a"] == 1 and ev[1]["b"] == 0, "HIT + DEATH: %s" % str(ev))
	check(not v.alive and v.hp == 0 and stats[0]["kills"] == 1, "жертва мертва, убийство засчитано")
	one(a)
	check(Combat.resolve_hits(players(a, v), 2, {}, stats).is_empty(), "по мёртвому не бьют")


# ------------------------------------------------------------------ руны

func t_rune_move() -> void:
	var s := PState.spawn(0)
	Combat.apply_pickup(s, GC.R_SPEED)
	sim(s, 20, 127)
	check(s.vx == GC.RUN_MAX * 130 / 100, "скорость с руной %d" % s.vx)
	var j := PState.spawn(0)
	Combat.apply_pickup(j, GC.R_JUMP)
	var y0 := j.y
	var peak := 0
	one(j, 0, Proto.BTN_JUMP | Proto.BTN_JUMP_HELD)
	for i in 200:
		one(j, 0, Proto.BTN_JUMP_HELD)
		peak = maxi(peak, y0 - j.y)
	check(peak / PX >= 175 and peak / PX <= 200, "высота прыжка с руной %d px" % [peak / PX])
	var e := PState.spawn(0)
	Combat.apply_pickup(e, GC.R_SPEED)
	e.buffs[GC.R_SPEED] = 2
	sim(e, 3)
	check(e.buffs[GC.R_SPEED] == 0, "эффект заканчивается по таймеру")


func t_rune_combat() -> void:
	var p := pair(30)
	Combat.apply_pickup(p[0], GC.R_DAMAGE)
	one(p[0], 0, Proto.BTN_LIGHT)
	Combat.resolve_hits(players(p[0], p[1]), 1, {}, {})
	check(p[1].hp == 100 - GC.LIGHT_DAMAGE * 130 / 100, "урон +30%%: hp %d" % p[1].hp)
	var q := pair(30)
	Combat.apply_pickup(q[1], GC.R_ARMOR)
	one(q[0], 0, Proto.BTN_LIGHT)
	Combat.resolve_hits(players(q[0], q[1]), 1, {}, {})
	check(q[1].hp == 100 - GC.LIGHT_DAMAGE * 70 / 100, "броня: hp %d" % q[1].hp)
	var k := pair(30)
	Combat.apply_pickup(k[0], GC.R_KNOCKBACK)
	one(k[0], 0, Proto.BTN_LIGHT)
	Combat.resolve_hits(players(k[0], k[1]), 1, {}, {})
	check(k[1].vx == GC.LIGHT_KB_X * 130 / 100, "отталкивание +30%%: %d" % k[1].vx)
	var st := pair(30)
	Combat.apply_pickup(st[1], GC.R_STEADY)
	one(st[0], 0, Proto.BTN_LIGHT)
	Combat.resolve_hits(players(st[0], st[1]), 1, {}, {})
	check(st[1].vx == GC.LIGHT_KB_X * 70 / 100, "устойчивость: %d" % st[1].vx)


func t_rune_vampire() -> void:
	var p := pair(30)
	p[0].hp = 50
	Combat.apply_pickup(p[0], GC.R_VAMPIRE)
	one(p[0], 0, Proto.BTN_HEAVY)
	sim(p[0], 18)
	Combat.resolve_hits(players(p[0], p[1]), 1, {}, {})
	check(p[0].hp == 50 + GC.HEAVY_DAMAGE * 30 / 100, "вампиризм: hp %d" % p[0].hp)
	var full := pair(30)
	Combat.apply_pickup(full[0], GC.R_VAMPIRE)
	one(full[0], 0, Proto.BTN_LIGHT)
	Combat.resolve_hits(players(full[0], full[1]), 1, {}, {})
	check(full[0].hp == 100, "лечение не выше 100")


func t_rune_debuffs() -> void:
	var p := pair(30)
	Combat.apply_pickup(p[0], GC.R_SLOWHIT)
	one(p[0], 0, Proto.BTN_LIGHT)
	Combat.resolve_hits(players(p[0], p[1]), 1, {}, {})
	check(p[1].slow == GC.DEBUFF_TICKS and p[1].invert == 0, "замедление наложено")
	var v: PState = p[1]
	v.stun = 0
	v.vx = 0
	v.on_ground = true
	v.y = 460 * PX
	v.vy = 0
	sim(v, 20, 127)
	check(v.vx == GC.RUN_MAX * GC.SLOW_SPEED_PCT / 100, "скорость замедленного %d" % v.vx)
	check(v.buff_mask() & (1 << 11) != 0 and v.flag_byte() & 128 != 0, "дебафф виден в маске и флагах")
	var q := pair(30)
	Combat.apply_pickup(q[0], GC.R_INVERTHIT)
	one(q[0], 0, Proto.BTN_LIGHT)
	Combat.resolve_hits(players(q[0], q[1]), 1, {}, {})
	var w: PState = q[1]
	w.stun = 0
	w.vx = 0
	w.on_ground = true
	w.y = 460 * PX
	w.vy = 0
	sim(w, 20, 127)
	check(w.vx == -GC.RUN_MAX and w.facing == -1, "управление инвертировано: vx=%d" % w.vx)
	sim(w, GC.DEBUFF_TICKS, 0)
	sim(w, 20, 127)
	check(w.vx == GC.RUN_MAX, "дебафф закончился")


func t_rune_health() -> void:
	var s := PState.spawn(0)
	check(not Combat.can_pickup(s, GC.R_HEALTH), "при полном HP не берётся")
	s.hp = 50
	check(Combat.can_pickup(s, GC.R_HEALTH), "при неполном берётся")
	Combat.apply_pickup(s, GC.R_HEALTH)
	check(s.hp == 80 and s.buffs[GC.R_HEALTH] == 0, "лечит на 30, таймера нет: hp %d" % s.hp)
	s.hp = 90
	Combat.apply_pickup(s, GC.R_HEALTH)
	check(s.hp == 100, "не выше 100")
	check(Combat.can_pickup(s, GC.R_SPEED), "остальные руны берутся при полном HP")


func t_rune_cap() -> void:
	var s := PState.spawn(0)
	Combat.apply_pickup(s, GC.R_SPEED)
	Combat.apply_pickup(s, GC.R_JUMP)
	Combat.apply_pickup(s, GC.R_DAMAGE)
	s.buffs[GC.R_JUMP] = 100          # самая короткая
	Combat.apply_pickup(s, GC.R_VAMPIRE)
	check(s.buffs[GC.R_JUMP] == 0 and s.buffs[GC.R_VAMPIRE] == GC.BUFF_TICKS, "вытеснена самая короткая")
	var active := 0
	for i in GC.NUM_RUNES:
		if s.buffs[i] > 0:
			active += 1
	check(active == 3, "активных %d" % active)
	s.buffs[GC.R_SPEED] = 50
	Combat.apply_pickup(s, GC.R_SPEED)
	check(s.buffs[GC.R_SPEED] == GC.BUFF_TICKS, "повтор обновляет таймер без вытеснения")
	Combat.apply_pickup(s, GC.R_CHAOS)
	check(s.buffs[GC.R_CHAOS] == GC.CHAOS_TICKS, "«случайность» длится 30 с")


func t_pickup() -> void:
	var s := PState.spawn(0)
	var dead := PState.spawn(1)
	dead.alive = false
	var runes := [{"id": 7, "type": GC.R_SPEED, "x": s.x, "y": s.y}, {"id": 8, "type": GC.R_JUMP, "x": 100 * PX, "y": 460 * PX}]
	var ev := Combat.resolve_pickups({0: s, 1: dead}, runes)
	check(ev.size() == 1 and ev[0]["kind"] == GC.EV_PICKUP and ev[0]["a"] == 0 and ev[0]["b"] == GC.R_SPEED and ev[0]["v"] == 7, "событие PICKUP: %s" % str(ev))
	check(runes.size() == 1 and runes[0]["id"] == 8, "подобранная убрана, дальняя осталась")
	check(s.buffs[GC.R_SPEED] == GC.BUFF_TICKS, "эффект применён")
	var onlydead := [{"id": 9, "type": GC.R_SPEED, "x": dead.x, "y": dead.y}]
	check(Combat.resolve_pickups({1: dead}, onlydead).is_empty() and onlydead.size() == 1, "мёртвый не подбирает")
	var hp_full := [{"id": 10, "type": GC.R_HEALTH, "x": s.x, "y": s.y}]
	check(Combat.resolve_pickups({0: s}, hp_full).is_empty() and hp_full.size() == 1, "руна здоровья остаётся при полном HP")


# ------------------------------------------------------------------ детерминизм

func t_determinism() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var a := PState.spawn(0)
	var b := PState.spawn(0)
	for i in 5000:
		var axis := rng.randi_range(-127, 127) if rng.randf() < 0.7 else 0
		var buttons := 0
		if rng.randf() < 0.05: buttons |= Proto.BTN_JUMP
		if rng.randf() < 0.5: buttons |= Proto.BTN_JUMP_HELD
		if rng.randf() < 0.03: buttons |= Proto.BTN_DASH
		if rng.randf() < 0.04: buttons |= Proto.BTN_LIGHT
		if rng.randf() < 0.02: buttons |= Proto.BTN_HEAVY
		if rng.randf() < 0.02: buttons |= Proto.BTN_DOWN
		PlatSim.step(a, axis, buttons)
		PlatSim.step(b, axis, buttons)
		if not a.alive:
			a = PState.spawn(0)
			b = PState.spawn(0)
		if i % 500 == 0:
			Combat.apply_pickup(a, rng.randi() % GC.NUM_RUNES)
			b = a.copy()
	check(a.equals(b), "состояния разошлись")
