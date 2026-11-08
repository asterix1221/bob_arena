class_name DashRules
extends RefCounted
## Правила рывка (dash) — чистая логика без Node/сети/часов.
## Один и тот же код исполняют сервер (авторитет) и клиент (предсказание).
## Всё считается в ТИКАХ фиксированного шага, поэтому повтор команд на клиенте после
## коррекции даёт результат, побитово совпадающий с серверной симуляцией.

const REASON_NONE := ""
const REASON_ALREADY := "already_dashing"
const REASON_COOLDOWN := "cooldown"
const REASON_STAMINA := "no_stamina"


static func default_cfg() -> Dictionary:
	return {
		"walk_speed": 220.0,        # px/s
		"dash_speed": 900.0,        # px/s
		"dash_ticks": 11,           # ~0.18 c при 60 Гц
		"cooldown_ticks": 72,       # 1.2 c между стартами рывков
		"stamina_max": 100.0,
		"stamina_cost": 35.0,
		"stamina_regen_per_tick": 25.0 / 60.0,
		"radius": 16.0,
	}


## Проверка допустимости рывка. Ничего не меняет, возвращает причину отказа или "".
static func validate(state: PlayerState, cfg: Dictionary) -> String:
	if state.dash_left > 0:
		return REASON_ALREADY
	if cfg.get("ignore_rules", false):
		return REASON_NONE            # ТОЛЬКО для клиентского чита в демонстрации расхождения
	if state.cooldown_left > 0:
		return REASON_COOLDOWN
	if state.stamina < cfg["stamina_cost"]:
		return REASON_STAMINA
	return REASON_NONE


## Старт рывка: только после успешной validate. Направление передаёт вызывающий (его считает сервер).
static func begin(state: PlayerState, cfg: Dictionary, dir: Vector2) -> void:
	state.stamina = maxf(0.0, state.stamina - cfg["stamina_cost"])
	state.cooldown_left = cfg["cooldown_ticks"]
	state.dash_left = cfg["dash_ticks"]
	state.dash_dir = dir
	state.dash_count += 1


## Таймеры и выносливость — после движения тика.
static func tick_timers(state: PlayerState, cfg: Dictionary, was_dashing: bool) -> void:
	if state.dash_left > 0:
		state.dash_left -= 1
	if state.cooldown_left > 0:
		state.cooldown_left -= 1
	if not was_dashing:
		state.stamina = minf(cfg["stamina_max"], state.stamina + cfg["stamina_regen_per_tick"])
