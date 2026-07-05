extends Window
class_name WAddString

# Entry de destino (la clave de Handle.strings donde vivirá la nueva string).
var entry: String = ""

# Datos de la string fuente para el modo "duplicar".
# Si source_index == -1, el diálogo se comporta en modo "blanco":
# clave y contenido vacíos, contenido editable, se agrega al final del entry.
var source_index: int = -1
var source_container: IStringContainer = null

@onready var clave_edit: LineEdit = $ClaveLineEdit
@onready var content_edit: TextEdit = $ContentTextEdit
@onready var edit_original_check: CheckBox = $EditOriginalCheck
@onready var edit_clave_check: CheckBox = $EditClaveCheck

# Regex que detecta los prefijos especiales:
#   - sp_<base>            (formato nuevo, primer duplicado)
#   - sp_<N>_<base>        (formato nuevo, duplicados sucesivos: sp_1_, sp_2_, ...)
#   - sp<N>_<base>         (formato legacy: sp1_, sp2_, ...)
# Sólo detecta el prefijo; nunca consume "_<dígitos>_" del medio del nombre base.
var _sp_rx: RegEx = RegEx.new()

func _ready() -> void:
	_sp_rx.compile("^sp_?\\d*_")

	if source_container != null:
		# Modo DUPLICAR: pre-rellenar con la fuente, contenido y clave bloqueados.
		# La clave que mostramos en el LineEdit es la que recibirá la nueva string.
		clave_edit.text = _preview_clave(source_container.clave, entry)
		clave_edit.editable = false
		edit_clave_check.button_pressed = false
		edit_clave_check.disabled = false

		content_edit.text = source_container.original_content
		content_edit.editable = false
		edit_original_check.button_pressed = false
		edit_original_check.disabled = false
	else:
		# Modo BLANCO: sin fuente, todo editable, sin bloqueo.
		clave_edit.text = ""
		clave_edit.editable = true
		edit_clave_check.button_pressed = true
		edit_clave_check.disabled = true

		content_edit.text = ""
		content_edit.editable = true
		# Como no hay fuente, no tiene sentido el toggle "editar original".
		edit_original_check.button_pressed = true
		edit_original_check.disabled = true

	# Solo damos el foco a la clave si es editable al inicio.
	if clave_edit.editable:
		clave_edit.grab_focus()

	# Colocamos el caret al final.
	clave_edit.caret_column = clave_edit.text.length()

# ---------------------------------------------------------------------------
# Helpers para el formato de claves sp_ / sp_1_ / sp_2_ / ...
# ---------------------------------------------------------------------------

# Devuelve la "base" de la clave (lo que va después del prefijo sp_/spN_/sp_N_).
# Si la clave no tiene prefijo sp_*, la devuelve sin tocar.
func _strip_sp_prefix(clave: String) -> String:
	var _m: RegExMatch = _sp_rx.search(clave)
	if _m == null:
		return clave
	return clave.substr(_m.get_end())

# True si la clave empieza con un prefijo sp_ reconocido (formato nuevo o legacy).
func _is_sp_clave(clave: String) -> bool:
	return _sp_rx.search(clave) != null

# Predice la clave que recibirá la nueva string: cuenta TODOS los miembros
# de la familia en la entry, porque la inserción ocurre al final de ella.
# - Ninguno previo: "sp_<base>"
# - N previos:      "sp_N_<base>"
# Anti-colisión: si la clave candidata ya existe en la entry (caso raro pero
# posible si el usuario editó las claves a mano), bumpeamos el contador hasta
# encontrar una libre. El cálculo refleja exactamente lo que hará luego
# _on_ok_button_pressed para que preview y resultado coincidan.
func _preview_clave(source_clave: String, target_entry: String) -> String:
	var _base: String = _strip_sp_prefix(source_clave)
	if _base == "":
		return "sp_"
	if not Handle.strings.has(target_entry):
		return "sp_" + _base
	var _arr: Array = Handle.strings[target_entry] as Array
	var _existing_claves := {}
	for _s: IStringContainer in _arr:
		_existing_claves[_s.clave] = true
	var _counter: int = 0
	for _s: IStringContainer in _arr:
		if _is_sp_clave(_s.clave) and _strip_sp_prefix(_s.clave) == _base:
			_counter += 1
	var _candidate := ("sp_" + _base) if _counter == 0 else ("sp_" + str(_counter) + "_" + _base)
	while _existing_claves.has(_candidate):
		_counter += 1
		_candidate = "sp_" + str(_counter) + "_" + _base
	return _candidate

# ---------------------------------------------------------------------------
# Handlers de UI
# ---------------------------------------------------------------------------

func _on_edit_clave_toggled(toggled_on: bool) -> void:
	clave_edit.editable = toggled_on
	if toggled_on:
		if clave_edit.has_focus():
			clave_edit.release_focus()
		clave_edit.call_deferred("grab_focus")
		clave_edit.caret_column = clave_edit.text.length()

func _on_edit_original_toggled(toggled_on: bool) -> void:
	content_edit.editable = toggled_on
	if toggled_on:
		if content_edit.has_focus():
			content_edit.release_focus()
		content_edit.call_deferred("grab_focus")

func _on_close_requested() -> void:
	queue_free()

