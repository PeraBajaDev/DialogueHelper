extends Window
class_name WUnsavedChanges

signal callback()

func _on_close_requested() -> void:
	queue_free()

func _on_ok_button_pressed() -> void:
	# Antes había `if !callback.is_null(): callback.emit()`. En Godot 4 una
	# Signal no puede ser null (no es un objeto nullable como Callable), así
	# que la guarda no protegía de nada. Llamar `emit()` sin listeners
	# conectados ya es un no-op seguro.
	callback.emit()
	queue_free()

func _on_cancel_button_pressed() -> void:
	queue_free()
