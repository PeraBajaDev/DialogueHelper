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
func save_file(_path: String) -> void:
	if io_in_progress:
		return
	io_in_progress = true
	if FileAccess.file_exists("user://enable_git.bool"):
		_save_git_phase1_pull(_path)
	else:
		_save_phase_write(_path)

func load_file(_path: String, _override_path: String = "", _override_modified: bool = false) -> Thread:
	# Bloque 3: cuando recuperamos un autosave, queremos cargar el contenido
	# de user://autosave.txt PERO que current_file_path apunte al archivo
	# original (el que el usuario estaba editando antes del crash) y que
	# is_modified quede en true (porque el autosave aún no es un save real).
	# Los dos parámetros opcionales controlan ese caso. Para una carga
	# normal se dejan en sus defaults.
	Handle.main_node.clear_data()
	var _cthr := Thread.new()
	_cthr.start(func() -> void:
		var _cleanup_on_fail := func() -> void:
			if Handle.loading_window != null:
				Handle.loading_window.call_deferred("queue_free")
		if FileAccess.file_exists("user://enable_git.bool"):
			Handle.loading_window.label.set_text.call_deferred("Fetching the git repo...")
			var _r := Handle.git.pull()
			Handle.handle_git_output.call_deferred(_r)
			if !_r.success:
				_cleanup_on_fail.call()
				return
		Handle.loading_window.label.set_text.call_deferred("Loading...")
		Handle.main_node.dialogue_selector.clear.call_deferred()
		Handle.main_node.string_selector.clear.call_deferred()
		Handle.main_node.similar_entries.clear.call_deferred()
		
		# Trabajar SIEMPRE en variables locales del thread; nunca tocar Handle.*
		# directamente desde aquí. Al final volcamos todo en un único call_deferred
		# para que el main tenga una vista consistente y no haya races con _process.
		var _output := load_file_data(_path, true, true)

		# Bloque 1: si la carga falló (archivo inaccesible, formato roto),
		# abortamos el commit y mostramos un diálogo en el main. Antes esto
		# se silenciaba y el usuario se quedaba con datos a medias o vacíos.
		if _output.error != OK:
			var _err_msg: String = _output.error_message
			(func() -> void:
				if Handle.loading_window != null:
					Handle.loading_window.queue_free()
				Handle.main_node._show_load_error(_err_msg)
			).call_deferred()
			return

		var _local_strings: Dictionary = _output.strings
		var _local_string_table: Dictionary = _output.string_table
		var _local_string_ids: Dictionary = _output.string_ids
		var _local_entry_names: Array = _output.entry_names
		var _local_last_id: int = _output.last_string_id

		# Si la carga tuvo advertencias (líneas malformadas saltadas), las
		# mostramos al final en un diálogo informativo, pero seguimos con el
		# flujo de commit normal — el archivo se carga con lo que se pudo.
		var _warning_msg: String = _output.error_message
		
		# Cacheo de similar entries en estructuras LOCALES.
		var _local_string_sstr := {}
		var _local_string_sstr_arr: Array[Array] = []
		var _eqstr := {}
		var _eqstrarr := []
		var _v := 0
		Handle.loading_window.label.set_text.call_deferred("Caching similar entries... [This may take a long time.]")
		Handle.loading_window.progress_bar.set_value.call_deferred(0)
		Handle.loading_window.progress_bar.set_max.call_deferred(_local_string_table.size() * 2)
		for _entry: int in _local_string_table.keys():
			var _strg: IStringContainer = _local_string_table[_entry].data
			if !_eqstr.has(_strg.original_content):
				_eqstr[_strg.original_content] = _eqstrarr.size()
				var _arr: Array[int] = [_strg.id]
				_strg.equal_strings = _arr
				_eqstrarr.append(_arr)
			else:
				var _arr: Array[int] = _eqstrarr[_eqstr[_strg.original_content]]
				_arr.append(_strg.id)
				_strg.equal_strings = _arr
			_v += 1
			Handle.loading_window.progress_bar.set_value.call_deferred(_v)
		for _key: String in _eqstr.keys():
			var _entries: Array = _eqstrarr[_eqstr[_key]]
			if _entries.size() > 1:
				var _index := _local_string_sstr_arr.size()
				_local_string_sstr[_key] = _index
				_local_string_sstr_arr.append(_entries)
				for _entry: int in _entries:
					(_local_string_table[_entry] as IStringTable).data.equal_strings_index = _index
			_v += 1
			Handle.loading_window.progress_bar.set_value.call_deferred(_v)
		
		# Vuelco atómico (desde el punto de vista del main): todo en un único
		# call_deferred. Cuando este lambda corra, el main verá Handle.* coherente.
		var _commit := func() -> void:
			Handle.strings = _local_strings
			Handle.string_table = _local_string_table
			Handle.string_ids = _local_string_ids
			Handle.entry_names = _local_entry_names
			Handle.last_string_id = _local_last_id
			Handle.string_sstr = _local_string_sstr
			Handle.string_sstr_arr = _local_string_sstr_arr
			# Fix #3: ahora sí se actualiza string_size, así Search.gd ve el tamaño
			# correcto y la barra de progreso de búsqueda funciona.
			Handle.string_size = _local_string_table.size()
			Handle.og_str = ""
			for _i in range(Handle.layer_strings.size()):
				Handle.layer_strings[_i] = ""
			for _i in range(Handle.layer_colors.size()):
				Handle.layer_colors[_i] = Color.WHITE
			Handle.is_modified = false
			# Bloque 3: si nos pidieron sobrescribir el path final (caso de
			# recuperación de autosave), usamos ése en current_file_path
			# y en push_recent. El _path real (de donde se leyó) podía ser
			# user://autosave.txt y no queremos guardarlo como "reciente".
			var _final_path: String = _override_path if _override_path != "" else _path
			Handle.current_file_path = _final_path
			if _override_modified:
				Handle.is_modified = true
			if Handle.main_node != null:
				Handle.main_node.update_window_title()
				# Bloque 1: registrar en Open Recent tras carga exitosa.
				# Solo si el path final no está vacío y no es el autosave.
				if _final_path != "":
					Handle.main_node.push_recent_file(_final_path)
				# El archivo viene de disco: marcar que es un "archivo abierto"
				# para deshabilitar acciones que solo tienen sentido en archivos nuevos
				# (Add new Entry, Delete Selected Entry). Si la carga es de un
				# autosave huérfano de un archivo nunca guardado (_final_path == ""),
				# se trata igual que un archivo nuevo.
				Handle.main_node._file_was_opened = (_final_path != "")
			if Handle.loading_window != null:
				Handle.loading_window.queue_free()
			_select_first_entry()
			# Bloque 1: si hubo advertencias, las mostramos tras cargar.
			if _warning_msg != "" and Handle.main_node != null:
				Handle.main_node._show_load_warning(_warning_msg)
		_commit.call_deferred()
	)
	return _cthr

