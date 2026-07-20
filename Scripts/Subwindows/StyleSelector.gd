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
	var available := Handle.list_available_styles()
	var i: int = 0
	var preselect: int = 0
	# Preseleccionamos el Style actualmente cargado, que viene de
	# Handle.pick_default_style() (Deltarune si está, si no Template, etc.).
	var current := Handle.style
	for _folder: String in available:
		var display_local_name: String = _folder
		var meta_path := Handle.style_get_path("Metadata.json", _folder)
		if FileAccess.file_exists(meta_path):
			var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
			if meta is Dictionary and (meta as Dictionary).has(&"Name"):
				display_local_name = str((meta as Dictionary).Name)
		option_button.add_item(display_local_name, i)
		_id_to_folder[i] = _folder
		if _folder == current:
			preselect = i
		i += 1
	option_button.select(preselect)

func _on_ok_button_pressed() -> void:
	var id: int = option_button.get_selected_id()
	if id < 0 or not _id_to_folder.has(id):
		queue_free()
		return
	var folder: String = _id_to_folder[id]

	# Si el usuario eligió un Style distinto del cargado por defecto,
	# recargamos. Mismo flujo que usa Settings al cambiar de Style.
	if folder != Handle.style:
		Handle.load_style(folder)
		if Handle.main_node != null and Handle.main_node.box != null \
				and Handle.main_node.box.handle != null:
			Handle.main_node.box.handle.force_update = true

	# Persistimos la elección. La próxima vez que arranque la app, el bloque
	# de "primer arranque" no se ejecutará y se respetará esta preferencia.
	var last_style_file := FileAccess.open("user://last_style.txt", FileAccess.WRITE)
	if last_style_file != null:
		last_style_file.store_string(folder)
		last_style_file.flush()
		last_style_file.close()
	queue_free()

func _on_cancel_button_pressed() -> void:
	# Cerrar sin persistir: el default cargado durante el _ready sigue activo,
	# pero como NO escribimos last_style.txt, la próxima vez se volverá a
	# preguntar. Es lo que el usuario querría si pulsa Cancel: "decido luego".
	queue_free()

func _on_close_requested() -> void:
	# Cerrar con la X equivale a Cancel.
	queue_free()
