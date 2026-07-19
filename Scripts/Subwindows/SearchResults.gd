extends Window
class_name WSearchResults

@onready var it: ItemList = $ItemList

func _on_item_selected(index: int) -> void:
	# Bug fix: parseo "local_name:N" robusto a `:` en el nombre. Antes hacíamos
	# `(text + ":1").split(":")` y partíamos el nombre en el primer `:`.
	# _parse_entry_ref usa rsplit y exige número en la cola.
	var ref: Array = Handle.main_node._parse_entry_ref(it.get_item_text(index))
	var item_local_name: String = ref[0]
	var idx_zero: int = (ref[1] as int) - 1
	if Handle.strings.has(item_local_name):
		# Bug fix (decoupling, ver MainNode.current_entry): change_to fija
		# current_entry/current_string_index — la edición funciona aunque la
		# entry no aparezca en dialogue_selector (filtro activo). El bucle
		# final es sólo sincronización visual: si la entry está visible la
		# marca como seleccionada; si no, no-op y el filtro del usuario se
		# preserva.
		Handle.main_node.change_to(item_local_name, idx_zero)
		Handle.main_node.string_selector.clear()
		for _stri: IStringContainer in Handle.strings[item_local_name]:
			# Fix: incluir el prefijo de progreso (✓/·/⚠/★) al rellenar el
			# string_selector. Antes se añadía el texto crudo y al navegar
			# desde un resultado de búsqueda los marcadores desaparecían.
			Handle.main_node.string_selector.add_item(Handle.main_node._string_progress_prefix(_stri) + str(_stri.layer_strings[0]))
		Handle.main_node.string_selector.select(idx_zero)
		Handle.main_node.string_selector.ensure_current_is_visible()
		for _i in range(Handle.main_node.dialogue_selector.get_item_count()):
			# Fix: comparar contra el nombre real (sin prefijo). get_item_text
			# incluye el prefijo de progreso y la comparación nunca coincidía.
			if Handle.main_node.dialogue_selector_entry_at(_i) == item_local_name:
				Handle.main_node.dialogue_selector.select(_i)
				Handle.main_node.dialogue_selector.ensure_current_is_visible()
				break

func _on_close_requested() -> void:
	queue_free()
