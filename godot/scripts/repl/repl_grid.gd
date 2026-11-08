class_name ReplGrid
extends RefCounted
## Grid Spatialization (аналог узла GridSpatialization2D из Replication Graph): мир делится на ячейки,
## актор живёт в одной ячейке, а запрос «кто рядом с клиентом» просматривает только несколько ячеек,
## а не все акторы мира. Движущиеся акторы перекладываются между ячейками при смене ячейки.

var cell := ReplDefs.CELL_PX
var _cells := {}        # ключ ячейки -> {id: true}
var _cell_of := {}      # id -> ключ ячейки
var cells_visited := 0  # сколько ячеек просмотрено запросами (для профиля)


func _key(x: float, y: float) -> int:
	return int(floorf(x / cell)) + 1000 * int(floorf(y / cell))


func insert(id: int, x: float, y: float) -> void:
	remove(id)
	var k := _key(x, y)
	if not _cells.has(k):
		_cells[k] = {}
	_cells[k][id] = true
	_cell_of[id] = k


func move(id: int, x: float, y: float) -> void:
	var k := _key(x, y)
	if _cell_of.get(id, -999999) == k:
		return
	insert(id, x, y)


func remove(id: int) -> void:
	if not _cell_of.has(id):
		return
	var k: int = _cell_of[id]
	_cell_of.erase(id)
	if _cells.has(k):
		(_cells[k] as Dictionary).erase(id)
		if (_cells[k] as Dictionary).is_empty():
			_cells.erase(k)


## id всех акторов в ячейках, пересекающих полосу x0..x1 (по всей высоте мира). Это надмножество: точный отбор делает релевантность.
func query_x_range(x0: float, x1: float) -> Array:
	var out: Array = []
	var cx0 := int(floorf(x0 / cell))
	var cx1 := int(floorf(x1 / cell))
	var rows := int(floorf(1000.0 / cell)) + 1
	for cy in rows:
		for cx in range(cx0, cx1 + 1):
			cells_visited += 1
			var k := cx + 1000 * cy
			if _cells.has(k):
				out.append_array((_cells[k] as Dictionary).keys())
	return out


func size() -> int:
	return _cell_of.size()
