class_name ReplCfg
extends RefCounted
## Набор включённых оптимизаций репликации. Все выключены = «до» (наивная репликация: всё, всем, полным состоянием, float32,
## 30 Гц). Каждый флаг независим — поэтому в отчёте есть и вклад каждой техники отдельно, и накопительные наборы.

var name := "baseline"
var relevancy := false          # Replication Graph: Grid Spatialization + радиус релевантности (NetCullDistance)
var custom_relevance := false   # IsNetRelevantFor: направление «взгляда» (за спиной радиус меньше) и гистерезис; нужен relevancy
var dormancy := false           # Net Dormancy: статичные акторы спят (DORM_Initial), изменения — надёжным «пробуждением»
var push := false               # Push-based: в пакете только изменённые («грязные») поля по маске
var quantize := false           # FVector_NetQuantize: позиции u16 (0,25 px), скорости i8
var freq := false               # NetUpdateFrequency по классам + разнесение обновлений по тикам (frequency buckets)
var priority := false           # NetPriority: при нехватке бюджета важное (враги, снаряды) обновляется первым
var budget_bytes := 0           # бюджет на сетевой тик на клиента (0 — без ограничения)
var keyframe_net_ticks := ReplDefs.KEYFRAME_NET_TICKS


static func baseline() -> ReplCfg:
	return ReplCfg.new()


static func optimized() -> ReplCfg:
	var c := ReplCfg.new()
	c.name = "optimized"
	c.relevancy = true
	c.custom_relevance = true
	c.dormancy = true
	c.push = true
	c.quantize = true
	c.freq = true
	c.priority = true
	c.budget_bytes = 1000
	return c


## Ключи техник в порядке отчёта.
const TECH_KEYS := ["relevancy", "custom_relevance", "dormancy", "push", "quantize", "freq", "priority"]
const TECH_NAMES := {
	"relevancy": "Replication Graph (сетка + релевантность)",
	"custom_relevance": "IsNetRelevantFor (направление, гистерезис)",
	"dormancy": "Net Dormancy",
	"push": "Push-based (только изменённые поля)",
	"quantize": "Квантование (NetQuantize)",
	"freq": "NetUpdateFrequency по классам",
	"priority": "NetPriority + бюджет",
}


func get_flag(key: String) -> bool:
	return bool(get(key))


func set_flag(key: String, v: bool) -> void:
	set(key, v)
	if key == "priority" and v and budget_bytes == 0:
		budget_bytes = 1000
	if key == "priority" and not v:
		budget_bytes = 0


func active() -> Array:
	var out: Array = []
	for k in TECH_KEYS:
		if get_flag(k):
			out.append(k)
	return out


## Набор из одной техники (для таблицы вклада) или накопительная цепочка «relevancy+dormancy+...».
static func only(keys: Array, label: String) -> ReplCfg:
	var c := ReplCfg.new()
	c.name = label
	for k in keys:
		c.set_flag(k, true)
	return c


func duplicate_cfg() -> ReplCfg:
	var c := ReplCfg.new()
	c.name = name
	for k in TECH_KEYS:
		c.set_flag(k, get_flag(k))
	c.budget_bytes = budget_bytes
	c.keyframe_net_ticks = keyframe_net_ticks
	return c
