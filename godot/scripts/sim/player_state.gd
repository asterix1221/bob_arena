class_name PlayerState
extends RefCounted
## Полное состояние игрока в симуляции. Вся «скрытая» информация (таймеры рывка, выносливость)
## лежит здесь и целиком уходит клиенту в снимке — поэтому после коррекции повтор команд точный.

var pos := Vector2.ZERO
var facing := Vector2.RIGHT
var dash_left := 0            # тиков до конца рывка
var dash_dir := Vector2.RIGHT
var cooldown_left := 0        # тиков до разрешения нового рывка
var stamina := 100.0
var dash_count := 0           # сколько рывков ПРИНЯТО (счётчик; растёт и у клиента при предсказании)


func duplicate_state() -> PlayerState:
	var s := PlayerState.new()
	s.pos = pos
	s.facing = facing
	s.dash_left = dash_left
	s.dash_dir = dash_dir
	s.cooldown_left = cooldown_left
	s.stamina = stamina
	s.dash_count = dash_count
	return s


func to_dict() -> Dictionary:
	return {"pos": pos, "facing": facing, "dash_left": dash_left, "dash_dir": dash_dir,
		"cooldown_left": cooldown_left, "stamina": stamina, "dash_count": dash_count}


static func from_dict(d: Dictionary) -> PlayerState:
	var s := PlayerState.new()
	s.pos = d["pos"]
	s.facing = d["facing"]
	s.dash_left = d["dash_left"]
	s.dash_dir = d["dash_dir"]
	s.cooldown_left = d["cooldown_left"]
	s.stamina = d["stamina"]
	s.dash_count = d["dash_count"]
	return s


## Совпадают ли два состояния (позиции — с допуском в пикселях).
func matches(other: PlayerState, eps: float = 0.01) -> bool:
	return pos.distance_to(other.pos) <= eps \
		and dash_left == other.dash_left \
		and cooldown_left == other.cooldown_left \
		and absf(stamina - other.stamina) <= 0.01
