extends ScrollContainer
class_name WBox

@export var current_box := 0
var portrait_enabled := false
@onready var sprite: Sprite2D = $Handler/BoxSprite
@onready var handle: BoxHandler = $Handler

var supports_portrait := false
var dialogue_offset := Vector2i(20, 20)
var portrait_offset := Vector2i(145, 20)

# Bug fix: antes se reseteaba todo a cero cada frame y luego se restauraba
# condicionalmente. Eso hacía que el `if _scale != scale` siempre diera true
# (porque acabábamos de poner ZERO) y se asignara el scale en cada frame sin
# necesidad. Ahora detectamos cambios reales en el box (índice o cantidad de
# datos) y sólo entonces refrescamos los campos. Es funcionalmente equivalente
# pero sin trabajo redundante en _process.
var _last_applied_box: int = -1
var _last_applied_box_data_size: int = -1

func _process(_delta: float) -> void:
	# Bug fix: se añadió `current_box < 0`. En GDScript, array[-1] devuelve el
	# último elemento (no error), así que un current_box=-1 transitorio durante
	# un Reload Style pintaba el box equivocado en silencio en vez de salir.
	if Handle.box_data.is_empty() or current_box < 0 or current_box >= Handle.box_data.size():
		# Sin datos válidos: dejamos los campos como estén; no hay nada que pintar.
		return

	# Sólo recalculamos cuando cambia el box seleccionado o cuando se recargan
	# los datos del estilo (la cantidad de boxes cambia).
	var box_data_size: int = Handle.box_data.size()
	if current_box == _last_applied_box and box_data_size == _last_applied_box_data_size:
		return

	_last_applied_box = current_box
	_last_applied_box_data_size = box_data_size

	var box: IBox = Handle.box_data[current_box]
	if sprite.texture != box.texture:
		sprite.texture = box.texture
	supports_portrait = box.supports_portrait
	dialogue_offset = box.dialogue_offset
	portrait_offset = box.portrait_offset
	var local_scale := Vector2(box.scale, box.scale)
	if local_scale != scale:
		scale = local_scale
