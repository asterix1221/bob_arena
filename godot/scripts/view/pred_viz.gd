class_name PredViz
extends RefCounted
## Визуализация клиентского предсказания (ПР №4). Только отрисовка: состояние симуляции не меняется.
## Режимы (настройка в меню/паузе и клавиша F8):
##   OFF    — как в обычной игре;
##   GHOST  — рядом с вашим персонажем виден полупрозрачный оранжевый «призрак»: ПОСЛЕДНЕЕ АВТОРИТЕТНОЕ положение от сервера
##            (отстаёт на ≈ RTT/2 + интервал снимков; чем больше лаг, тем дальше он от вас);
##   FADED  — ваш (предсказанный) персонаж полупрозрачный, подтверждённое сервером положение — плотнее;
##   FULL   — оба + путь ещё не подтверждённых команд (точка на каждую), линия «опережения» и подписи.
## Красное кольцо в любом режиме кроме OFF — клиент только что получил коррекцию и переиграл команды.

const OFF := 0
const GHOST := 1
const FADED := 2
const FULL := 3
const NAMES := ["Выкл", "Призрак сервера", "Предсказанный полупрозрачный", "Полная (путь и ошибка)"]
const SERVER_COLOR := Color("ffb347")
const FLASH_MS := 700.0
const PRED_ALPHA_FADED := 0.45


## Прозрачность локального (предсказанного) персонажа в данном режиме.
static func local_alpha(mode: int) -> float:
	return PRED_ALPHA_FADED if (mode == FADED or mode == FULL) else 1.0


static func _server_alpha(mode: int) -> float:
	match mode:
		GHOST: return 0.42
		FADED: return 0.85
		FULL: return 0.6
	return 0.0


## Под персонажем: серверный «призрак» и путь неподтверждённых команд.
static func draw_under(ci: CanvasItem, c: GameClient, mode: int) -> void:
	if mode == OFF or c == null or c.last_server_state == null or c.phase != GC.PHASE_PLAYING:
		return
	var s: PState = c.last_server_state
	if not s.alive:
		return
	var pos := Vector2(s.x, s.y) / float(GC.SUB)
	if mode == FULL:
		var path := c.pending_path()
		if path.size() >= 2:
			var pts := PackedVector2Array()
			for q in path:
				pts.append(q + Vector2(0, -24))
			ci.draw_polyline(pts, Color(1, 1, 1, 0.55), 2.0)
			for i in range(1, pts.size()):
				ci.draw_circle(pts[i], 2.4, Color(1, 1, 1, 0.85))
	var col := Color(SERVER_COLOR.r, SERVER_COLOR.g, SERVER_COLOR.b, _server_alpha(mode))
	PlayerDraw.draw_silhouette(ci, pos, s.facing, col, s.dash_left > 0)


## Поверх персонажа: линия опережения, подписи, кольцо коррекции, легенда.
## me — положение «ног» предсказанного персонажа, как он нарисован (с учётом сглаживания).
static func draw_over(ci: CanvasItem, c: GameClient, mode: int, font: Font, me: Vector2, now_ms: float, flash_t0_ms: float, flash_pos: Vector2) -> void:
	if mode == OFF or c == null or c.phase != GC.PHASE_PLAYING:
		return
	if c.last_server_state != null and c.last_server_state.alive and mode == FULL:
		var sp := Vector2(c.last_server_state.x, c.last_server_state.y) / float(GC.SUB)
		ci.draw_line(sp + Vector2(0, -24), me + Vector2(0, -24), Color(1, 1, 1, 0.45), 1.0)
		ci.draw_string(font, sp + Vector2(18, -52), "сервер", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, SERVER_COLOR)
		ci.draw_string(font, me + Vector2(18, 16), "клиент (+%.0f px, %d команд)" % [c.prediction_lead_px(), c.pending.size()], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.9))
	if flash_t0_ms >= 0.0:
		var age := now_ms - flash_t0_ms
		if age >= 0.0 and age < FLASH_MS:
			var k := 1.0 - age / FLASH_MS
			ci.draw_arc(flash_pos + Vector2(0, -24), 30.0 + age * 0.05, 0.0, TAU, 32, Color(1.0, 0.25, 0.2, k), 3.5)
	_legend(ci, font, mode)


static func _legend(ci: CanvasItem, font: Font, mode: int) -> void:
	var x := 18.0
	var y := 64.0           # под строкой «Пинг», не перекрывает полоску здоровья
	ci.draw_rect(Rect2(x - 8, y - 22, 330, 74), Color(0, 0, 0, 0.45))
	ci.draw_string(font, Vector2(x, y - 6), "Визуализация предсказания [F8]: %s" % NAMES[mode], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.95))
	ci.draw_circle(Vector2(x + 6, y + 12), 6.0, Color(1, 1, 1, PRED_ALPHA_FADED if (mode == FADED or mode == FULL) else 1.0))
	ci.draw_string(font, Vector2(x + 20, y + 17), "ваш персонаж: предсказан клиентом", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.85))
	ci.draw_circle(Vector2(x + 6, y + 30), 6.0, Color(SERVER_COLOR.r, SERVER_COLOR.g, SERVER_COLOR.b, 0.8))
	ci.draw_string(font, Vector2(x + 20, y + 35), "оранжевый: положение по серверу", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.85))
	ci.draw_arc(Vector2(x + 6, y + 48), 6.0, 0.0, TAU, 16, Color(1.0, 0.25, 0.2), 2.0)
	ci.draw_string(font, Vector2(x + 20, y + 52), "красное кольцо: коррекция", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.85))
