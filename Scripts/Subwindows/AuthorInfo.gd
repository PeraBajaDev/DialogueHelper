extends Window

func _on_close_requested() -> void:
	queue_free()

func _on_cancel_button_pressed() -> void:
	queue_free()

func _on_ok_button_pressed() -> void:
	var author := ($Label/LineEdit as LineEdit).text
	(get_parent() as WDialogueHelper).author = author
	# Fix: chequear null tras FileAccess.open. Si user:// está bloqueado
	# (permisos, antivirus, disco lleno), la app crasheaba al llamar
	# store_string sobre un null. Mismo patrón defensivo que ya usa
	# MainNode._save_recent_files (Scripts/MainNode.gd:778).
	var f := FileAccess.open("user://userlocal_name.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(author)
		f.flush()
		f.close()
	queue_free()
