extends Node

class ILoadFile extends RefCounted:
	var strings := {}
	var string_table := {}
	var string_ids := {}
	var entry_names := []
	var last_string_id := 0
	# Bloque 1: si la carga falla (archivo inaccesible, vacío, formato roto),
	# `error` queda a algo distinto de OK y `error_message` describe el motivo.
	# El thread de carga ya no se traga el error en silencio: retorna un
	# ILoadFile con datos vacíos pero con error informado, y el commit en el
	# main muestra un diálogo en lugar de aplicar datos a medias.
	var error: int = OK
	var error_message: String = ""

# Bandera global de "estoy haciendo I/O". Cubre TODO el flujo de guardado
# (pull, espera por UI de conflictos, escritura, commit). MainNode la consulta
# vía _io_busy() para impedir disparar atajos mientras estamos ocupados.
var io_in_progress: bool = false

# Threads internos del flujo de guardado. Se referencian aquí para hacer
# wait_to_finish() ordenado desde el main, igual que MainNode hace con last_thread.
var _presave_thread: Thread = null
var _write_thread: Thread = null

# ---------------------------------------------------------------------------
# API pública
# ---------------------------------------------------------------------------

# Refactorizado: ya NO devuelve un Thread. El estado se consulta vía
# io_in_progress. El flujo es ahora orientado a eventos:
#   pull (en thread) → resolución de conflictos (en MAIN, vía UI) → write (en thread).
# Así gc_window se crea/manipula SIEMPRE en el main, sin race.
func save_file(path: String) -> void:
	if io_in_progress:
		return
	io_in_progress = true
	if FileAccess.file_exists("user://enable_git.bool"):
		_save_git_phase1_pull(path)
	else:
		_save_phase_write(path)

