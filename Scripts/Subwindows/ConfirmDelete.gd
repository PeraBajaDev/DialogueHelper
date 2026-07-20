extends Window
class_name WConfirmDelete

# Diálogo genérico de confirmación para acciones destructivas (borrar entry,
# borrar string). El caller asigna `message` y `confirmed`, después add_child.
# Si el usuario pulsa Delete, dispara `confirmed`. Si pulsa Cancel o cierra
# con la X, no hace nada.

signal confirmed()

var message: String = "Are you sure?":
	set(value):
		message = value
		if is_inside_tree():
			($Label as Label).text = value

func _ready() -> void:
	($Label as Label).text = message

func _on_ok_button_pressed() -> void:
	confirmed.emit()
	queue_free()

func _on_cancel_button_pressed() -> void:
	queue_free()

func _on_close_requested() -> void:
	queue_free()
