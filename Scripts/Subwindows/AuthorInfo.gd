extends Window

func _on_close_requested() -> void:
	queue_free()

func _on_cancel_button_pressed() -> void:
	queue_free()

func _on_ok_button_pressed() -> void:
	var _author := ($Label/LineEdit as LineEdit).text
	(get_parent() as WDialogueHelper).author = _author
	# Fix: chequear null tras FileAccess.open. Si user:// está bloqueado
	# (permisos, antivirus, disco lleno), la app crasheaba al llamar
	# store_string sobre un null. Mismo patrón defensivo que ya usa
	# MainNode._save_recent_files (Scripts/MainNode.gd:778).
	var _f := FileAccess.open("user://username.txt", FileAccess.WRITE)
	if _f != null:
		_f.store_string(_author)
		_f.flush()
		_f.close()
	queue_free()