func load_file(path: String, override_path: String = "", override_modified: bool = false) -> Thread:
	# Bloque 3: cuando recuperamos un autosave, queremos cargar el contenido
	# de user://autosave.txt PERO que current_file_path apunte al archivo
	# original (el que el usuario estaba editando antes del crash) y que
	# is_modified quede en true (porque el autosave aún no es un save real).
	# Los dos parámetros opcionales controlan ese caso. Para una carga
	# normal se dejan en sus defaults.
	Handle.main_node.clear_data()
	var current_thread := Thread.new()
	current_thread.start(func() -> void:
		var cleanup_on_fail := func() -> void:
			if Handle.loading_window != null:
				Handle.loading_window.queue_free.call_deferred()
		if FileAccess.file_exists("user://enable_git.bool"):
			Handle.loading_window.label.set_text.call_deferred("Fetching the git repo...")
			var git_response := Handle.git.pull()
			Handle.handle_git_output.call_deferred(git_response)
			if !git_response.success:
				cleanup_on_fail.call()
				return
		Handle.loading_window.label.set_text.call_deferred("Loading...")
		Handle.main_node.dialogue_selector.clear.call_deferred()
		Handle.main_node.string_selector.clear.call_deferred()
		Handle.main_node.similar_entries.clear.call_deferred()

		# Trabajar SIEMPRE en variables locales del thread; nunca tocar Handle.*
		# directamente desde aquí. Al final volcamos todo en un único call_deferred
		# para que el main tenga una vista consistente y no haya races con _process.
		var output := load_file_data(path, true, true)

		# Bloque 1: si la carga falló (archivo inaccesible, formato roto),
		# abortamos el commit y mostramos un diálogo en el main. Antes esto
		# se silenciaba y el usuario se quedaba con datos a medias o vacíos.
		if output.error != OK:
			var error_message: String = output.error_message
			(func() -> void:
				if Handle.loading_window != null:
					Handle.loading_window.queue_free()
				Handle.main_node._show_load_error(error_message)
			).call_deferred()
			return

		var local_strings: Dictionary = output.strings
		var local_string_table: Dictionary = output.string_table
		var local_string_ids: Dictionary = output.string_ids
		var local_entry_names: Array = output.entry_names
		var local_last_id: int = output.last_string_id

		# Si la carga tuvo advertencias (líneas malformadas saltadas), las
		# mostramos al final en un diálogo informativo, pero seguimos con el
		# flujo de commit normal — el archivo se carga con lo que se pudo.
		var warning_message: String = output.error_message

		# Cacheo de similar entries en estructuras LOCALES.
		var local_string_sstr := {}
		var local_string_sstr_arr: Array[Array] = []
		var equal_strings := {}
		var equal_strings_array := []
		var progress := 0
		Handle.loading_window.label.set_text.call_deferred("Caching similar entries... [This may take a long time.]")
		Handle.loading_window.progress_bar.set_value.call_deferred(0)
		Handle.loading_window.progress_bar.set_max.call_deferred(local_string_table.size() * 2)
		for entry: int in local_string_table.keys():
			var string_container: IStringContainer = local_string_table[entry].data
			if !equal_strings.has(string_container.original_content):
				equal_strings[string_container.original_content] = equal_strings_array.size()
				var array: Array[int] = [string_container.id]
				string_container.equal_strings = array
				equal_strings_array.append(array)
			else:
				var array: Array[int] = equal_strings_array[equal_strings[string_container.original_content]]
				array.append(string_container.id)
				string_container.equal_strings = array
			progress += 1
			Handle.loading_window.progress_bar.set_value.call_deferred(progress)
		for key: String in equal_strings.keys():
			var entries: Array = equal_strings_array[equal_strings[key]]
			if entries.size() > 1:
				var index := local_string_sstr_arr.size()
				local_string_sstr[key] = index
				local_string_sstr_arr.append(entries)
				for entry: int in entries:
					(local_string_table[entry] as IStringTable).data.equal_strings_index = index
			progress += 1
			Handle.loading_window.progress_bar.set_value.call_deferred(progress)

		# Vuelco atómico (desde el punto de vista del main): todo en un único
		# call_deferred. Cuando este lambda corra, el main verá Handle.* coherente.
		var commit := func() -> void:
			Handle.strings = local_strings
			Handle.string_table = local_string_table
			Handle.string_ids = local_string_ids
			Handle.entry_names = local_entry_names
			Handle.last_string_id = local_last_id
			Handle.string_sstr = local_string_sstr
			Handle.string_sstr_arr = local_string_sstr_arr
			# Fix #3: ahora sí se actualiza string_size, así Search.gd ve el tamaño
			# correcto y la barra de progreso de búsqueda funciona.
			Handle.string_size = local_string_table.size()
			Handle.original_string = ""
			for i in range(Handle.layer_strings.size()):
				Handle.layer_strings[i] = ""
			for i in range(Handle.layer_colors.size()):
				Handle.layer_colors[i] = Color.WHITE
			Handle.is_modified = false
			# Bloque 3: si nos pidieron sobrescribir el path final (caso de
			# recuperación de autosave), usamos ése en current_file_path
			# y en push_recent. El path real (de donde se leyó) podía ser
			# user://autosave.txt y no queremos guardarlo como "reciente".
			var final_path: String = override_path if override_path != "" else path
			Handle.current_file_path = final_path
			if override_modified:
				Handle.is_modified = true
			if Handle.main_node != null:
				Handle.main_node.update_window_title()
				# Bloque 1: registrar en Open Recent tras carga exitosa.
				# Solo si el path final no está vacío y no es el autosave.
				if final_path != "":
					Handle.main_node.push_recent_file(final_path)
				# El archivo viene de disco: marcar que es un "archivo abierto"
				# para deshabilitar acciones que solo tienen sentido en archivos nuevos
				# (Add new Entry, Delete Selected Entry). Si la carga es de un
				# autosave huérfano de un archivo nunca guardado (final_path == ""),
				# se trata igual que un archivo nuevo.
				Handle.main_node._file_was_opened = (final_path != "")
			if Handle.loading_window != null:
				Handle.loading_window.queue_free()
			_select_first_entry()
			# Bloque 1: si hubo advertencias, las mostramos tras cargar.
			if warning_message != "" and Handle.main_node != null:
				Handle.main_node._show_load_warning(warning_message)
		commit.call_deferred()
	)
	return current_thread

func _select_first_entry() -> void:
	if Handle.main_node == null:
		return
	var dialogue_selector: ItemList = Handle.main_node.dialogue_selector
	# Bloque 1: tras cargar, refrescamos prefijos y stats globales.
	# Bloque 2: pasamos por _rebuild_entry_list en lugar de refresh_all_*
	# para que el filtro activo se aplique de entrada (en caso de que el
	# usuario hubiese dejado un filtro puesto antes de abrir el archivo).
	# load_file_data llenó los items "crudos"; aquí los reemplazamos.
	Handle.main_node._rebuild_entry_list()
	Handle.main_node.update_progress_stats_label()
	if dialogue_selector.item_count == 0:
		return
	dialogue_selector.select(0)
	dialogue_selector.ensure_current_is_visible()
	# select() no emite item_selected; lo llamamos a mano para que se pueble
	# string_selector y se cargue la primera string en el editor de capas.
	Handle.main_node._on_item_list_item_selected(0)

