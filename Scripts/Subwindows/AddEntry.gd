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
	#     SOBREESCRIBÍA Handle.strings[text] perdiendo todas las traducciones.
	# Ahora:
	#   - strip_edges() para tolerar espacios accidentales.
	#   - Vacío → no hace nada (la ventana queda abierta para que el usuario lo note).
	#   - Duplicado → selecciona la entry existente y cierra (sin sobreescribir, sin
	#     marcar el archivo como modificado).
	#   - Nuevo → añade a entry_names, a strings y a la UI; ESO sí marca modificado.
	var text := ($Label/LineEdit as LineEdit).text.strip_edges()

	if text.is_empty():
		# Sin nombre válido → no hacer nada. La ventana sigue abierta.
		return

	if Handle.strings.has(text):
		# Ya existe: en vez de pisarla, llevamos al usuario a la entry existente.
		var dialogue_selector: ItemList = Handle.main_node.dialogue_selector
		for _i in range(dialogue_selector.get_item_count()):
			# Fix: usar dialogue_selector_entry_at(_i) en lugar de
			# get_item_text(_i). Los items del dialogue_selector llevan un
			# prefijo de progreso (✓/·/∅/⚠/★) que get_item_text incluye, así
			# que la comparación directa contra `text` (nombre crudo) nunca
			# coincidía y el usuario no era llevado a la entry existente —
			# la ventana se cerraba sin más y parecía que no había pasado nada.
			if Handle.main_node.dialogue_selector_entry_at(_i) == text:
				dialogue_selector.select(_i)
				dialogue_selector.ensure_current_is_visible()
				Handle.main_node._on_item_list_item_selected(_i)
				break
		queue_free()
		return

	# Camino normal: entry nueva.
	Handle.strings[text] = []
	Handle.entry_names.append(text)  # ← lo que faltaba para que la búsqueda la viera.
	# Bloque 1: el item lleva prefijo de progreso. Para una entry recién creada
	# sin strings, el prefijo es "∅ " (vacía).
	var prefix: String = Handle.main_node._entry_progress_prefix(text)
	var item := Handle.main_node.dialogue_selector.add_item(prefix + text)
	Handle.main_node.dialogue_selector.select(item)
	Handle.main_node._on_item_list_item_selected(item)
	Handle.main_node.update_progress_stats_label()
	Handle.is_modified = true
	queue_free()
