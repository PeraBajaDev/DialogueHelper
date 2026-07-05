extends Window
class_name WRecoverAutosave

# Bloque 3: diálogo de recuperación de autosave.
# Aparece al arrancar la app si existe `user://autosave.txt`. El caller
# (MainNode) es responsable de cargar/borrar — esta ventana sólo informa
# al usuario y emite señales según su decisión.

signal recover_requested()
signal discard_requested()

var message: String = "":
	set(v):
		message = v
		if is_inside_tree():
			($Label as Label).text = v

func _ready() -> void:
	($Label as Label).text = message

func _on_recover_pressed() -> void:
	recover_requested.emit()
	queue_free()

func _on_discard_pressed() -> void:
	discard_requested.emit()
	queue_free()

func _on_close_requested() -> void:
	# Cerrar con la X = cancelar: no recover, no discard. El autosave
	# queda intacto en disco; volverá a preguntar la próxima vez.
	queue_free()