func load_file_data(path: String, apply_settings := true, is_thread := false) -> ILoadFile:
	var strings := {}
	var string_table := {}
	var string_ids := {}
	var entry_names := []
	var last_string_id := 0
	var file_loader := ILoadFile.new()

	# Bloque 1: comprobamos que el archivo se puede abrir antes de leer. Si
	# falla, devolvemos ILoadFile con error y el caller decide qué hacer (en
	# el flujo de carga normal: mostrar diálogo y abortar el commit).
	if not FileAccess.file_exists(path):
		file_loader.error = ERR_FILE_NOT_FOUND
		file_loader.error_message = "File does not exist:\n%s" % path
		return file_loader

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		file_loader.error = FileAccess.get_open_error()
		file_loader.error_message = "Could not open file (error %d):\n%s" % [file_loader.error, path]
		return file_loader
	var data := file.get_as_text()
	file.close()

	if data.strip_edges() == "":
		# Un archivo completamente vacío no es un error grave (puede ser un
		# .txt nuevo). Lo tratamos como "0 entries" pero avisamos al caller
		# por si quiere mostrar nota — el flujo actual no lo hace.
		# Reutilizamos el `file_loader` ya creado: tiene los defaults correctos
		# (error=OK, strings={}, entry_names=[], etc.).
		return file_loader

	var array := FileFormat.parse_file(data)
	if array.is_empty():
		file_loader.error = ERR_PARSE_ERROR
		file_loader.error_message = "File could not be parsed (no recognizable lines):\n%s" % path
		return file_loader

	if is_thread:
		Handle.loading_window.progress_bar.set_max.call_deferred(array.size())

	var total := 0
	var current_entry := ""
	var entries := []
	var is_entry := false
	var malformed_count := 0  # contamos líneas raras para reportar al final

	for _line: IFormatEntry in array:
		if (_line.kind == 0 || _line.kind == 8) && is_entry:
			strings[current_entry] = entries
			entries = []
		match _line.kind:
			9:
				if apply_settings:
					if is_thread:
						Handle.load_style.call_deferred(_line.data["Style"])
					else:
						Handle.load_style(_line.data["Style"])
			0:
				if not _line.data.has(&"ID"):
					# Entry sin ID: línea malformada. La saltamos y contamos.
					malformed_count += 1
				else:
					current_entry = _line.data.ID
					entry_names.append(current_entry)
					is_entry = true
			1:
				_line.data.ID = last_string_id
				last_string_id += 1
				var cont := IStringContainer.new(_line)
				if is_thread:
					string_table[cont.id] = IStringTable.new(current_entry, cont.content, entries.size(), cont)
				string_ids[cont.id] = cont.content
				entries.append(cont)
			_:
				# kind no reconocido (≠ 0,1,8,9). Lo ignoramos pero contamos
				# para el reporte final. kind=8 es marcador EOF.
				if _line.kind != 8:
					malformed_count += 1
		if is_thread:
			total += 1
			Handle.loading_window.progress_bar.set_value.call_deferred(total)
	file_loader.strings = strings
	file_loader.string_table = string_table
	file_loader.string_ids = string_ids
	file_loader.entry_names = entry_names
	file_loader.last_string_id = last_string_id
	# Si hubo líneas malformadas pero al menos algo se cargó, lo reportamos
	# como advertencia (no como error fatal): el archivo se carga, pero el
	# usuario sabe que ha habido problemas y puede revisar.
	if malformed_count > 0:
		file_loader.error_message = "%d line(s) in the file were malformed and skipped." % malformed_count
	return file_loader

# ---------------------------------------------------------------------------
# Internos del flujo de guardado refactorizado
# ---------------------------------------------------------------------------

# Phase 1 (solo git): pull + detección de conflictos en thread.
# Cuando termina, retorna a MAIN vía call_deferred para resolver UI.
func _save_git_phase1_pull(path: String) -> void:
	_presave_thread = Thread.new()
	_presave_thread.start(func() -> void:
		Handle.saving_window.label.set_text.call_deferred("Fetching the git repo...")
		var git_response := Handle.git.pull()
		Handle.handle_git_output.call_deferred(git_response)
		var conflicts: Array[IGitConflict] = []
		if git_response.success:
			Handle.saving_window.label.set_text.call_deferred("Checking up differences between commits...")
			var old_data: Dictionary = load_file_data(path, false).strings
			for entry_name: String in Handle.strings.keys():
				if old_data.has(entry_name):
					var old_entries: Array = old_data[entry_name]
					var new_entries: Array = Handle.strings[entry_name]
					var i := 0
					for entry: IStringContainer in new_entries:
						if i >= old_entries.size():
							break
						var old_entry: IStringContainer = old_entries[i]
						if old_entry.content != entry.content:
							var conflict := IGitConflict.new()
							conflict.string_id = entry.id
							conflict.current_string = entry.content
							conflict.git_string = old_entry.content
							conflicts.append(conflict)
						i += 1
		(func() -> void:
			_save_git_phase2_resolve(path, git_response.success, conflicts)
		).call_deferred()
	)