func _select_first_entry() -> void:
	if Handle.main_node == null:
		return
	var _ds: ItemList = Handle.main_node.dialogue_selector
	# Bloque 1: tras cargar, refrescamos prefijos y stats globales.
	# Bloque 2: pasamos por _rebuild_entry_list en lugar de refresh_all_*
	# para que el filtro activo se aplique de entrada (en caso de que el
	# usuario hubiese dejado un filtro puesto antes de abrir el archivo).
	# load_file_data llenó los items "crudos"; aquí los reemplazamos.
	Handle.main_node._rebuild_entry_list()
	Handle.main_node.update_progress_stats_label()
	if _ds.item_count == 0:
		return
	_ds.select(0)
	_ds.ensure_current_is_visible()
	# select() no emite item_selected; lo llamamos a mano para que se pueble
	# string_selector y se cargue la primera string en el editor de capas.
	Handle.main_node._on_item_list_item_selected(0)

func load_file_data(_path: String, _apply_settings := true, _is_thread := false) -> ILoadFile:
	var _strings := {}
	var _string_table := {}
	var _string_ids := {}
	var _entry_names := []
	var _last_string_id := 0
	var ilf := ILoadFile.new()

	# Bloque 1: comprobamos que el archivo se puede abrir antes de leer. Si
	# falla, devolvemos ILoadFile con error y el caller decide qué hacer (en
	# el flujo de carga normal: mostrar diálogo y abortar el commit).
	if not FileAccess.file_exists(_path):
		ilf.error = ERR_FILE_NOT_FOUND
		ilf.error_message = "File does not exist:\n%s" % _path
		return ilf

	var _f := FileAccess.open(_path, FileAccess.READ)
	if _f == null:
		ilf.error = FileAccess.get_open_error()
		ilf.error_message = "Could not open file (error %d):\n%s" % [ilf.error, _path]
		return ilf
	var _data := _f.get_as_text()
	_f.close()

	if _data.strip_edges() == "":
		# Un archivo completamente vacío no es un error grave (puede ser un
		# .txt nuevo). Lo tratamos como "0 entries" pero avisamos al caller
		# por si quiere mostrar nota — el flujo actual no lo hace.
		# Reutilizamos el `ilf` ya creado: tiene los defaults correctos
		# (error=OK, strings={}, entry_names=[], etc.).
		return ilf

	var _arr := FileFormat.parse_file(_data)
	if _arr.is_empty():
		ilf.error = ERR_PARSE_ERROR
		ilf.error_message = "File could not be parsed (no recognizable lines):\n%s" % _path
		return ilf

	if _is_thread:
		Handle.loading_window.progress_bar.set_max.call_deferred(_arr.size())

	var _totl := 0
	var _current_entry := ""
	var _entries := []
	var _is_entry := false
	var _malformed_count := 0  # contamos líneas raras para reportar al final

	for _line: IFormatEntry in _arr:
		if (_line.kind == 0 || _line.kind == 8) && _is_entry:
			_strings[_current_entry] = _entries
			_entries = []
		match _line.kind:
			9:
				if _apply_settings:
					if _is_thread:
						Handle.load_style.call_deferred(_line.data["Style"])
					else:
						Handle.load_style(_line.data["Style"])
			0:
				if not _line.data.has(&"ID"):
					# Entry sin ID: línea malformada. La saltamos y contamos.
					_malformed_count += 1
				else:
					_current_entry = _line.data.ID
					_entry_names.append(_current_entry)
					_is_entry = true
			1:
				_line.data.ID = _last_string_id
				_last_string_id += 1
				var _cont := IStringContainer.new(_line)
				if _is_thread:
					_string_table[_cont.id] = IStringTable.new(_current_entry, _cont.content, _entries.size(), _cont)
				_string_ids[_cont.id] = _cont.content
				_entries.append(_cont)
			_:
				# kind no reconocido (≠ 0,1,8,9). Lo ignoramos pero contamos
				# para el reporte final. kind=8 es marcador EOF.
				if _line.kind != 8:
					_malformed_count += 1
		if _is_thread:
			_totl += 1
			Handle.loading_window.progress_bar.set_value.call_deferred(_totl)
	ilf.strings = _strings
	ilf.string_table = _string_table
	ilf.string_ids = _string_ids
	ilf.entry_names = _entry_names
	ilf.last_string_id = _last_string_id
	# Si hubo líneas malformadas pero al menos algo se cargó, lo reportamos
	# como advertencia (no como error fatal): el archivo se carga, pero el
	# usuario sabe que ha habido problemas y puede revisar.
	if _malformed_count > 0:
		ilf.error_message = "%d line(s) in the file were malformed and skipped." % _malformed_count
	return ilf

