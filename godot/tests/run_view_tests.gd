extends SceneTree
## Тесты спрайтов персонажей и биты (лист assets/sprites/characters.png): загрузка, раскладка, соответствие цветов, силуэт, переключатель.
##   godot --headless --path godot -s res://tests/run_view_tests.gd

var passed := 0
var failed := 0
var current := ""


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
	print("== Спрайты ==")
	run("лист загружается: 41x32, есть силуэт", t_load)
	run("4 персонажа 6x13 и бита 3x11: области внутри листа и не пустые", t_regions)
	run("цвета листа соответствуют цветам игры (красный, синий, зелёный, жёлтый)", t_colors)
	run("силуэт: те же пиксели, цвет белый", t_silhouette)
	run("переключатель Sprites.enabled", t_toggle)
	print("\n%d тестов, %d провалено" % [passed + failed, failed])
	quit(1 if failed > 0 else 0)


func _img() -> Image:
	return Sprites.texture().get_image()


func t_load() -> void:
	check(Sprites.available(), "лист не найден")
	check(Sprites.texture().get_size() == Vector2(41, 32), "размер %s" % str(Sprites.texture().get_size()))
	check(Sprites.silhouette() != null and Sprites.silhouette().get_size() == Sprites.texture().get_size(), "силуэт")


func _opaque_count(img: Image, r: Rect2i) -> int:
	var n := 0
	for y in range(r.position.y, r.position.y + r.size.y):
		for x in range(r.position.x, r.position.x + r.size.x):
			if img.get_pixel(x, y).a > 0.0:
				n += 1
	return n


func t_regions() -> void:
	var img := _img()
	for i in GC.COLORS.size():
		var r := Sprites.char_rect(i)
		check(r.position.x >= 0 and r.end.x <= 41 and r.position.y >= 0 and r.end.y <= 32, "персонаж %d выходит за лист" % i)
		check(_opaque_count(img, Rect2i(r)) > 40, "персонаж %d пустой" % i)
	check(_opaque_count(img, Sprites.BAT_RECT) > 15, "бита пустая")
	# области персонажей не пересекаются с битой
	for i in GC.COLORS.size():
		check(not Sprites.char_rect(i).intersects(Rect2(Sprites.BAT_RECT)), "персонаж %d пересекается с битой" % i)


func _dominant(img: Image, r: Rect2) -> Color:
	var c := Color(0, 0, 0)
	var n := 0
	for y in range(int(r.position.y), int(r.end.y)):
		for x in range(int(r.position.x), int(r.end.x)):
			var p := img.get_pixel(x, y)
			if p.a > 0.0 and p.get_luminance() > 0.12:
				c += p
				n += 1
	return c / float(maxi(n, 1))


func t_colors() -> void:
	var img := _img()
	# спрайт i должен быть «похож» на GC.COLORS[i] сильнее, чем на остальные цвета
	for i in GC.COLORS.size():
		var avg := _dominant(img, Sprites.char_rect(i))
		check(Sprites.color_index(avg) == i, "спрайт %d ближе к цвету %d" % [i, Sprites.color_index(avg)])
		check(Sprites.color_index(GC.COLORS[i]) == i, "цвет %d сопоставляется сам с собой" % i)


func t_silhouette() -> void:
	var a := _img()
	var s := Sprites.silhouette().get_image()
	var same := true
	var white := true
	for y in a.get_height():
		for x in a.get_width():
			var pa := a.get_pixel(x, y)
			var ps := s.get_pixel(x, y)
			if (pa.a > 0.0) != (ps.a > 0.0):
				same = false
			if ps.a > 0.0 and not (ps.r > 0.99 and ps.g > 0.99 and ps.b > 0.99):
				white = false
	check(same, "форма силуэта совпадает со спрайтом")
	check(white, "силуэт белый")


func t_toggle() -> void:
	Sprites.enabled = true
	check(Sprites.active(), "включено")
	Sprites.enabled = false
	check(not Sprites.active(), "выключено")
	Sprites.enabled = true