# Phase 2 (solo git): SIEMPRE en MAIN. Maneja la UI de conflictos y, cuando se
# resuelve, lanza la fase de escritura.
func _save_git_phase2_resolve(path: String, pull_ok: bool, conflicts: Array) -> void:
	if _presave_thread != null:
		_presave_thread.wait_to_finish()
		_presave_thread = null
	if not pull_ok:
		if Handle.saving_window != null:
			Handle.saving_window.queue_free()
		io_in_progress = false
		return
	if conflicts.is_empty():
		_save_phase_write(path)
		return
	# Crear gc_window aquí, en main; ya no hay race con el worker.
	Handle.git_conflict_window = Handle.git_conflict_scene.instantiate()
	Handle.git_conflict_window.conflicts = conflicts
	# Conectamos ANTES de add_child para no perder el evento si por algún motivo
	# la ventana se cerrara inmediatamente.
	Handle.git_conflict_window.tree_exited.connect(func() -> void:
		for conflict: IGitConflict in conflicts:
			var string_table: IStringTable = Handle.string_table[conflict.string_id]
			match conflict.keep:
				IGitConflict.IKeep.KeepGit:
					string_table.data.content = conflict.git_string
					# Bug fix: sin esto, string_ids[id] queda apuntando al
					# content viejo. AddString usa string_ids para detectar
					# strings con el mismo original_content y construir grupos
					# de "similar entries", así que un conflicto resuelto
					# rompía el cálculo hasta el siguiente reload del archivo.
					Handle.string_ids[conflict.string_id] = conflict.git_string
				IGitConflict.IKeep.KeepOriginal:
					string_table.data.content = conflict.current_string
					Handle.string_ids[conflict.string_id] = conflict.current_string
		_save_phase_write(path)
	, CONNECT_ONE_SHOT)
	Handle.main_node.add_child(Handle.git_conflict_window)

# Bloque 3: construye el array de strings (líneas serializadas) que
# representa el estado actual de Handle.strings en formato del .txt.
# Reusable desde _save_phase_write y desde el autosave de MainNode.
# El callback opcional `_progress_cb` recibe el contador acumulado de
# strings procesadas, para refrescar barras de progreso del save normal.
# El autosave lo ignora.
func _build_save_payload(progress_cb: Callable = Callable()) -> Array:
	var data: Array = []
	var progress: int = 0
	var format_entry := IFormatEntry.new()
	format_entry.kind = 9
	format_entry.data.Style = Handle.style
	data.append(format_entry)
	for key: String in Handle.strings.keys():
		format_entry = IFormatEntry.new()
		format_entry.kind = 0
		format_entry.data.ID = key
		data.append(str(format_entry))
		for entry: IStringContainer in Handle.strings[key] as Array:
			data.append(str(entry))
			if progress_cb.is_valid():
				progress_cb.call(progress)
			progress += 1
	format_entry = IFormatEntry.new()
	format_entry.kind = 8
	data.append(str(format_entry))
	return data