# ---------------------------------------------------------------------------
# Internos del flujo de guardado refactorizado
# ---------------------------------------------------------------------------

# Phase 1 (solo git): pull + detección de conflictos en thread.
# Cuando termina, retorna a MAIN vía call_deferred para resolver UI.
func _save_git_phase1_pull(_path: String) -> void:
	_presave_thread = Thread.new()
	_presave_thread.start(func() -> void:
		Handle.saving_window.label.set_text.call_deferred("Fetching the git repo...")
		var _r := Handle.git.pull()
		Handle.handle_git_output.call_deferred(_r)
		var _conflicts: Array[IGitConflict] = []
		if _r.success:
			Handle.saving_window.label.set_text.call_deferred("Checking up differences between commits...")
			var _old_data: Dictionary = load_file_data(_path, false).strings
			for _entry_name: String in Handle.strings.keys():
				if _old_data.has(_entry_name):
					var _old_entry: Array = _old_data[_entry_name]
					var _new_entry: Array = Handle.strings[_entry_name]
					var _i := 0
					for _entry: IStringContainer in _new_entry:
						if _i >= _old_entry.size():
							break
						var _oentry: IStringContainer = _old_entry[_i]
						if _oentry.content != _entry.content:
							var _conflict := IGitConflict.new()
							_conflict.string_id = _entry.id
							_conflict.current_string = _entry.content
							_conflict.git_string = _oentry.content
							_conflicts.append(_conflict)
						_i += 1
		(func() -> void:
			_save_git_phase2_resolve(_path, _r.success, _conflicts)
		).call_deferred()
	)

