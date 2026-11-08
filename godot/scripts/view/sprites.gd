class_name Sprites
extends RefCounted
## Спрайты персонажей и биты (пиксель-арт, один лист assets/sprites/characters.png, 41x32 px).
## Лист: 4 персонажа 6x13 px (в листе слева направо: синий, красный, зелёный, жёлтый; смотрят ВЛЕВО, один кадр) и бита 3x11 px
## (рукоять внизу). Персонаж рисуется в 4 раза крупнее (24x52 px — как прежняя капсула), бита — в 3 раза (9x33 px).
## Если файл не найден или спрайты выключены (настройка «Модели», F6, --sprites=0), игра рисует прежние фигуры (PlayerDraw).
## Загрузка идёт напрямую из PNG (Image.load_from_file), поэтому не зависит от кэша импорта Godot (.godot, *.import).

const PATH := "res://assets/sprites/characters.png"
const CHAR_SCALE := 4.0
const BAT_SCALE := 3.0
const CHAR_SIZE := Vector2i(6, 13)
const CHAR_X := [13, 4, 22, 31]            # X на листе для цветов игры GC.COLORS: красный, синий, зелёный, жёлтый
const CHAR_Y := 4
const BAT_RECT := Rect2i(4, 19, 3, 11)

static var enabled := true                 # настройка «Модели персонажей» (F6)
static var _tried := false
static var _tex: Texture2D = null
static var _sil: Texture2D = null          # белые силуэты тех же форм — для «призрака» сервера (красится через modulate)


static func available() -> bool:
	_load()
	return _tex != null


static func active() -> bool:
	return enabled and available()


static func texture() -> Texture2D:
	_load()
	return _tex


static func silhouette() -> Texture2D:
	_load()
	return _sil


## Индекс цвета игры (GC.COLORS) для произвольного Color: ближайший по RGB.
static func color_index(c: Color) -> int:
	var best := 0
	var best_d := 1e9
	for i in GC.COLORS.size():
		var k: Color = GC.COLORS[i]
		var d := (k.r - c.r) * (k.r - c.r) + (k.g - c.g) * (k.g - c.g) + (k.b - c.b) * (k.b - c.b)
		if d < best_d:
			best_d = d
			best = i
	return best


static func char_rect(color_idx: int) -> Rect2:
	return Rect2(float(CHAR_X[clampi(color_idx, 0, CHAR_X.size() - 1)]), float(CHAR_Y), float(CHAR_SIZE.x), float(CHAR_SIZE.y))


## Рисует персонажа: pos — «ноги» (px), f — взгляд (+1 вправо), scale.x/y — растяжение, rot — наклон при беге.
## tex — обычная текстура листа или силуэт; mod — modulate (цвет/прозрачность/вспышка).
static func draw_char(ci: CanvasItem, tex: Texture2D, color_idx: int, pos: Vector2, f: int, sx: float, sy: float, rot: float, mod: Color) -> void:
	var flip := -1.0 if f > 0 else 1.0                   # на листе персонаж смотрит влево
	ci.draw_set_transform(pos, rot, Vector2(flip * sx, sy))
	var w := float(CHAR_SIZE.x) * CHAR_SCALE
	var h := float(CHAR_SIZE.y) * CHAR_SCALE
	ci.draw_texture_rect_region(tex, Rect2(-w * 0.5, -h, w, h), char_rect(color_idx), mod)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Бита: hand — рука (рукоять), dir — направление от руки к концу (единичный вектор).
static func draw_bat(ci: CanvasItem, hand: Vector2, dir: Vector2, mod: Color) -> void:
	var tex := texture()
	var theta := atan2(dir.x, -dir.y)                    # на листе бита направлена вверх
	ci.draw_set_transform(hand, theta, Vector2.ONE)
	var w := float(BAT_RECT.size.x) * BAT_SCALE
	var h := float(BAT_RECT.size.y) * BAT_SCALE
	ci.draw_texture_rect_region(tex, Rect2(-w * 0.5, -h, w, h), Rect2(BAT_RECT), mod)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


static func _load() -> void:
	if _tried:
		return
	_tried = true
	var img := Image.load_from_file(PATH)
	if img == null or img.is_empty():
		var res = load(PATH) if ResourceLoader.exists(PATH) else null
		if res is Texture2D:
			img = (res as Texture2D).get_image()
	if img == null or img.is_empty():
		push_warning("Sprites: не удалось загрузить %s — рисуем фигурами" % PATH)
		return
	img.convert(Image.FORMAT_RGBA8)
	_tex = ImageTexture.create_from_image(img)
	var s := img.duplicate() as Image
	for y in s.get_height():
		for x in s.get_width():
			var p := s.get_pixel(x, y)
			if p.a > 0.0:
				s.set_pixel(x, y, Color(1, 1, 1, p.a))
	_sil = ImageTexture.create_from_image(s)
