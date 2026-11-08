class_name PlatSim
extends RefCounted
## Детерминированный шаг игрока (платформер). Одна и та же функция работает на сервере (авторитет) и на клиенте
## (предсказание своего персонажа). Здесь только то, что зависит от СОБСТВЕННОГО ввода и статического мира;
## попадания по игроку и подбор рун решает только сервер (Combat), клиент узнаёт о них из снимка.

const BTN_JUMP := Proto.BTN_JUMP
const BTN_DASH := Proto.BTN_DASH
const BTN_LIGHT := Proto.BTN_LIGHT
const BTN_HEAVY := Proto.BTN_HEAVY
const BTN_DOWN := Proto.BTN_DOWN
const BTN_JUMP_HELD := Proto.BTN_JUMP_HELD


static func _toward(v: int, target: int, step: int) -> int:
	if v < target:
		return mini(v + step, target)
	return maxi(v - step, target)


## Результат проверки рывка: "" — можно, иначе причина отказа (как в ПР №4).
static func dash_reject_reason(s: PState, stunned: bool) -> String:
	if s.dash_left > 0:
		return "already_dashing"
	if stunned:
		return "stunned"
	if s.atk_kind == 2:
		return "attacking"
	if s.dash_cd > 0:
		return "cooldown"
	if s.stamina < GC.DASH_COST:
		return "no_stamina"
	return ""


static func attack_active(s: PState) -> bool:
	if s.atk_kind == 1:
		return s.atk_tick < GC.LIGHT_ACTIVE_END
	if s.atk_kind == 2:
		return s.atk_tick >= GC.HEAVY_ACTIVE_START and s.atk_tick < GC.HEAVY_ACTIVE_END
	return false


## Один тик. axis: -127..127, buttons: маска Proto.BTN_*. Возвращает пустую строку или причину отказа рывка
## (если игрок его запросил, но правила не позволили) — сервер пишет это в лог/событие.
static func step(s: PState, axis: int, buttons: int) -> String:
	if not s.alive:
		return ""
	var reject := ""
	# 1. таймеры
	if s.stun > 0: s.stun -= 1
	if s.atk_cd > 0: s.atk_cd -= 1
	if s.dash_cd > 0: s.dash_cd -= 1
	if s.drop_t > 0: s.drop_t -= 1
	if s.jump_buf > 0: s.jump_buf -= 1
	if s.slow > 0: s.slow -= 1
	if s.invert > 0: s.invert -= 1
	for i in GC.NUM_RUNES:
		if s.buffs[i] > 0:
			s.buffs[i] -= 1
	if s.dash_left == 0:
		s.stamina = mini(s.stamina + GC.STAMINA_REGEN, GC.STAMINA_MAX)
	if s.on_ground:
		s.coyote = GC.COYOTE_TICKS
	elif s.coyote > 0:
		s.coyote -= 1

	var stunned := s.stun > 0
	var ax := clampi(axis, -127, 127)
	if stunned:
		ax = 0
	elif s.invert > 0:
		ax = -ax
	if ax != 0 and s.atk_kind != 2 and s.dash_left == 0 and not stunned:
		s.facing = 1 if ax > 0 else -1

	# 2. прыжок / спрыгивание вниз
	if buttons & BTN_JUMP:
		if (buttons & BTN_DOWN) and s.on_ground and not stunned:
			s.drop_t = GC.DROP_TICKS
			s.on_ground = false
			s.coyote = 0
			s.jump_buf = 0
		else:
			s.jump_buf = GC.JUMP_BUFFER_TICKS
	if s.jump_buf > 0 and (s.on_ground or s.coyote > 0) and not stunned and s.dash_left == 0:
		var jv := GC.JUMP_V
		if s.buffs[GC.R_JUMP] > 0:
			jv = jv * (100 + GC.JUMP_BONUS_PCT) / 100
		s.vy = -jv
		s.on_ground = false
		s.jumping = true
		s.coyote = 0
		s.jump_buf = 0

	# 3. рывок
	if buttons & BTN_DASH:
		reject = dash_reject_reason(s, stunned)
		if reject == "":
			s.dash_left = GC.DASH_TICKS
			s.dash_cd = GC.DASH_COOLDOWN
			s.stamina -= GC.DASH_COST
			s.dash_dir = (1 if ax > 0 else -1) if ax != 0 else s.facing
			s.facing = s.dash_dir
			s.atk_kind = 0
			s.atk_tick = 0

	# 4. горизонтальная скорость
	var dashing := s.dash_left > 0
	if dashing:
		s.vx = s.dash_dir * GC.DASH_SPEED
		s.vy = 0
		s.dash_left -= 1
	elif stunned:
		s.vx = _toward(s.vx, 0, GC.STUN_DRAG)
	else:
		var max_speed := GC.RUN_MAX
		if s.buffs[GC.R_SPEED] > 0:
			max_speed = max_speed * (100 + GC.SPEED_BONUS_PCT) / 100
		if s.slow > 0:
			max_speed = max_speed * GC.SLOW_SPEED_PCT / 100
		if s.atk_kind == 2:
			max_speed = max_speed * 30 / 100
		var target := ax * max_speed / 127
		var acc: int
		if target == 0:
			acc = GC.GROUND_DEC if s.on_ground else GC.AIR_DEC
		else:
			acc = GC.GROUND_ACC if s.on_ground else GC.AIR_ACC
			if (s.vx > 0 and target < 0) or (s.vx < 0 and target > 0):
				acc *= 2
		s.vx = _toward(s.vx, target, acc)

	# 5. вертикаль
	if not dashing:
		s.vy = mini(s.vy + GC.GRAVITY, GC.MAX_FALL)
		if s.jumping:
			if s.vy >= 0:
				s.jumping = false
			elif not (buttons & BTN_JUMP_HELD) and s.vy < -GC.JUMP_CUT:
				s.vy = -GC.JUMP_CUT
				s.jumping = false

	# 6. перемещение и посадка на платформы (односторонние: только сверху)
	var prev_bottom := s.y
	s.x += s.vx
	s.y += s.vy
	s.on_ground = false
	if s.vy >= 0 and s.drop_t == 0:
		var edge := GC.PLATFORM_EDGE_PX * GC.SUB
		for p in GC.platforms_u():
			if s.x >= p[0] - edge and s.x <= p[1] + edge and prev_bottom <= p[2] and s.y >= p[2]:
				s.y = p[2]
				s.vy = 0
				s.on_ground = true
				s.jumping = false
				break
	if s.y > GC.FALL_Y_PX * GC.SUB:
		s.alive = false

	# 7. атака: продвинуть текущую, затем начать новую (первый активный кадр — в тот же тик)
	if s.atk_kind != 0:
		s.atk_tick += 1
		var total := GC.LIGHT_TOTAL if s.atk_kind == 1 else GC.HEAVY_TOTAL
		if s.atk_tick >= total:
			s.atk_kind = 0
			s.atk_tick = 0
			s.atk_cd = GC.ATTACK_COOLDOWN
	if s.atk_kind == 0 and s.atk_cd == 0 and not stunned and not dashing and s.alive:
		if buttons & BTN_HEAVY:
			s.atk_kind = 2
			s.atk_tick = 0
			s.hit_mask = 0
		elif buttons & BTN_LIGHT:
			s.atk_kind = 1
			s.atk_tick = 0
			s.hit_mask = 0
	return reject