# Phase 2 (solo git): SIEMPRE en MAIN. Maneja la UI de conflictos y, cuando se
# resuelve, lanza la fase de escritura.
func _save_git_phase2_resolve(_path: String, _pull_ok: bool, _conflicts: Array) -> void:
	if _presave_thread != null:
		_presave_thread.wait_to_finish()
		_presave_thread = null
	if not _pull_ok:
		if Handle.saving_window != null:
			Handle.saving_window.queue_free()
		io_in_progress = false
		return
	if _conflicts.is_empty():
		_save_phase_write(_path)
		return
	# Crear gc_window aquí, en main; ya no hay race con el worker.
	Handle.gc_window = Handle.gc_scene.instantiate()
	Handle.gc_window.conflicts = _conflicts
	# Conectamos ANTES de add_child para no perder el evento si por algún motivo
	# la ventana se cerrara inmediatamente.
	Handle.gc_window.tree_exited.connect(func() -> void:
		for _conflict: IGitConflict in _conflicts:
			var _strt: IStringTable = Handle.string_table[_conflict.string_id]
			match _conflict.keep:
				IGitConflict.IKeep.KeepGit:
					_strt.data.content = _conflict.git_string
					# Bug fix: sin esto, string_ids[id] queda apuntando al
					# content viejo. AddString usa string_ids para detectar
					# strings con el mismo original_content y construir grupos
					# de "similar entries", así que un conflicto resuelto
					# rompía el cálculo hasta el siguiente reload del archivo.
					Handle.string_ids[_conflict.string_id] = _conflict.git_string
				IGitConflict.IKeep.KeepOriginal:
					_strt.data.content = _conflict.current_string
					Handle.string_ids[_conflict.string_id] = _conflict.current_string
		_save_phase_write(_path)
	, CONNECT_ONE_SHOT)
	Handle.main_node.add_child(Handle.gc_window)

# Bloque 3: construye el array de strings (líneas serializadas) que
# representa el estado actual de Handle.strings en formato del .txt.
# Reusable desde _save_phase_write y desde el autosave de MainNode.
# El callback opcional `_progress_cb` recibe el contador acumulado de
# strings procesadas, para refrescar barras de progreso del save normal.
# El autosave lo ignora.
func _build_save_payload(_progress_cb: Callable = Callable()) -> Array:
	var _data: Array = []
	var _v: int = 0
	var _fe := IFormatEntry.new()
	_fe.kind = 9
	_fe.data.Style = Handle.style
	_data.append(_fe)
	for key: String in Handle.strings.keys():
		_fe = IFormatEntry.new()
		_fe.kind = 0
		_fe.data.ID = key
		_data.append(str(_fe))
		for _entry: IStringContainer in Handle.strings[key] as Array:
			_data.append(str(_entry))
			if _progress_cb.is_valid():
				_progress_cb.call(_v)
			_v += 1
	_fe = IFormatEntry.new()
	_fe.kind = 8
	_data.append(str(_fe))
	return _data

