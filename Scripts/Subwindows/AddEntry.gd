extends Window

func _on_close_requested() -> void:
	queue_free()

func _on_cancel_button_pressed() -> void:
	queue_free()

func _on_ok_button_pressed() -> void:
	# Bug fix:
	#   - Antes: NO se actualizaba Handle.entry_names → la entry desaparecía al
	#     escribir en la barra de búsqueda.
	#   - Antes: nombre vacío y nombre duplicado se aceptaban; el duplicado
	#     SOBREESCRIBÍA Handle.strings[txt] perdiendo todas las traducciones.
	# Ahora:
	#   - strip_edges() para tolerar espacios accidentales.
	#   - Vacío → no hace nada (la ventana queda abierta para que el usuario lo note).
	#   - Duplicado → selecciona la entry existente y cierra (sin sobreescribir, sin
	#     marcar el archivo como modificado).
	#   - Nuevo → añade a entry_names, a strings y a la UI; ESO sí marca modificado.
	var txt := ($Label/LineEdit as LineEdit).text.strip_edges()

	if txt.is_empty():
		# Sin nombre válido → no hacer nada. La ventana sigue abierta.
		return

	if Handle.strings.has(txt):
		# Ya existe: en vez de pisarla, llevamos al usuario a la entry existente.
		var _ds: ItemList = Handle.main_node.dialogue_selector
		for _i in range(_ds.get_item_count()):
			# Fix: usar dialogue_selector_entry_at(_i) en lugar de
			# get_item_text(_i). Los items del dialogue_selector llevan un
			# prefijo de progreso (✓/·/∅/⚠/★) que get_item_text incluye, así
			# que la comparación directa contra `txt` (nombre crudo) nunca
			# coincidía y el usuario no era llevado a la entry existente —
			# la ventana se cerraba sin más y parecía que no había pasado nada.
			if Handle.main_node.dialogue_selector_entry_at(_i) == txt:
				_ds.select(_i)
				_ds.ensure_current_is_visible()
				Handle.main_node._on_item_list_item_selected(_i)
				break
		queue_free()
		return

	# Camino normal: entry nueva.
	Handle.strings[txt] = []
	Handle.entry_names.append(txt)  # ← lo que faltaba para que la búsqueda la viera.
	# Bloque 1: el item lleva prefijo de progreso. Para una entry recién creada
	# sin strings, el prefijo es "∅ " (vacía).
	var _prefix: String = Handle.main_node._entry_progress_prefix(txt)
	var _item := Handle.main_node.dialogue_selector.add_item(_prefix + txt)
	Handle.main_node.dialogue_selector.select(_item)
	Handle.main_node._on_item_list_item_selected(_item)
	Handle.main_node.update_progress_stats_label()
	Handle.is_modified = true
	queue_free()
