extends Window
class_name WStyleSelector

# Diálogo de bienvenida que aparece sólo en el primer arranque cuando hay
# 2 o más Styles disponibles. Persistir la elección en user://last_style.txt
# hace que la próxima vez no se vuelva a preguntar — la app respeta lo que
# eligió el usuario.

@onready var option_button: OptionButton = $OptionButton

# IDs del OptionButton (los pasamos como `id` y nos los devuelve el get_selected_id)
# mapeados al nombre real de la carpeta del Style en res://Styles/.
var _id_to_folder: Dictionary[int, String] = {}

func _ready() -> void:
	# Llenamos la lista. Si el Metadata.json del Style tiene un "Name" amigable
	# (p. ej. "Deltarune Chapter 1") lo mostramos; si no, mostramos el nombre
	# de la carpeta tal cual. El id que registramos en el OptionButton es
	# secuencial; lo que nos importa es la carpeta, que recuperamos del map.
	var _available := Handle.list_available_styles()
	var _i: int = 0
	var _preselect: int = 0
	# Preseleccionamos el Style actualmente cargado, que viene de
	# Handle.pick_default_style() (Deltarune si está, si no Template, etc.).
	var _current := Handle.style
	for _folder: String in _available:
		var _display_name: String = _folder
		var _meta_path := Handle.style_get_path("Metadata.json", _folder)
		if FileAccess.file_exists(_meta_path):
			var _meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(_meta_path))
			if _meta is Dictionary and (_meta as Dictionary).has(&"Name"):
				_display_name = str((_meta as Dictionary).Name)
		option_button.add_item(_display_name, _i)
		_id_to_folder[_i] = _folder
		if _folder == _current:
			_preselect = _i
		_i += 1
	option_button.select(_preselect)

func _on_ok_button_pressed() -> void:
	var _id: int = option_button.get_selected_id()
	if _id < 0 or not _id_to_folder.has(_id):
		queue_free()
		return
	var _folder: String = _id_to_folder[_id]

	# Si el usuario eligió un Style distinto del cargado por defecto,
	# recargamos. Mismo flujo que usa Settings al cambiar de Style.
	if _folder != Handle.style:
		Handle.load_style(_folder)
		if Handle.main_node != null and Handle.main_node.box != null \
				and Handle.main_node.box.handle != null:
			Handle.main_node.box.handle.force_update = true

	# Persistimos la elección. La próxima vez que arranque la app, el bloque
	# de "primer arranque" no se ejecutará y se respetará esta preferencia.
	var _f := FileAccess.open("user://last_style.txt", FileAccess.WRITE)
	if _f != null:
		_f.store_string(_folder)
		_f.flush()
		_f.close()
	queue_free()

func _on_cancel_button_pressed() -> void:
	# Cerrar sin persistir: el default cargado durante el _ready sigue activo,
	# pero como NO escribimos last_style.txt, la próxima vez se volverá a
	# preguntar. Es lo que el usuario querría si pulsa Cancel: "decido luego".
	queue_free()

func _on_close_requested() -> void:
	# Cerrar con la X equivale a Cancel.
	queue_free()