# Phase write: escritura del archivo en thread. Al terminar, libera la ventana
# de progreso, hace commit si hay git, y limpia io_in_progress.
func _save_phase_write(_path: String) -> void:
	_write_thread = Thread.new()
	_write_thread.start(func() -> void:
		Handle.saving_window.label.set_text.call_deferred("Saving...")
		# Bug fix: la barra de guardado nunca tenía max_value y se saturaba al
		# 100% en los primeros 100 strings. Sumamos el total ANTES del bucle.
		var _total_strings: int = 0
		for _key_count: String in Handle.strings.keys():
			_total_strings += (Handle.strings[_key_count] as Array).size()
		Handle.saving_window.progress_bar.set_max.call_deferred(_total_strings)
		Handle.saving_window.progress_bar.set_value.call_deferred(0)
		var _data := _build_save_payload(func(_v: int) -> void:
			Handle.saving_window.progress_bar.set_value.call_deferred(_v)
		)
		Handle.saving_window.label.set_text.call_deferred("Saving the file...")
		var _ok := _write_data(_path, _data)
		if not _ok:
			Handle.saving_window.call_deferred("queue_free")
			io_in_progress = false
			_join_write_thread.call_deferred()
			return
		# Bug fix (race): estas asignaciones corren en el thread del save. El
		# setter de is_modified emite is_modified_changed; el handler en
		# MainNode (_on_is_modified_changed) toca un Timer, lo que NO es legal
		# desde un thread no-main. Con set_deferred la asignación —y por tanto
		# la señal— se procesa en el siguiente tick del main thread.
		Handle.set_deferred(&"is_modified", false)
		Handle.set_deferred(&"current_file_path", _path)
		if Handle.main_node != null:
			Handle.main_node.call_deferred(&"update_window_title")
			# Bloque 1: registrar en Open Recent. push_recent_file ignora rutas
			# de user:// (modo git) automáticamente, así que es seguro llamarla
			# en ambos caminos.
			Handle.main_node.call_deferred(&"push_recent_file", _path)
			# Bloque 3: el archivo se guardó OK; el autosave es ya basura,
			# lo descartamos para que no aparezca el diálogo de recuperación
			# en el próximo arranque.
			Handle.main_node.call_deferred(&"_discard_autosave_files")
		if FileAccess.file_exists("user://enable_git.bool"):
			Handle.saving_window.label.set_text.call_deferred("Commiting on the git repo...")
			var _r := Handle.git.commit("[DH] Update Strings")
			Handle.handle_git_output.call_deferred(_r)
			if !_r.success:
				Handle.saving_window.call_deferred("queue_free")
				io_in_progress = false
				_join_write_thread.call_deferred()
				return
		Handle.saving_window.call_deferred("queue_free")
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
func _write_data(_path: String, _data: Array) -> bool:
	var _payload := "\n".join(PackedStringArray(_data))

	# Caso simple: archivo nuevo. Sin baile de temporales.
	if not FileAccess.file_exists(_path):
		var _fnew := FileAccess.open(_path, FileAccess.WRITE)
		if _fnew == null:
			var _err_new := FileAccess.get_open_error()
			push_error("Failed to open %s for writing (error %d)" % [_path, _err_new])
			Handle.saving_window.label.set_text.call_deferred(
				"Error: could not save to\n%s\n(error %d)" % [_path, _err_new]
			)
			return false
		_fnew.store_string(_payload)
		_fnew.flush()
		_fnew.close()
		return true

	# Camino atómico para archivos existentes: escribir a .tmp y renombrar.
	var _tmp_path := _path + ".tmp"
	var _f := FileAccess.open(_tmp_path, FileAccess.WRITE)
	if _f == null:
		var _err := FileAccess.get_open_error()
		push_error("Failed to open %s for writing (error %d)" % [_tmp_path, _err])
		Handle.saving_window.label.set_text.call_deferred(
			"Error: could not save to\n%s\n(error %d)" % [_path, _err]
		)
		return false
	_f.store_string(_payload)
	_f.flush()
	_f.close()

	var _err_mv := DirAccess.rename_absolute(_tmp_path, _path)
	if _err_mv != OK:
		push_error("Failed to rename %s to %s (error %d)" % [_tmp_path, _path, _err_mv])
		Handle.saving_window.label.set_text.call_deferred(
			"Error: save file could not be finalized (error %d)" % _err_mv
		)
		# Limpiamos el .tmp que quedó huérfano para no dejar basura.
		# El archivo original sigue intacto (el rename falló, no llegó a tocarlo).
		if FileAccess.file_exists(_tmp_path):
			DirAccess.remove_absolute(_tmp_path)
		return false
	return true
