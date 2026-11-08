class_name ReplDefs
extends RefCounted
## ПР №5 «Оптимизация репликации». Константы мира-нагрузки, классы акторов и их сетевые параметры.
## Названия повторяют Unreal Engine (NetUpdateFrequency, NetPriority, NetCullDistance, dormancy), чтобы работу
## было легко сопоставить с условием: в Godot своего механизма репликации с такими настройками нет, поэтому он написан
## поверх собственного UDP-протокола ПР №1–3 (пакеты T_WORLD_UPDATE / T_WORLD_RELIABLE).

# --- мир (px, px/с); «уровень» — длинный платформер с боковой прокруткой ---
const WORLD_W_PX := 16000.0
const GROUND_Y_PX := 700.0
const VIEW_HALF_W := 640.0          # камера: окно 1280 px вокруг своего персонажа
const WORLD_HZ := 60                # частота симуляции мира
const NET_HZ := 30                  # NetServerMaxTickRate: частота сетевых тиков (раз в NET_EVERY тиков мира)
const NET_EVERY := 2
const MAX_UPDATE_PAYLOAD := 1100    # байт полезной нагрузки в одной датаграмме (в MTU 1500 с запасом)
const KEYFRAME_NET_TICKS := 30      # раз в секунду полное состояние живого актора (лечит потерянные дельты)

# --- классы акторов ---
const C_PLAYER := 0
const C_TREE := 1
const C_PICKUP := 2
const C_BOT := 3
const C_PROJ := 4
const C_CLOUD := 5
const NUM_CLASSES := 6
const CLASS_KEYS := ["player", "tree", "pickup", "bot", "projectile", "cloud"]
const CLASS_NAMES := ["Игрок", "Дерево (декор)", "Предмет", "Бот", "Снаряд", "Облако (фон)"]

# --- поля состояния актора (маска изменённых полей, push-модель) ---
const F_X := 1
const F_Y := 2
const F_VX := 4
const F_VY := 8
const F_ST := 16        # флаги состояния (анимация, «взят», направление)
const F_HP := 32
const F_ALL := 63
const FIELD_NAMES := ["x", "y", "vx", "vy", "st", "hp"]

# --- формат пакетов ---
const FMT_DELTA := 1    # в записи есть маска и только изменённые поля (push-based)
const FMT_QUANT := 2    # позиции u16 (0,25 px), скорости i8 (8 px/с) вместо float32
const OP_UPSERT := 0    # создать актор / обновить его полное состояние (появление и «пробуждение» спящего)
const OP_DESTROY := 2
const DESTROY_REMOVED := 0      # актор уничтожен на сервере
const DESTROY_IRRELEVANT := 1   # актор ушёл из зоны релевантности клиента

# --- сетевые параметры классов; порядок: player, tree, pickup, bot, projectile, cloud ---
const NAIVE_HZ := 30                              # «до»: всё обновляется с максимальной частотой
const OPT_HZ := [30, 2, 5, 30, 30, 5]             # NetUpdateFrequency: фон и декор — реже, игровое — как было
const PRIORITY := [3.0, 0.2, 1.0, 2.0, 2.5, 0.3]  # NetPriority
const CULL_PX := [0.0, 1000.0, 1100.0, 1400.0, 1400.0, 1000.0]   # радиус релевантности по X (0 — всегда релевантен)
const BACK_FACTOR := [1.0, 0.75, 0.75, 1.0, 1.0, 0.75]          # IsNetRelevantFor: «за спиной» радиус меньше (враги и снаряды — нет)
const CAN_SLEEP := [false, true, true, false, false, false]    # статика: DORM_Initial
const HYST_PX := 120.0                            # гистерезис выхода из зоны релевантности
const CELL_PX := 500.0                            # ячейка Grid Spatialization

# --- квантование (аналог FVector_NetQuantize) ---
const POS_STEP := 0.25      # px; u16 покрывает 0…16383 px
const VEL_STEP := 8.0       # px/с; i8 покрывает ±1016 px/с


static func q_pos(v: float) -> int:
	return clampi(roundi(v / POS_STEP), 0, 65535)


static func dq_pos(q: int) -> float:
	return float(q) * POS_STEP


static func q_vel(v: float) -> int:
	return clampi(roundi(v / VEL_STEP), -127, 127)


static func dq_vel(q: int) -> float:
	return float(q) * VEL_STEP


## Период обновления класса в сетевых тиках (при выключенной оптимизации частот — каждый тик).
static func period_net_ticks(cls: int, use_freq: bool) -> int:
	if not use_freq:
		return 1
	return maxi(1, roundi(float(NET_HZ) / float(OPT_HZ[cls])))


## Размер на проводе: 28 байт IPv4+UDP и 8 байт заголовка протокола — как считает NetNode.
const WIRE_OVERHEAD := 28 + 8