func _on_cancel_button_pressed() -> void:
	queue_free()

func _on_ok_button_pressed() -> void:
	var _entries_arr: Array = Handle.strings[entry]
	var _insert_at: int

	if source_container != null and source_index >= 0:
		# Modo DUPLICAR: insertar al final de la familia sp_*_<base>.
		var _base := _strip_sp_prefix(source_container.clave)
		_insert_at = source_index + 1
		for _i in range(source_index + 1, _entries_arr.size()):
			var _s: IStringContainer = _entries_arr[_i]
			if _is_sp_clave(_s.clave) and _strip_sp_prefix(_s.clave) == _base:
				_insert_at = _i + 1
	elif source_index >= 0 and source_index < _entries_arr.size():
		_insert_at = source_index + 1
	else:
		_insert_at = _entries_arr.size()

	var _sc := IStringContainer.new()
	_sc.id = Handle.last_string_id
	Handle.last_string_id += 1
	_sc.original_content = content_edit.text
	_sc.content = _sc.original_content

	# Asignar clave contando los miembros de la familia presentes en TODA la
	# entry (no sólo los anteriores al punto de inserción). Bug fix: el código
	# anterior contaba sólo `range(_insert_at)`, así que si la familia estaba
	# fragmentada (p.ej.: B(sp_foo), src(sp_1_foo), C, D(sp_2_foo)), al duplicar
	# `src` calculaba "sp_2_foo", clave que YA tenía D. Además el preview
	# (_preview_clave) cuenta toda la entry, así que la clave mostrada al usuario
	# y la realmente generada divergían.
	# Defensa adicional: si por cualquier motivo la clave generada ya existe en
	# la entry, incrementamos el contador hasta encontrar una libre.
	if source_container != null and not edit_clave_check.button_pressed:
		var _base := _strip_sp_prefix(source_container.clave)
		var _existing_claves := {}
		for _s: IStringContainer in _entries_arr:
			_existing_claves[_s.clave] = true
		var _counter := 0
		for _s: IStringContainer in _entries_arr:
			if _is_sp_clave(_s.clave) and _strip_sp_prefix(_s.clave) == _base:
				_counter += 1
		var _candidate := ("sp_" + _base) if _counter == 0 else ("sp_" + str(_counter) + "_" + _base)
		while _existing_claves.has(_candidate):
			_counter += 1
			_candidate = "sp_" + str(_counter) + "_" + _base
		_sc.clave = _candidate
	else:
		_sc.clave = clave_edit.text

	if source_container != null:
		_sc.font_style = source_container.font_style
		_sc.box_style = source_container.box_style
		_sc.speaker = source_container.speaker
		_sc.enable_portrait = source_container.enable_portrait
	_sc.layer_strings = [_sc.content]
	while _sc.layer_strings.size() < Handle.layers:
		_sc.layer_strings.append("")
	_sc.layer_colors = []
	while _sc.layer_colors.size() < Handle.layers:
		_sc.layer_colors.append(Color.WHITE)
	_sc.equal_strings = []

	_entries_arr.insert(_insert_at, _sc)

	Handle.string_table[_sc.id] = IStringTable.new(entry, _sc.content, _insert_at, _sc)
	Handle.string_ids[_sc.id] = _sc.content

	for _i in range(_insert_at + 1, _entries_arr.size()):
		var _c: IStringContainer = _entries_arr[_i]
		if Handle.string_table.has(_c.id):
			(Handle.string_table[_c.id] as IStringTable).index = _i

	if Handle.string_sstr.has(_sc.original_content):
		_sc.equal_strings_index = Handle.string_sstr[_sc.original_content]
		_sc.equal_strings = Handle.string_sstr_arr[_sc.equal_strings_index]
		_sc.equal_strings.append(_sc.id)
	else:
		var _eqstr: Array[int] = []
		for _key: int in Handle.string_ids.keys():
			if Handle.string_ids[_key] == _sc.original_content:
				_eqstr.append(_key)
		if _eqstr.size() > 1:
			var _index_eq := Handle.string_sstr_arr.size()
			Handle.string_sstr[_sc.original_content] = _index_eq
			Handle.string_sstr_arr.append(_eqstr)
			_sc.equal_strings = _eqstr
			_sc.equal_strings_index = _index_eq
			for _key in _eqstr:
				var _strg: IStringContainer = Handle.string_table[_key].data
				_strg.equal_strings = _eqstr
				_strg.equal_strings_index = _index_eq

	Handle.string_size += 1

	var _parent: WDialogueHelper = get_parent()
	_parent.string_selector.clear()
	for _s: IStringContainer in _entries_arr:
		# Bloque 1: prefijo de progreso por string.
		_parent.string_selector.add_item(_parent._string_progress_prefix(_s) + _s.content)
	_parent.string_selector.select(_insert_at)
	_parent.string_selector.ensure_current_is_visible()
	_parent._on_item_list_item_selected_str(_insert_at)

	# La entry pasó de "∅" (si estaba vacía) o sigue en "·" (si ya tenía
	# strings sin traducir). Refrescamos el prefijo de la entry y las stats.
	if entry != "":
		_parent.refresh_entry_item_prefix(entry)
	_parent.update_progress_stats_label()

	Handle.is_modified = true
	queue_free()
