class_name GC
extends RefCounted
## Константы игры. ЕДИНИЦЫ: 1 px = 256 u (позиции), скорости в u/тик, ускорения в u/тик^2, время в тиках (120 Гц).
## Вся симуляция целочисленная: клиент и сервер получают побитно одинаковый результат на любой платформе,
## поэтому повтор команд после коррекции (reconciliation) точен, а сравнение состояний — просто сравнение байт.

const TICK_HZ := 120
const SUB := 256

# --- тело и мир (px) ---
const HALF_W_PX := 14
const HEIGHT_PX := 48
const FALL_Y_PX := 900
const PLATFORM_EDGE_PX := 4
# Платформы: [x1, x2, y_верха] в px. Все проходимы снизу и «спрыгиваемы» вниз (DOWN + прыжок).
const PLATFORMS_PX := [[340, 940, 460], [60, 300, 330], [980, 1220, 330]]
# Точки появления (низ персонажа, px): по одной на слот игрока.
const SPAWNS_PX := [[460, 460], [820, 460], [180, 330], [1100, 330]]

# --- движение (u/тик, u/тик^2) ---
const RUN_MAX := 768           # 360 px/с
const GROUND_ACC := 128
const GROUND_DEC := 192
const AIR_ACC := 64
const AIR_DEC := 24
const STUN_DRAG := 6
const GRAVITY := 43            # ~2400 px/с^2
const MAX_FALL := 2347         # ~1100 px/с
const JUMP_V := 1809           # высота ~150 px
const JUMP_CUT := 600
const COYOTE_TICKS := 10       # 83 мс
const JUMP_BUFFER_TICKS := 12  # 100 мс
const DROP_TICKS := 14

# --- рывок (ПР №4: действие, чувствительное к задержке) ---
const DASH_TICKS := 22
const DASH_SPEED := 1920       # 900 px/с
const DASH_COOLDOWN := 144     # 1.2 с
const STAMINA_MAX := 100000
const DASH_COST := 35000
const STAMINA_REGEN := 208     # ~25 ед./с (в тысячных)

# --- бой ---
const HP_MAX := 100
const LIGHT_TOTAL := 24
const LIGHT_ACTIVE_END := 6
const LIGHT_DAMAGE := 8
const LIGHT_KB_X := 811        # 380 px/с
const LIGHT_KB_Y := 533        # 250 px/с вверх
const LIGHT_STUN := 14
const LIGHT_REACH_PX := 44
const HEAVY_TOTAL := 54
const HEAVY_ACTIVE_START := 18
const HEAVY_ACTIVE_END := 24
const HEAVY_DAMAGE := 22
const HEAVY_KB_X := 1621       # 760 px/с
const HEAVY_KB_Y := 896        # 420 px/с вверх
const HEAVY_STUN := 24
const HEAVY_REACH_PX := 56
const ATTACK_COOLDOWN := 6

# --- руны ---
const R_SPEED := 0
const R_JUMP := 1
const R_DAMAGE := 2
const R_KNOCKBACK := 3
const R_VAMPIRE := 4
const R_ARMOR := 5
const R_STEADY := 6
const R_SLOWHIT := 7
const R_INVERTHIT := 8
const R_HEALTH := 9            # мгновенная, в buffs не хранится
const R_CHAOS := 10
const NUM_RUNES := 11
const BUFF_TICKS := 1800       # 15 с
const CHAOS_TICKS := 3600      # 30 с
const DEBUFF_TICKS := 480      # 4 с
const MAX_ACTIVE_BUFFS := 3
const SPEED_BONUS_PCT := 30
const JUMP_BONUS_PCT := 12     # к скорости прыжка (~+25% высоты)
const DAMAGE_BONUS_PCT := 30
const KNOCKBACK_BONUS_PCT := 30
const VAMPIRE_HEAL_PCT := 30
const ARMOR_REDUCTION_PCT := 30
const STEADY_REDUCTION_PCT := 30
const SLOW_SPEED_PCT := 65
const HEALTH_RUNE_HEAL := 30
const RUNE_HALF_PX := 14
const RUNE_SPAWN_INTERVAL := 1200   # 10 с
const MAX_RUNES_ON_GROUND := 4

# --- матч ---
const COUNTDOWN_TICKS := 360        # 3 с
const MAX_PLAYERS := 4
const PHASE_LOBBY := 0
const PHASE_COUNTDOWN := 1
const PHASE_PLAYING := 2
const PHASE_ENDED := 3

# Виды GameEvent.kind
const EV_ROUND_START := 1
const EV_HIT := 2           # a=атакующий, b=жертва, v=урон, x,y=позиция жертвы (px)
const EV_PICKUP := 3        # a=игрок, b=тип руны, v=id руны, x,y=позиция руны (px)
const EV_DEATH := 4         # a=погибший, b=убийца (255 — нет), v=причина: 0 урон, 1 падение
const EV_ROUND_END := 5     # a=победитель (255 — ничья)
const EV_COUNTDOWN := 6     # v=осталось секунд
const EV_JOINED := 7
const EV_LEFT := 8
const EV_STATS := 9          # итоги раунда по игроку: a=id, b=убийства, v=урон, x=секунд жизни, y=смертей(0/1)
const EV_LOBBY := 10         # матч закончен, возврат в лобби

const NO_PLAYER := 255

# Цвета игроков (индекс из Hello.color)
const COLORS := [Color("e5484d"), Color("3e63dd"), Color("30a46c"), Color("f5d90a")]


static var _plat_u: Array = []


## Платформы в единицах u: [[x1, x2, y], ...]
static func platforms_u() -> Array:
	if _plat_u.is_empty():
		for p in PLATFORMS_PX:
			_plat_u.append([p[0] * SUB, p[1] * SUB, p[2] * SUB])
	return _plat_u


static func spawn_u(slot: int) -> Array:
	var s: Array = SPAWNS_PX[slot % SPAWNS_PX.size()]
	return [s[0] * SUB, s[1] * SUB]