# Phase write: escritura del archivo en thread. Al terminar, libera la ventana
# de progreso, hace commit si hay git, y limpia io_in_progress.
func _save_phase_write(path: String) -> void:
	_write_thread = Thread.new()
	_write_thread.start(func() -> void:
		Handle.saving_window.label.set_text.call_deferred("Saving...")
		# Bug fix: la barra de guardado nunca tenía max_value y se saturaba al
		# 100% en los primeros 100 strings. Sumamos el total ANTES del bucle.
		var total_strings: int = 0
		for key_count: String in Handle.strings.keys():
			total_strings += (Handle.strings[key_count] as Array).size()
		Handle.saving_window.progress_bar.set_max.call_deferred(total_strings)
		Handle.saving_window.progress_bar.set_value.call_deferred(0)
		var data := _build_save_payload(func(progress: int) -> void:
			Handle.saving_window.progress_bar.set_value.call_deferred(progress)
		)
		Handle.saving_window.label.set_text.call_deferred("Saving the file...")
		var ok := _write_data(path, data)
		if not ok:
			Handle.saving_window.queue_free.call_deferred()
			io_in_progress = false
			_join_write_thread.call_deferred()
			return
		# Bug fix (race): estas asignaciones corren en el thread del save. El
		# setter de is_modified emite is_modified_changed; el handler en
		# MainNode (_on_is_modified_changed) toca un Timer, lo que NO es legal
		# desde un thread no-main. Con set_deferred la asignación —y por tanto
		# la señal— se procesa en el siguiente tick del main thread.
		Handle.set_deferred(&"is_modified", false)
		Handle.set_deferred(&"current_file_path", path)
		if Handle.main_node != null:
			Handle.main_node.update_window_title.call_deferred()
			# Bloque 1: registrar en Open Recent. push_recent_file ignora rutas
			# de user:// (modo git) automáticamente, así que es seguro llamarla
			# en ambos caminos.
			Handle.main_node.push_recent_file.call_deferred(path)
			# Bloque 3: el archivo se guardó OK; el autosave es ya basura,
			# lo descartamos para que no aparezca el diálogo de recuperación
			# en el próximo arranque.
			Handle.main_node._discard_autosave_files.call_deferred()
		if FileAccess.file_exists("user://enable_git.bool"):
			Handle.saving_window.label.set_text.call_deferred("Commiting on the git repo...")
			var git_response := Handle.git.commit("[DH] Update Strings")
			Handle.handle_git_output.call_deferred(git_response)
			if !git_response.success:
				Handle.saving_window.queue_free.call_deferred()
				io_in_progress = false
				_join_write_thread.call_deferred()
				return
		Handle.saving_window.queue_free.call_deferred()
		io_in_progress = false
		_join_write_thread.call_deferred()
	)

# Joiner: lo dispara el write thread al terminar, vía call_deferred.
func _join_write_thread() -> void:
	if _write_thread != null:
		_write_thread.wait_to_finish()
		_write_thread = null

# Escritura del payload al disco.
# - Destino NO existe → escritura directa (no hay nada a proteger).
# - Destino existe → escribir a .tmp y rename atómico .tmp → destino.
#   El rename sobre un destino existente es atómico en Linux/macOS (rename(2))
#   y en Windows (MoveFileEx con MOVEFILE_REPLACE_EXISTING, que es lo que usa
#   Godot 4 internamente), así que en ningún momento queda un archivo "a medias":
#   o ves la versión vieja entera, o la nueva entera.
#
# No mantenemos .bak: el git integrado ya hace ese papel (con historial real,
# no sólo "el guardado anterior") y un .bak placebo sólo ensucia la carpeta.
func _write_data(path: String, data: Array) -> bool:
	var payload := "\n".join(PackedStringArray(data))

	# Caso simple: archivo nuevo. Sin baile de temporales.
	if not FileAccess.file_exists(path):
		var new_file := FileAccess.open(path, FileAccess.WRITE)
		if new_file == null:
			var err_new := FileAccess.get_open_error()
			push_error("Failed to open %s for writing (error %d)" % [path, err_new])
			Handle.saving_window.label.set_text.call_deferred(
				"Error: could not save to\n%s\n(error %d)" % [path, err_new]
			)
			return false
		new_file.store_string(payload)
		new_file.flush()
		new_file.close()
		return true

	# Camino atómico para archivos existentes: escribir a .tmp y renombrar.
	var tmp_path := path + ".tmp"
	var tmp_file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if tmp_file == null:
		var error := FileAccess.get_open_error()
		push_error("Failed to open %s for writing (error %d)" % [tmp_path, error])
		Handle.saving_window.label.set_text.call_deferred(
			"Error: could not save to\n%s\n(error %d)" % [path, error]
		)
		return false
	tmp_file.store_string(payload)
	tmp_file.flush()
	tmp_file.close()

	var rename_error := DirAccess.rename_absolute(tmp_path, path)
	if rename_error != OK:
		push_error("Failed to rename %s to %s (error %d)" % [tmp_path, path, rename_error])
		Handle.saving_window.label.set_text.call_deferred(
			"Error: save file could not be finalized (error %d)" % rename_error
		)
		# Limpiamos el .tmp que quedó huérfano para no dejar basura.
		# El archivo original sigue intacto (el rename falló, no llegó a tocarlo).
		if FileAccess.file_exists(tmp_path):
			DirAccess.remove_absolute(tmp_path)
		return false
	return true
