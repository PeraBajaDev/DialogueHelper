extends Control
class_name WDialogueHelper

# Explicit preload so this helper script is packaged in exports that use
# export_filter="resources". Without this dependency, exported builds can fail
# to find IReferenceTable unless an external Scripts folder is next to the exe.
const ReferenceTable = preload("res://Scripts/IReferenceTable.gd")

var font := IFont.new()
var search_kind := 1
var author := "DefaultUsername"

@onready var similar_entries: ItemList = $SimilarEntries/ItemList
@onready var box: WBox = $Box
@onready var dialogue_edit: TextEdit = $DialogueEdit
@onready var original_dialogue: TextEdit = $DialogueEdit/OriginalDialogue
# Bloque 2: panel del validador y checkbox de "necesita revisión".
# Movidos a la barra superior ($Panel/...) en el primer round de fixes:
# antes estaban dentro de DialogueEdit y quedaban fuera de la zona visible
# (DialogueEdit mide 86 px de alto, los nodos iban a y=160+).
# Issue #2: el checkbox se ha movido de nuevo, ahora a $DisplaySettings/
# (debajo del SpinBox de Box, ver Main.tscn). El TagValidatorLabel sigue
# en la barra superior. has_node defensivo por si alguien usa un .tscn
# antiguo con el checkbox aún en $Panel/.
@onready var tag_validator_label: Label = $Panel/TagValidatorLabel if has_node("Panel/TagValidatorLabel") else null
@onready var closed_sign_validator_label: Label = $Panel/ClosedSignValidatorLabel if has_node("Panel/ClosedSignValidatorLabel") else null
@onready var needs_review_check: CheckBox = (
	$DisplaySettings/NeedsReviewCheck if has_node("DisplaySettings/NeedsReviewCheck")
	else ($Panel/NeedsReviewCheck if has_node("Panel/NeedsReviewCheck") else null)
)
@onready var current_layer_node: SpinBox = $DisplaySettings/CurrentLayer/Num
@onready var current_box_node: SpinBox = $DisplaySettings/CurrentBox/Num
@onready var current_font_node: SpinBox = $DisplaySettings/CurrentFont/Num
@onready var current_color_node: ColorPickerButton = $DisplaySettings/CurrentColor/Picker
@onready var current_scale_node: SpinBox = $DisplaySettings/CurrentScale/Num

@onready var current_box_label: Label = $DisplaySettings/CurrentBox/Info
@onready var current_font_label: Label = $DisplaySettings/CurrentFont/Info
@onready var dialogue_selector: ItemList = $EntryList
@onready var string_selector: ItemList = $StringSelector/ItemList
# Label de estadísticas globales del bloque 1. Vive en la barra superior
# ($Panel/ProgressStats), anclado a la derecha al lado del botón "Reload
# Style". Antes estaba bajo el EntryList, pero allí se solapaba con los
# items y el fondo transparente lo hacía ilegible. has_node() defensivo
# por si alguien usa una versión antigua del .tscn sin el nodo.
@onready var progress_stats_label: Label = $Panel/ProgressStats if has_node("Panel/ProgressStats") else null

@onready var replace_similar: CheckBox = $DialogueEdit/ReplaceSimilar
@onready var enable_portrait: CheckBox = $DialogueEdit/EnablePortrait
@onready var add_entry: Button = $DialogueEdit/AddEntry
@onready var add_string: Button = $DialogueEdit/AddString

@onready var tree: SceneTree = get_tree()
@onready var panel: Control = $Panel
@onready var display_settings: Control = $DisplaySettings
@onready var string_selector_parent: Control = $StringSelector
@onready var similar_entries_parent: Control = $SimilarEntries

var current_layer := 0
var current_font_id := 0
var current_box := 0

# Bug fix (decoupling): "qué entry y qué string están cargadas en el editor"
# se resolvía leyendo dialogue_selector.get_selected_items() y
# string_selector.get_selected_items(). Eso fallaba cuando el usuario
# navegaba a una entry filtrada vía Search/GoTo/Similar: el editor cargaba
# la entry buscada pero dialogue_selector se quedaba con la anterior (o
# vacío), y los handlers de edición leían el nombre de una entry y el índice
# de otra (crash o corrupción de datos), o salían por la cláusula
# `if _ds_sel.is_empty(): return` y la edición parecía no tener efecto y
# string_selector no respondía a clicks.
#
# Estas variables son la fuente única de verdad para "lo que está cargado
# en el editor ahora mismo". Se actualizan desde change_to() y desde
# _on_item_list_item_selected_str. dialogue_selector y string_selector pasan
# a ser sólo UI: el filtro queda como una vista pura, y el editor sigue
# funcionando aunque la entry cargada no aparezca en la lista filtrada.
# Cadena vacía / -1 = nada cargado.
var current_entry: String = ""
var current_string_index: int = -1

# Debounce de refresco de UI tras editar dialogue_edit. El handler hace dos
# tipos de trabajo: (a) escribir los datos en IStringContainer/Handle —
# barato, lo dejamos síncrono para que un save inmediato siempre vea los
# valores correctos—; (b) refrescar UI — caro porque refresh_entry_item_prefix
# corre ITagValidator.validate_string (regex compile + search_all) por cada
# string traducida de cada entry afectada, y replace_similar puede tocar
# varias entries por tecla. Coalescemos (b) en un Timer: cada tecla añade al
# pendiente y reinicia el Timer; tras _EDIT_REFRESH_DEBOUNCE_S sin teclear,
# _flush_edit_refresh aplica todo. update_tag_validator_label se queda
# síncrono (una sola regex, da feedback en vivo sobre la string actual).
const _EDIT_REFRESH_DEBOUNCE_S: float = 0.25
# Debe coincidir con la preview de Deltarune: cada TAB de los textos de
# diálogo ocupa una celda. TextEdit también dibuja una marca visible para
# distinguirlo de un espacio sin modificar el contenido subyacente.
const _DIALOGUE_EDITOR_TAB_SIZE: int = 1
var _edit_refresh_timer: Timer = null
var _entries_to_refresh_pending: Dictionary = {}
var _stats_count_changed_pending: bool = false

# Estado para saber si la línea anterior tenía etiqueta de retrato
var prev_has_portrait: bool = false

# QoL: estado previo para actualizar el título solo cuando cambia.
var _prev_is_modified: bool = false
var _prev_file_path: String = ""

# Fix bug "is_modified falso positivo": cuando asignamos `dialogue_edit.text` por
# código (al cambiar de string, capa o limpiar), TextEdit emite text_changed igual
# que si el usuario hubiera tecleado. Para distinguirlo, alzamos este flag durante
# las asignaciones programáticas y _on_dialogue_edit_text_changed sale temprano.
var _suppress_text_signal: bool = false

# True cuando el contenido actual proviene de abrir un archivo desde disco
# (flujo open/open recent/recover de autosave de archivo existente).
# False cuando el usuario creó un archivo nuevo (new_file_flow / clear_data).
# Se usa para:
#   - Deshabilitar "Add new Entry" (entries no deben crearse en archivos abiertos).
#   - Deshabilitar "Delete Selected Entry" (no puede haber entries extras en abiertos).
#   - "Delete Selected String" se controla por prefijo sp_ (ver _update_file_menu_items).
var _file_was_opened: bool = false

# CSV reference panel: optional local Google Sheets export used as a compact
# in-app reference for notes and machine-translation drafts. It is keyed by
# IStringContainer.clave and intentionally does not write anything into the
# opened .txt.
var reference_table: ReferenceTable = ReferenceTable.new()
var _reference_fd_window: FileDialog = null
var reference_panel: PanelContainer = null
var reference_status_label: Label = null
var reference_notes_edit: TextEdit = null
var reference_es_en_edit: TextEdit = null
var reference_es_jp_edit: TextEdit = null
var reference_body: HBoxContainer = null
var reference_toggle_button: Button = null
var reference_panel_collapsed := true
const _REFERENCE_PANEL_MARGIN := 6.0
const _REFERENCE_PANEL_EXPANDED_H := 160.0
const _REFERENCE_PANEL_COLLAPSED_H := 30.0
const _REFERENCE_PANEL_FONT_SIZE := 14

@onready var file_popup: PopupMenu = ($Panel/MenuBar/Container/File as MenuButton).get_popup()
@onready var about_popup: PopupMenu = ($Panel/MenuBar/Container/About as MenuButton).get_popup()

# Bloque 1: submenu de "Open Recent". Se construye en _ready, se rellena
# cada vez que el menú File se va a mostrar (about_to_popup), y dispara
# _open_recent_selected con el índice elegido.
var recent_popup: PopupMenu = null

var last_thread: Thread = null
var last_sthread: Thread = null
var last_size := Vector2i.ZERO

# FileDialog del export JSON — se crea programáticamente en export_to_json_flow.
var _fdj_window: FileDialog = null

func _configure_dialogue_tab_visuals(_edit: TextEdit) -> void:
	# draw_tabs usa el indicador nativo de TextEdit (flecha/marca de tab según
	# el tema). No reemplaza U+0009 por un carácter visible ni toca el texto.
	_edit.draw_tabs = true
	_edit.draw_spaces = false
	_edit.set_tab_size(_DIALOGUE_EDITOR_TAB_SIZE)

func _ready() -> void:
	# Sólo los editores inferiores muestran los TAB. La preview sigue usando
	# sus propios glifos y su propio cálculo de posiciones.
	_configure_dialogue_tab_visuals(dialogue_edit)
	_configure_dialogue_tab_visuals(original_dialogue)
	# QoL: si se arrastra un .txt a la ventana, ahora respetamos los cambios sin guardar.
	tree.root.files_dropped.connect(_on_files_dropped)
	tree.auto_accept_quit = false
	tree.root.close_requested.connect(func() -> void:
		# Bug fix: si hay threads vivos al cerrar la app, Godot avisa con error
		# en consola por no haberlos esperado. Los unimos antes de salir.
		_join_pending_threads()
		if Handle.is_modified:
			Handle.uc_window = Handle.uc_scene.instantiate()
			Handle.uc_window.callback.connect(_on_unsaved_changes_confirmed.bind(tree.quit))
			add_child(Handle.uc_window)
		else:
			tree.quit(0)
	)
	tree.root.min_size = Vector2(1100, 700)
	if OS.has_environment("USERNAME"):
		author = OS.get_environment("USERNAME")
	elif OS.has_environment("USER"):
		author = OS.get_environment("USER")

	file_popup.id_pressed.connect(file_menu_selected)
	about_popup.id_pressed.connect(about_menu_selected)

	# Bloque 2: el toggle de "Review" actualiza el flag de la string actual.
	if needs_review_check != null:
		needs_review_check.toggled.connect(_on_needs_review_toggled)

	# Bloque 1: setup de "Open Recent". En Godot el submenu se asocia a un
	# item del popup mediante set_item_submenu_node(). El submenu se rellena
	# justo antes de mostrar el menú File (about_to_popup), no en _ready, para
	# que siempre refleje la lista persistida más reciente.
	recent_popup = PopupMenu.new()
	recent_popup.name = "RecentSubmenu"
	file_popup.add_child(recent_popup)
	var _recent_idx: int = file_popup.get_item_index(11)  # id 11 = "Open Recent"
	if _recent_idx != -1:
		file_popup.set_item_submenu_node(_recent_idx, recent_popup)
	recent_popup.id_pressed.connect(_on_recent_selected)
	file_popup.about_to_popup.connect(_rebuild_recent_submenu)
	file_popup.about_to_popup.connect(_update_file_menu_items)
	Handle.main_node = self

	# Timer del debounce de refresco de UI (ver constante arriba). Lo
	# instanciamos aquí, en _ready, para que sea hijo del MainNode y se
	# limpie automáticamente al cerrar el árbol.
	_edit_refresh_timer = Timer.new()
	_edit_refresh_timer.one_shot = true
	_edit_refresh_timer.wait_time = _EDIT_REFRESH_DEBOUNCE_S
	_edit_refresh_timer.timeout.connect(_flush_edit_refresh)
	add_child(_edit_refresh_timer)

	# QoL: mostrar los atajos (Ctrl+S, Ctrl+O, etc.) al lado de cada entrada del menú File.
	_setup_menu_accelerators()

	# Bug fix: cualquier editor de texto añade un \n al final del archivo. Si lo
	# leemos tal cual, ese newline acaba en el author, en la URL del repo y en
	# el nombre del branch, y rompe en sitios sutiles (URL inválida, branch
	# que git no encuentra, asterisco al lado del nombre del autor...).
	# strip_edges() limpia espacios y saltos al inicio/final.
	if FileAccess.file_exists("user://username.txt"):
		author = FileAccess.get_file_as_string("user://username.txt").strip_edges()
	if FileAccess.file_exists("user://enable_git.bool"):
		var _branch := ""
		if FileAccess.file_exists("user://git_branch.txt"):
			_branch = FileAccess.get_file_as_string("user://git_branch.txt").strip_edges()
		Handle.git.url = FileAccess.get_file_as_string("user://git_url.txt").strip_edges()
		Handle.git.branch = _branch
	if FileAccess.file_exists("user://scale.txt"):
		var _raw := FileAccess.get_file_as_string("user://scale.txt").strip_escapes().strip_edges()
		var _v := float(_raw)
		if _v > 0.0:
			current_scale_node.value = _v
			Handle.visual_scale = _v  # Sync para evitar is_modified=true espurio en el primer frame.

	current_layer_node.max_value = Handle.layers
	current_font_node.max_value = 8
	current_box_node.max_value = 29

	# Tres caminos al arrancar:
	#  1) last_style.txt existe Y apunta a un Style que sigue en disco
	#     → respetamos la preferencia.
	#  2) last_style.txt no existe, está vacío, o apunta a un Style que el
	#     usuario borró
	#     → tratamos como primer arranque: cargamos el default y, si hay 2+
	#       Styles disponibles, preguntamos. NO usamos el fallback silencioso
	#       de load_style aquí, porque preferimos pedir al usuario que decida
	#       cuál quiere usar antes que asumir uno por él.
	#  3) load_style mantiene un fallback automático interno como red de
	#     seguridad para llamadas que no son el arranque (Settings, Reload
	#     Style, etc.). Si por carrera de archivos el Style desaparece justo
	#     entre listar y cargar, no se cuelga la app.
	var _stored_style: String = ""
	if FileAccess.file_exists("user://last_style.txt"):
		_stored_style = FileAccess.get_file_as_string("user://last_style.txt").strip_edges()

	var _stored_is_valid: bool = _stored_style != "" \
		and FileAccess.file_exists(Handle.style_get_path("Metadata.json", _stored_style))

	if _stored_is_valid:
		Handle.load_style(_stored_style)
	else:
		Handle.load_style(Handle.pick_default_style())
		if Handle.list_available_styles().size() >= 2:
			# Diferimos al siguiente frame para que el resto de _ready termine
			# de configurar la UI antes de superponer el diálogo modal.
			call_deferred("_show_style_picker")
	font = IFont.get_font(Handle.current_font)
	update_box(current_box, false)
	update_font(current_font_id, false)
	Handle.is_modified = false
	# QoL: establecer el título inicial de la ventana.
	update_window_title()
	# Menú contextual: añadir "Copy Clave name" a los TextEdits de traducción
	# y de original. La caja de preview es otro Control y no se toca.
	_setup_textedit_clave_menu(dialogue_edit)
	_setup_textedit_clave_menu(original_dialogue)
	# CSV de referencia: panel compacto con Notas / ES desde EN / ES desde JP.
	_setup_reference_panel()
	# Bloque 3: inicializar timers y señales de autosave, y disparar el
	# diálogo de recuperación si hay un autosave huérfano de una sesión
	# anterior. Diferido para que el resto de la UI esté lista cuando
	# se superponga el diálogo modal (de existir).
	_ready_autosave()
	call_deferred("_check_autosave_recovery")

func _process(_delta: float) -> void:
	if last_size != tree.root.size:
		last_size = tree.root.size
		panel.size.x = tree.root.size.x
		display_settings.position.x = tree.root.size.x - (1100 - 876)

		string_selector_parent.position.x = tree.root.size.x - (1100 - 881)
		similar_entries_parent.position.x = tree.root.size.x - (1100 - 879)
		box.size.x = tree.root.size.x - (1100 - 580)
		box.size.y = tree.root.size.y - (700 - 400)
		dialogue_edit.position.y = tree.root.size.y - (700 - 530)
		dialogue_edit.size.x = tree.root.size.x - (1100 - 587)
		original_dialogue.size.x = tree.root.size.x - (1100 - 587)
		_update_reference_panel_layout()
		add_string.position.x = (dialogue_edit.size.x - 587) + 449
		replace_similar.position.x = (dialogue_edit.size.x - 587) + 353
		dialogue_selector.size.y = tree.root.size.y - (700 - 602)
		# Issue #2: la altura por defecto del ItemList de StringSelector pasó
		# de 359 a 329 al achicar el panel por arriba (offset_top de
		# StringSelector se bajó de 295 a 325, offset_bottom del ItemList
		# de 393 a 363, así el borde inferior absoluto se mantiene en 688).
		# La constante de la fórmula DEBE coincidir con el nuevo
		# offset_bottom - offset_top del ItemList; si no, en el primer
		# resize el ItemList "salta" a un tamaño incorrecto.
		string_selector.size.y = tree.root.size.y - (700 - 329)

	current_font_node.max_value = Handle.font_data.size()
	current_box_node.max_value = Handle.box_data.size()
	# Bug fix (decoupling): habilitar/deshabilitar Add String según haya una
	# entry cargada en el editor, no según la selección visual del
	# dialogue_selector — que puede estar desincronizada con un filtro.
	add_string.disabled = (current_entry == "" or not Handle.strings.has(current_entry))
	# "Add new Entry" solo tiene sentido en archivos nuevos: en archivos abiertos
	# las entries son fijas y no se deben crear nuevas.
	add_entry.disabled = _file_was_opened
	enable_portrait.disabled = !box.supports_portrait
	box.portrait_enabled = enable_portrait.button_pressed
	if int(current_layer_node.value) - 1 != current_layer:
		current_layer = int(current_layer_node.value) - 1
		current_color_node.color = Handle.layer_colors[current_layer]
		_set_dialogue_edit_text_silent(str(Handle.layer_strings[current_layer]))
		dialogue_edit.clear_undo_history()
		# El cuadro de "diálogo original" lo actualiza el bloque de Handle.og_str
		# unas líneas más abajo; antes lo sobrescribíamos aquí con basura y se
		# corregía en el mismo frame, causando parpadeo.
	if current_font_node.value - 1 != current_font_id:
		var _new_font := int(current_font_node.value - 1)
		# Detectar si esto es sincronización con la string seleccionada (cambió
		# el SpinBox porque cambió la string activa) o si fue el usuario quien
		# pulsó el SpinBox. Si el valor coincide con el font_style de la string
		# actual, es sync y NO hay que marcar is_modified ni reescribir nada.
		# Bug fix (decoupling): leíamos dialogue_selector + string_selector,
		# pero con una entry filtrada esos no apuntan a la string cargada.
		# Vamos por _get_current_string_container, que consulta current_entry
		# y current_string_index.
		var _is_sync := false
		var _stri_ref: IStringContainer = _get_current_string_container()
		if _stri_ref != null and _stri_ref.font_style == _new_font:
			_is_sync = true
		update_font(_new_font, !_is_sync)
		if !_is_sync && _stri_ref != null:
			_stri_ref.font_style = current_font_id
	if current_box_node.value - 1 != current_box:
		var _new_box := int(current_box_node.value - 1)
		var _is_sync_b := false
		var _stri_ref_b: IStringContainer = _get_current_string_container()
		if _stri_ref_b != null:
			# Issue #3: además del valor guardado en `box_style`,
			# aceptamos como "sync" cualquier valor que coincida con
			# `_resolve_box_style`. Sin esto, al seleccionar una
			# string sin asterisco la regla del asterisco fija el
			# SpinBox en Box7, _process detecta el cambio, no
			# encuentra match con `box_style` (que sigue siendo 0)
			# y marca el archivo como modificado al instante.
			if _stri_ref_b.box_style == _new_box:
				_is_sync_b = true
			elif _resolve_box_style(_stri_ref_b) == _new_box:
				_is_sync_b = true
		update_box(_new_box, !_is_sync_b)
		if !_is_sync_b && _stri_ref_b != null:
			_stri_ref_b.box_style = current_box
	if current_scale_node.value != Handle.visual_scale:
		Handle.is_modified = true
		Handle.visual_scale = current_scale_node.value
		box.handle.queue_redraw()
		box.spr.scale = Vector2(Handle.visual_scale, Handle.visual_scale)
		_request_scale_save()
	while Handle.layer_strings.size() < Handle.layers:
		Handle.layer_strings.append("")
	while Handle.layer_colors.size() < Handle.layers:
		Handle.layer_colors.append(Color.WHITE)
	Handle.layer_strings[current_layer] = dialogue_edit.text
	if Handle.layer_colors[current_layer] != current_color_node.color:
		Handle.is_modified = true
		Handle.layer_colors[current_layer] = current_color_node.color
	if original_dialogue.text != Handle.og_str:
		original_dialogue.text = Handle.og_str
	# Nota: aquí había una pasada por frame que copiaba dialogue_edit.text en
	# `current.content` y en `Handle.string_ids[id]` (red de seguridad para
	# si la señal text_changed no disparaba). Tracé los dos caminos:
	# `_on_dialogue_edit_text_changed` ya cubre layer 0 — escribe a content y
	# string_ids — y para `current_layer != 0` content no debe mutar de todos
	# modos (queda igual al valor de layer_strings[0]). Toda mutación de
	# dialogue_edit.text en el editor pasa por text_changed (paste, undo,
	# tecleo); las asignaciones programáticas van por
	# `_set_dialogue_edit_text_silent`, que es por definición "no cuenta como
	# edición". Quitarlo elimina N escrituras por frame en archivos grandes
	# sin afectar correctness.
	if last_thread is Thread:
		if !last_thread.is_alive():
			last_thread.wait_to_finish()
			last_thread = null

	# QoL: refrescar el título cuando cambia el estado relevante (ahorra trabajo por frame).
	if _prev_is_modified != Handle.is_modified or _prev_file_path != Handle.current_file_path:
		_prev_is_modified = Handle.is_modified
		_prev_file_path = Handle.current_file_path
		update_window_title()

# ---------------------------------------------------------------------------
# QoL: atajos de teclado y título
# ---------------------------------------------------------------------------

# Se llama cuando una tecla pasa por todos los Control enfocados sin ser consumida.
# De este modo no rompemos las shortcuts internas de TextEdit (Ctrl+C/V/X/Z, etc.).
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var ke: InputEventKey = event
	if not ke.pressed or ke.echo:
		return
	# Exigimos Ctrl, pero NO Alt ni Meta (evita colisiones con atajos del SO).
	if not ke.ctrl_pressed or ke.alt_pressed or ke.meta_pressed:
		return
	# Si hay una operación de disco en curso, ignoramos los atajos.
	if _io_busy():
		return

	match ke.keycode:
		KEY_S:
			if ke.shift_pressed:
				save_as_flow()
			else:
				save_file_flow()
			get_viewport().set_input_as_handled()
		KEY_O:
			if ke.shift_pressed:
				return
			open_file_flow()
			get_viewport().set_input_as_handled()
		KEY_W:
			if ke.shift_pressed:
				return
			close_file_flow()
			get_viewport().set_input_as_handled()
		KEY_Q:
			if ke.shift_pressed:
				return
			quit_flow()
			get_viewport().set_input_as_handled()
		KEY_F:
			if ke.shift_pressed:
				return
			open_search_menu()
			get_viewport().set_input_as_handled()
		KEY_G:
			if ke.shift_pressed:
				return
			open_go_to_menu()
			get_viewport().set_input_as_handled()
		# La navegación por teclado (Ctrl+↑/↓ para strings, Alt+↑/↓ para
		# entries) NO se gestiona aquí. _unhandled_key_input solo recibe la tecla
		# si NINGÚN control enfocado la consumió antes, y el editor de texto se
		# "come" las flechas (mover cursor, seleccionar, scroll), así que estando
		# dentro del recuadro el atajo nunca llegaba. Por eso la navegación vive
		# ahora en _input(), que intercepta el evento ANTES que el editor. Ver
		# _input() más abajo.

# Navegación por teclado. Se gestiona en _input() —y NO en _unhandled_key_input()—
# a propósito: _input() recibe el evento ANTES que el control enfocado, de modo
# que la navegación funciona también con el foco dentro del editor de texto, que
# de otro modo consumiría las flechas (mover cursor, seleccionar, hacer scroll) y
# el atajo nunca llegaría. set_input_as_handled() evita que el editor reaccione
# además a la flecha. Tras navegar dejamos el foco en el editor (con el cursor al
# final) para poder escribir de inmediato sin tocar el ratón.
#   Ctrl + ↑ / ↓  → string anterior / siguiente (dentro de la entry)
#   Alt + ↑ / ↓   → entry anterior / siguiente
# Se usan ↑/↓ (no ←/→) porque ambas listas son verticales y porque ←/→ las
# necesita el editor para mover el cursor carácter a carácter.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var ke: InputEventKey = event
	if not ke.pressed:
		return
	# OJO: aquí NO filtramos ke.echo. Godot marca como echo los eventos
	# repetidos al mantener pulsada una tecla; dejarlos pasar es justo lo
	# que permite mantener Ctrl/Alt + ↑/↓ para navegar rápido. Los atajos
	# de menú (Ctrl+S/O/etc.) siguen filtrando echo en _unhandled_key_input.
	# Solo nos interesan ↑/↓; cualquier otra tecla se deja pasar intacta.
	if ke.keycode != KEY_UP and ke.keycode != KEY_DOWN:
		return
	# Meta (tecla Win/Cmd) no se usa aquí: evita colisiones con atajos del SO.
	if ke.meta_pressed:
		return
	# Modificadores EXCLUSIVOS: Ctrl-solo mueve strings; Alt-solo mueve entries.
	# Cualquier otra combinación (Shift de por medio, los dos a la vez, o ninguno)
	# no hace nada y deja pasar el evento, para no romper la edición/selección
	# normal del texto.
	var _only_ctrl: bool = ke.ctrl_pressed and not ke.alt_pressed and not ke.shift_pressed
	var _only_alt: bool = ke.alt_pressed and not ke.ctrl_pressed and not ke.shift_pressed
	if not (_only_ctrl or _only_alt):
		return
	# Si hay una operación de disco en curso, ignoramos los atajos.
	if _io_busy():
		return
	var _delta: int = -1 if ke.keycode == KEY_UP else 1
	if _only_ctrl:
		_nav_string(_delta)
	else:
		_nav_entry(_delta)
	# Dejar el recuadro listo para escribir (flujo 100% teclado).
	_focus_dialogue_edit_for_keyboard()
	get_viewport().set_input_as_handled()

# Deja el foco en el editor de diálogo con el cursor al final y sin selección, de
# modo que justo después de navegar con el teclado se pueda escribir al instante
# sin necesidad de hacer click en el recuadro. Se llama tras cada navegación.
func _focus_dialogue_edit_for_keyboard() -> void:
	if not is_instance_valid(dialogue_edit):
		return
	dialogue_edit.grab_focus()
	var _last_line: int = maxi(dialogue_edit.get_line_count() - 1, 0)
	dialogue_edit.deselect()
	dialogue_edit.set_caret_line(_last_line)
	dialogue_edit.set_caret_column(dialogue_edit.get_line(_last_line).length())

# Navegación por teclado entre STRINGS de la entry cargada (Ctrl+↑ / Ctrl+↓).
# Mueve la selección de string_selector y dispara el mismo handler que un click,
# porque select() no emite la señal item_selected por sí solo.
func _nav_string(_delta: int) -> void:
	if current_entry == "" or not Handle.strings.has(current_entry):
		return
	var _count: int = string_selector.get_item_count()
	if _count == 0:
		return
	# Sin string cargada todavía: la primera pulsación selecciona la primera.
	if current_string_index < 0:
		string_selector.select(0)
		string_selector.ensure_current_is_visible()
		_on_item_list_item_selected_str(0)
		return
	var _new: int = clampi(current_string_index + _delta, 0, _count - 1)
	if _new == current_string_index:
		return
	string_selector.select(_new)
	string_selector.ensure_current_is_visible()
	_on_item_list_item_selected_str(_new)

# Navegación por teclado entre ENTRIES (Alt+↑ / Alt+↓).
# Opera sobre dialogue_selector, que puede estar filtrado por Search/GoTo, así
# que el índice actual se resuelve por selección visible y, si no, por nombre.
func _nav_entry(_delta: int) -> void:
	var _count: int = dialogue_selector.get_item_count()
	if _count == 0:
		return
	var _cur: int = -1
	var _sel: PackedInt32Array = dialogue_selector.get_selected_items()
	if _sel.size() > 0:
		_cur = _sel[0]
	else:
		for _i in _count:
			if dialogue_selector_entry_at(_i) == current_entry:
				_cur = _i
				break
	var _new: int
	if _cur == -1:
		# La entry cargada no está en la lista visible (filtro activo): arrancamos
		# por el extremo correspondiente al sentido de la pulsación.
		_new = 0 if _delta > 0 else _count - 1
	else:
		_new = clampi(_cur + _delta, 0, _count - 1)
		if _new == _cur:
			return
	dialogue_selector.select(_new)
	dialogue_selector.ensure_current_is_visible()
	# select() no emite item_selected; replicamos el click: change_to() limpia y
	# carga la entry, y se repuebla string_selector seleccionando la primera string.
	_on_item_list_item_selected(_new)

# Marca los aceleradores en el menú File (solo para MOSTRAR "Ctrl+S", etc. junto
# al texto). La lógica real vive en _unhandled_key_input() — así no se dispara
# dos veces.
# Nota: no añadimos acelerador a "New File" (id 6) a propósito — sin atajo Ctrl+N.
func _setup_menu_accelerators() -> void:
	_set_accel_if_present(1, KEY_MASK_CTRL | KEY_O)                   # Open File
	_set_accel_if_present(2, KEY_MASK_CTRL | KEY_S)                   # Save File
	_set_accel_if_present(8, KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_S)  # Save File As...
	_set_accel_if_present(7, KEY_MASK_CTRL | KEY_W)                   # Close File
	_set_accel_if_present(5, KEY_MASK_CTRL | KEY_Q)                   # Exit

# Helper tipado — evita los UNTYPED_DECLARATION / UNSAFE_CALL_ARGUMENT que salen
# cuando se itera un Array sin tipo.
func _set_accel_if_present(menu_id: int, accel: int) -> void:
	var _idx: int = file_popup.get_item_index(menu_id)
	if _idx != -1:
		file_popup.set_item_accelerator(_idx, accel)

# Actualiza el estado habilitado/deshabilitado de las opciones de borrado
# justo antes de mostrar el menú File. Se llama desde about_to_popup.
#
# Reglas:
#   - "Delete Selected Entry" (id 9): deshabilitado si el archivo proviene de
#     abrir desde disco (_file_was_opened). En archivos abiertos no debe haber
#     entries extras — y en archivos nuevos sí puede haber entries creadas por
#     el usuario que quiera eliminar.
#   - "Delete Selected String" (id 10): habilitado solo si la clave de la string
#     actualmente cargada comienza con "sp_". Ese prefijo se añade siempre a las
#     strings creadas manualmente (AddString.gd), así que es el discriminador
#     fiable de "string añadida por el usuario vs. string del archivo original",
#     y sobrevive guardados y reaperturas porque está en el propio nombre.
func _update_file_menu_items() -> void:
	var _idx_del_entry: int = file_popup.get_item_index(9)
	var _idx_del_string: int = file_popup.get_item_index(10)
	var _idx_clear_ref: int = file_popup.get_item_index(14)

	if _idx_del_entry != -1:
		file_popup.set_item_disabled(_idx_del_entry, _file_was_opened)

	if _idx_del_string != -1:
		var _clave: String = _get_current_clave()
		var _is_sp: bool = _clave.begins_with("sp_")
		file_popup.set_item_disabled(_idx_del_string, not _is_sp)

	if _idx_clear_ref != -1:
		file_popup.set_item_disabled(_idx_clear_ref, reference_table.source_path == "")

func _io_busy() -> bool:
	if IFileHandler.io_in_progress:
		return true
	return last_thread is Thread and last_thread.is_alive()

# Bug fix: al cerrar la app, esperamos los threads sueltos que hayamos dejado
# corriendo (carga de archivos, recálculo de "similar entries"...). Sin esto,
# Godot saca un error en consola por threads no unidos. No se llama a quit
# desde aquí — el caller decide cuándo terminar.
func _join_pending_threads() -> void:
	if last_thread is Thread:
		last_thread.wait_to_finish()
		last_thread = null
	if last_sthread is Thread:
		last_sthread.wait_to_finish()
		last_sthread = null

# Muestra el diálogo de elección de Style. Sólo se llama en el primer arranque
# cuando hay 2+ Styles disponibles. Diferido al siguiente frame desde _ready
# para que la UI principal esté ya en su sitio cuando se superponga el modal.
func _show_style_picker() -> void:
	var _w := preload("res://Subwindows/StyleSelector.tscn").instantiate()
	add_child(_w)

# Helper: asigna texto al editor sin disparar la lógica de "edición del usuario".
# Lo usamos en cualquier sitio que reescriba `dialogue_edit.text` por motivos
# que NO son una pulsación del usuario (cambio de string, cambio de capa,
# clear_data...). Sin esto, esas asignaciones disparan text_changed y
# is_modified termina marcado a true por nada.
func _set_dialogue_edit_text_silent(_t: String) -> void:
	_suppress_text_signal = true
	dialogue_edit.text = _t
	_suppress_text_signal = false

# ---------------------------------------------------------------------------
# Indicadores de progreso de traducción (Bloque 1)
# ---------------------------------------------------------------------------
# Cada item del dialogue_selector y del string_selector lleva un prefijo:
#   "✓ "  → todas las strings de la entry están traducidas (criterio:
#           tienen LastEdited). Para items de strings: la string lo está.
#   "· "  → al menos una string de la entry no está traducida. Para strings:
#           esa string concreta no.
#   "∅ "  → entry vacía (sin strings).
# El prefijo se aplica por código, no se guarda en Handle.entry_names ni en
# IStringContainer.content. Cuando se necesita el nombre real (al guardar,
# al buscar en Handle.strings, al cambiar de entry...), se llama a
# _strip_progress_prefix() para quitarlo.

const _PROGRESS_PREFIX_DONE: String = "✓ "
const _PROGRESS_PREFIX_TODO: String = "· "
const _PROGRESS_PREFIX_EMPTY: String = "∅ "
const _PROGRESS_PREFIX_UNCLOSED_SIGN = "¡? "
# Bloque 2: dos prefijos de "atención" con significados distintos:
#   ⚠  Tag mismatch — problema técnico (cantidad de tags no coincide con
#      el original). Rompe el juego si no se arregla. Tiene prioridad
#      sobre cualquier otro estado.
#   ★  Marcado por el usuario para revisar más tarde. No es un error,
#      es un recordatorio personal del traductor.
# El orden en el array determina cómo `_strip_progress_prefix` los
# detecta; lo importante es que ningún prefijo sea sufijo de otro.
const _PROGRESS_PREFIX_WARN: String = "⚠ "
const _PROGRESS_PREFIX_REVIEW: String = "★ "
const _PROGRESS_PREFIXES: Array[String] = ["✓ ", "· ", "∅ ","¡? ", "⚠ ", "★ "]

func _strip_progress_prefix(_text: String) -> String:
	for _p: String in _PROGRESS_PREFIXES:
		if _text.begins_with(_p):
			return _text.substr(_p.length())
	return _text

# Wrapper público: devuelve el nombre real (sin prefijo) del item del
# dialogue_selector en el índice indicado. Es el equivalente "limpio" de
# `dialogue_selector_entry_at(_i)` y debe usarse siempre que el valor
# se vaya a buscar en Handle.strings o comparar con un nombre real.
func dialogue_selector_entry_at(_index: int) -> String:
	if _index < 0 or _index >= dialogue_selector.get_item_count():
		return ""
	return _strip_progress_prefix(dialogue_selector.get_item_text(_index))

func _entry_progress_prefix(_entry_name: String) -> String:
	if not Handle.strings.has(_entry_name):
		return _PROGRESS_PREFIX_EMPTY
	var _arr: Array = Handle.strings[_entry_name]
	if _arr.is_empty():
		return _PROGRESS_PREFIX_EMPTY
	# Bloque 2: prioridad de prefijo (mismo orden que _state_to_prefix).
	# Tag mismatch tiene prioridad sobre review porque es un problema
	# técnico que rompe el juego, mientras que review es un recordatorio.
	var _has_mismatch: bool = false
	var _has_review: bool = false
	var _has_unclosed_sign: bool = false
	for _stri: IStringContainer in _arr:
		if _string_has_tag_mismatch(_stri):
			_has_mismatch = true
			break  # No hace falta seguir, mismatch ya gana
		if _stri.needs_review:
			_has_review = true
		_has_unclosed_sign = _string_has_misclosed_sign(_stri)
	if _has_mismatch:
		return _PROGRESS_PREFIX_WARN
	if _has_review:
		return _PROGRESS_PREFIX_REVIEW
	if _has_unclosed_sign:
		return _PROGRESS_PREFIX_UNCLOSED_SIGN
	if Handle.is_entry_fully_translated(_entry_name):
		return _PROGRESS_PREFIX_DONE
	return _PROGRESS_PREFIX_TODO

func _string_progress_prefix(_stri: IStringContainer) -> String:
	# Misma prioridad que en entries: mismatch > review > done > todo.
	if _string_has_tag_mismatch(_stri):
		return _PROGRESS_PREFIX_WARN
	if _stri != null and _stri.needs_review:
		return _PROGRESS_PREFIX_REVIEW
	if _string_has_misclosed_sign(_stri):
		return _PROGRESS_PREFIX_UNCLOSED_SIGN
	if Handle.is_string_translated(_stri):
		return _PROGRESS_PREFIX_DONE
	return _PROGRESS_PREFIX_TODO

# Bloque 2: validación de tags. Sólo se aplica si la string tiene tags
# relevantes (en original o en traducción). Una string sin tags no se
# considera "mismatch" — `validate_string` devuelve ok=true igualmente,
# pero centralizamos aquí por claridad.
func _string_has_tag_mismatch(_stri: IStringContainer) -> bool:
	if _stri == null:
		return false
	var _diff := ITagValidator.validate_string(_stri)
	return not _diff.ok

func _string_has_misclosed_sign(_stri: IStringContainer) -> bool:
	if _stri == null:
		return false
	var _diff := IClosedSignValidator.validate_string(_stri)
	return not _diff.ok
# Recalcula el prefijo del item de dialogue_selector que corresponde a la
# entry indicada. Si por algún motivo no se encuentra, no hace nada.
func refresh_entry_item_prefix(_entry_name: String) -> void:
	if dialogue_selector == null:
		return
	for _i in range(dialogue_selector.get_item_count()):
		var _txt := _strip_progress_prefix(dialogue_selector.get_item_text(_i))
		if _txt == _entry_name:
			dialogue_selector.set_item_text(_i, _entry_progress_prefix(_entry_name) + _entry_name)
			return

# Recalcula el prefijo de un item del string_selector. La string vista en el
# selector usa _stri.content como texto.
func refresh_string_item_prefix(_index: int, _stri: IStringContainer) -> void:
	if string_selector == null or _index < 0 or _index >= string_selector.get_item_count():
		return
	string_selector.set_item_text(_index, _string_progress_prefix(_stri) + _stri.content)

# Refresca todos los items de dialogue_selector. Útil tras cargar un archivo.
func refresh_all_entry_prefixes() -> void:
	if dialogue_selector == null:
		return
	for _i in range(dialogue_selector.get_item_count()):
		var _name := _strip_progress_prefix(dialogue_selector.get_item_text(_i))
		dialogue_selector.set_item_text(_i, _entry_progress_prefix(_name) + _name)

# Label de estadísticas globales: "1234 / 5678 strings (21.7%)"
func update_progress_stats_label() -> void:
	if progress_stats_label == null:
		return
	var _p := Handle.global_translation_progress()
	var _done: int = _p[0]
	var _total: int = _p[1]
	if _total == 0:
		progress_stats_label.text = "0 / 0 strings"
		return
	var _pct := 100.0 * float(_done) / float(_total)
	progress_stats_label.text = "%d / %d strings (%.1f%%)" % [_done, _total, _pct]

# ---------------------------------------------------------------------------
# Bloque 2: validador de tags y "needs review"
# ---------------------------------------------------------------------------
# El panel del validador se refresca cada vez que cambia la string seleccionada
# y cada vez que el usuario edita. Lo mismo para el checkbox de "review".
# Ambos son no-op si el .tscn antiguo no tiene los nodos.

# Refresca el label del validador para la string actualmente seleccionada.
# Si no hay string seleccionada, oculta el panel.
func update_tag_validator_label() -> void:
	if tag_validator_label == null:
		return
	var _stri := _get_current_string_container()
	if _stri == null:
		tag_validator_label.text = ""
		tag_validator_label.tooltip_text = ""
		return
	var _diff := ITagValidator.validate_string(_stri)
	# Bloque 2: si NI el original NI la traducción contienen tags, el panel
	# se queda vacío. Mostrar "✓ Tags OK" en cada línea de texto plano sólo
	# añade ruido visual sin informar de nada útil. El panel sólo aparece
	# cuando hay algo que validar (o cuando el usuario rompió la simetría
	# añadiendo tags donde no había).
	if not _diff.has_any_tag:
		tag_validator_label.text = ""
		tag_validator_label.tooltip_text = ""
		return
	tag_validator_label.text = _diff.to_label_text()
	# Color sobrio: verde apagado si OK, ámbar si hay mismatch.
	if _diff.ok:
		tag_validator_label.add_theme_color_override(&"font_color", Color(0.55, 0.85, 0.55))
		tag_validator_label.tooltip_text = "Tag count matches the original."
	else:
		tag_validator_label.add_theme_color_override(&"font_color", Color(1.0, 0.65, 0.4))
		tag_validator_label.tooltip_text = "Tag mismatch with the original. Check \\E[x], \\F[x], %, /, etc."

func update_closed_sign_validator_label() -> void:
	if closed_sign_validator_label == null:
		return
	var _stri := _get_current_string_container()

	if _stri == null:
		closed_sign_validator_label.text = ""
		closed_sign_validator_label.tooltip_text = ""
		return

	var _diff := IClosedSignValidator.validate_string(_stri)
	if not _diff.has_any_sign:
		closed_sign_validator_label.text = ""
		closed_sign_validator_label.tooltip_text = ""
		return
	closed_sign_validator_label.text = _diff.to_label_text()
	# Color sobrio: verde apagado si OK, ámbar si hay mismatch.
	if _diff.ok:
		closed_sign_validator_label.add_theme_color_override(&"font_color", Color(0.55, 0.85, 0.55))
		closed_sign_validator_label.tooltip_text = "Tag count matches the original."
	else:
		closed_sign_validator_label.add_theme_color_override(&"font_color", Color(1.0, 0.65, 0.4))
		closed_sign_validator_label.tooltip_text = "Tag mismatch with the original. Check \\E[x], \\F[x], %, /, etc."

# Sincroniza el estado del checkbox de "Review" con el flag de la string
# actual. Llamado al cambiar de string. Bloquea momentáneamente la señal
# `toggled` para no disparar _on_needs_review_toggled y volver a marcar el
# archivo como modificado por una asignación programática.
func update_needs_review_check() -> void:
	if needs_review_check == null:
		return
	var _stri := _get_current_string_container()
	if _stri == null:
		needs_review_check.set_pressed_no_signal(false)
		needs_review_check.disabled = true
		return
	needs_review_check.disabled = false
	needs_review_check.set_pressed_no_signal(_stri.needs_review)

# Devuelve el IStringContainer actualmente cargado en el editor, o null.
# Bug fix (decoupling): leía dialogue_selector + string_selector, lo que daba
# resultados inconsistentes cuando la entry cargada estaba filtrada y el
# usuario tocaba algún control (font/box/review). Ahora consulta directamente
# las variables de estado del editor.
func _get_current_string_container() -> IStringContainer:
	if current_entry == "" or current_string_index < 0:
		return null
	if not Handle.strings.has(current_entry):
		return null
	var _arr: Array = Handle.strings[current_entry]
	if current_string_index >= _arr.size():
		return null
	return _arr[current_string_index]

func _on_needs_review_toggled(_pressed: bool) -> void:
	var _stri := _get_current_string_container()
	if _stri == null:
		return
	if _stri.needs_review == _pressed:
		return  # Ya estaba en ese estado (sync programático).
	_stri.needs_review = _pressed
	Handle.is_modified = true
	# Refrescar el ítem actual del string_selector y el de la entry.
	# Bug fix (decoupling): leemos current_entry/current_string_index, que es
	# lo que de verdad está cargado. Si la entry no aparece en
	# dialogue_selector (filtrada) refresh_entry_item_prefix es no-op para esa
	# entry; refresh_string_item_prefix sí actualiza porque string_selector
	# siempre refleja current_entry.
	if current_string_index >= 0:
		refresh_string_item_prefix(current_string_index, _stri)
	if current_entry != "":
		refresh_entry_item_prefix(current_entry)

# Título de la ventana: "archivo.txt* — Dialogue Helper".
# El asterisco aparece cuando hay cambios sin guardar.
func update_window_title() -> void:
	var _base: String = "Dialogue Helper"
	var _fname: String = "Untitled"
	if Handle.current_file_path != "":
		_fname = Handle.current_file_path.get_file()
	var _mod: String = "*" if Handle.is_modified else ""
	tree.root.title = "%s%s — %s" % [_fname, _mod, _base]

# ---------------------------------------------------------------------------
# QoL: flujos reutilizables para File (los llama tanto el menú como los atajos)
# ---------------------------------------------------------------------------

func _on_files_dropped(_files: PackedStringArray) -> void:
	# Bug fix: el resto de flujos de carga (open_file_flow, _on_recent_selected,
	# atajos de teclado) pasan por _io_busy() para no pisar un save/load en
	# curso. El drop de archivo no lo hacía: si el usuario soltaba un .txt
	# mientras un thread anterior seguía vivo, _launch_load_thread reasignaba
	# last_thread y el viejo nunca se unía.
	if _io_busy():
		return
	if _files.size() != 1 or not _files.get(0).ends_with(".txt"):
		return
	var _path: String = _files.get(0)
	var _do_load := func() -> void:
		_launch_load_thread(_path)
	if Handle.is_modified:
		Handle.uc_window = Handle.uc_scene.instantiate()
		Handle.uc_window.callback.connect(_on_unsaved_changes_confirmed.bind(_do_load))
		add_child(Handle.uc_window)
	else:
		_do_load.call()

func open_file_flow() -> void:
	if _io_busy():
		return
	var _do_open := func() -> void:
		if FileAccess.file_exists("user://enable_git.bool"):
			_launch_load_thread("user://repo/Strings.txt")
		else:
			Handle.fd_window = Handle.fd_scene.instantiate()
			# Pre-rellena la ruta con el archivo actual, si hay uno.
			if Handle.current_file_path != "":
				Handle.fd_window.current_path = Handle.current_file_path
			Handle.fd_window.file_selected.connect(_launch_load_thread)
			# Bug fix (Issue #1): al cancelar/cerrar el FileDialog nativo, Godot
			# emite el error interno
			#   window_move_to_foreground: Condition "!windows.has(p_window)" is true.
			# (godotengine/godot#98083, fix en PR #98194). El motor intenta
			# devolver el foco a una ventana ya liberada porque hacíamos
			# `queue_free` inmediatamente al cancelar. La solución es la misma
			# que ya usa el flujo de éxito (_launch_load_thread): liberar la
			# ventana 1 frame más tarde con un tween, y poner la referencia
			# global a null en el acto para que ningún otro código la toque.
			Handle.fd_window.close_requested.connect(_close_fd_window_deferred)
			Handle.fd_window.canceled.connect(_close_fd_window_deferred)
			add_child(Handle.fd_window)
			Handle.fd_window.show()
	if Handle.is_modified:
		Handle.uc_window = Handle.uc_scene.instantiate()
		Handle.uc_window.callback.connect(_on_unsaved_changes_confirmed.bind(_do_open))
		add_child(Handle.uc_window)
	else:
		_do_open.call()

# Limpieza diferida del FileDialog de Open. Patrón equivalente al de
# _launch_load_thread pero pensado para cancelaciones: capturamos el nodo en
# una variable local, anulamos Handle.fd_window inmediatamente, y un frame
# después hacemos queue_free. Así Godot ya ha terminado de devolver el foco
# a la ventana principal cuando el FileDialog desaparece.
func _close_fd_window_deferred() -> void:
	var _w: FileDialog = Handle.fd_window
	Handle.fd_window = null
	if not is_instance_valid(_w):
		return
	var _t := create_tween()
	_t.tween_callback(func() -> void:
		if is_instance_valid(_w):
			_w.queue_free()
	).set_delay(1.0 / 60.0)
	_t.play()

func _launch_load_thread(_path: String) -> void:
	# A reference CSV belongs to the currently opened .txt only. Opening another
	# file should start with a clean reference panel.
	clear_reference_csv()
	var _t := create_tween()
	_t.tween_callback(func() -> void:
		if Handle.fd_window != null:
			Handle.fd_window.free()
			Handle.fd_window = null
		Handle.loading_window = Handle.loading_scene.instantiate()
		add_child(Handle.loading_window)
		last_thread = IFileHandler.load_file(_path)
	).set_delay(1.0 / 60.0)
	_t.play()

# Ctrl+S: si ya hay una ruta conocida y el archivo existe, guarda directo.
# En caso contrario, se comporta como Save As.
func save_file_flow() -> void:
	if _io_busy():
		return
	if FileAccess.file_exists("user://enable_git.bool"):
		_launch_save_thread("user://repo/Strings.txt")
		return
	if Handle.current_file_path != "" and FileAccess.file_exists(Handle.current_file_path):
		_launch_save_thread(Handle.current_file_path)
	else:
		_open_save_dialog()

# Ctrl+Shift+S: siempre abre el diálogo, incluso si ya hay una ruta.
func save_as_flow() -> void:
	if _io_busy():
		return
	if FileAccess.file_exists("user://enable_git.bool"):
		# En modo Git la ruta es fija; Save As se comporta igual que Save.
		_launch_save_thread("user://repo/Strings.txt")
		return
	_open_save_dialog()

func _open_save_dialog() -> void:
	Handle.fds_window = Handle.fds_scene.instantiate()
	# Pre-rellena con la ruta actual si existe, para que el diálogo no parta de cero.
	if Handle.current_file_path != "":
		Handle.fds_window.current_path = Handle.current_file_path
	Handle.fds_window.file_selected.connect(_launch_save_thread)
	# Bug fix (Issue #1): mismo razonamiento que en open_file_flow. El
	# FileDialog nativo de Save también soltaba
	#   window_move_to_foreground: Condition "!windows.has(p_window)" is true.
	# si se cancelaba estando ya con un archivo abierto. Liberamos diferido.
	Handle.fds_window.close_requested.connect(_close_fds_window_deferred)
	Handle.fds_window.canceled.connect(_close_fds_window_deferred)
	add_child(Handle.fds_window)
	Handle.fds_window.show()

# Limpieza diferida del FileDialog de Save. Mismo patrón que
# _close_fd_window_deferred (ver explicación allí).
func _close_fds_window_deferred() -> void:
	var _w: FileDialog = Handle.fds_window
	Handle.fds_window = null
	if not is_instance_valid(_w):
		return
	var _t := create_tween()
	_t.tween_callback(func() -> void:
		if is_instance_valid(_w):
			_w.queue_free()
	).set_delay(1.0 / 60.0)
	_t.play()

func _launch_save_thread(_path: String) -> void:
	var _t := create_tween()
	_t.tween_callback(func() -> void:
		if Handle.fds_window != null:
			Handle.fds_window.free()
			Handle.fds_window = null
		Handle.saving_window = Handle.saving_scene.instantiate()
		add_child(Handle.saving_window)
		# save_file ya no devuelve Thread; el seguimiento se hace vía
		# IFileHandler.io_in_progress, consultado por _io_busy().
		IFileHandler.save_file(_path)
	).set_delay(1.0 / 60.0)
	_t.play()

func new_file_flow() -> void:
	if _io_busy():
		return
	if Handle.is_modified:
		Handle.uc_window = Handle.uc_scene.instantiate()
		Handle.uc_window.callback.connect(_on_unsaved_changes_confirmed.bind(clear_data))
		add_child(Handle.uc_window)
	else:
		clear_data()

# Close File hace lo mismo que New File en este proyecto.
func close_file_flow() -> void:
	new_file_flow()

func settings_flow() -> void:
	Handle.settings_window = Handle.settings_scene.instantiate()
	add_child(Handle.settings_window)

func quit_flow() -> void:
	# Bug fix: igual que en close_requested, esperamos threads vivos antes de
	# pedir el quit, para evitar el error de "Thread not finished" en consola.
	_join_pending_threads()
	if Handle.is_modified:
		Handle.uc_window = Handle.uc_scene.instantiate()
		Handle.uc_window.callback.connect(_on_unsaved_changes_confirmed.bind(tree.quit))
		add_child(Handle.uc_window)
	else:
		get_tree().quit()

# ---------------------------------------------------------------------------
# Bloque 1: Open Recent (últimos 4 archivos abiertos)
# ---------------------------------------------------------------------------
# La lista se persiste en user://recent.json como un Array[String] de rutas
# absolutas. Se actualiza cada vez que se abre o se guarda un archivo con
# éxito, y se reconstruye el submenu cada vez que se va a abrir el File menu.
# Si la ruta apunta a un archivo que ya no existe, se marca como "(missing)"
# en el menú y al hacer clic se purga de la lista — fallback amistoso.

const _RECENT_FILES_PATH: String = "user://recent.json"
const _RECENT_FILES_MAX: int = 4
const _RECENT_CLEAR_ID: int = 99

func _load_recent_files() -> Array:
	if not FileAccess.file_exists(_RECENT_FILES_PATH):
		return []
	var _txt := FileAccess.get_file_as_string(_RECENT_FILES_PATH)
	var _parsed: Variant = JSON.parse_string(_txt)
	if _parsed is Array:
		var _result: Array = []
		for _v: Variant in (_parsed as Array):
			if _v is String and (_v as String) != "":
				_result.append(_v)
				if _result.size() >= _RECENT_FILES_MAX:
					break
		return _result
	return []

func _save_recent_files(_list: Array) -> void:
	var _f := FileAccess.open(_RECENT_FILES_PATH, FileAccess.WRITE)
	if _f == null:
		return
	_f.store_string(JSON.stringify(_list))
	_f.flush()
	_f.close()

# Añade una ruta al principio de la lista (deduplica) y persiste. Llamada
# por load_file_data tras un open exitoso y por el flujo de save tras
# guardar. Manteniendo "exitoso" como única condición evita rutas inválidas.
func push_recent_file(_path: String) -> void:
	if _path == "" or _path.begins_with("user://"):
		# No guardamos rutas internas (modo git escribe a user://repo/...).
		return
	var _list := _load_recent_files()
	# Deduplicar (case-insensitive en Windows sería más correcto, pero el
	# sistema de archivos del usuario lo arbitrará si abre dos veces).
	_list.erase(_path)
	_list.push_front(_path)
	while _list.size() > _RECENT_FILES_MAX:
		_list.pop_back()
	_save_recent_files(_list)

func _rebuild_recent_submenu() -> void:
	if recent_popup == null:
		return
	recent_popup.clear()
	var _list := _load_recent_files()
	if _list.is_empty():
		recent_popup.add_item("(no recent files)")
		recent_popup.set_item_disabled(0, true)
		return
	var _i := 0
	for _path: String in _list:
		var _label: String = _path.get_file()
		if not FileAccess.file_exists(_path):
			_label += "  (missing)"
		# Usamos el índice como id del item; la posición es estable durante
		# la vida del popup (lo limpiamos antes de cada mostrar).
		recent_popup.add_item(_label, _i)
		recent_popup.set_item_tooltip(_i, _path)
		_i += 1
	recent_popup.add_separator()
	recent_popup.add_item("Clear Recent Files", _RECENT_CLEAR_ID)

func _on_recent_selected(_id: int) -> void:
	if _id == _RECENT_CLEAR_ID:
		_save_recent_files([])
		return
	var _list := _load_recent_files()
	if _id < 0 or _id >= _list.size():
		return
	var _path: String = _list[_id]
	if not FileAccess.file_exists(_path):
		# La ruta ya no es válida: la sacamos de la lista y avisamos al usuario.
		_list.remove_at(_id)
		_save_recent_files(_list)
		_show_load_error("File no longer exists:\n%s\n\nIt has been removed from the recent list." % _path)
		return
	# Mismo flujo que un Open File normal, respetando "unsaved changes".
	if _io_busy():
		return
	var _do_load := func() -> void:
		_launch_load_thread(_path)
	if Handle.is_modified:
		Handle.uc_window = Handle.uc_scene.instantiate()
		Handle.uc_window.callback.connect(_on_unsaved_changes_confirmed.bind(_do_load))
		add_child(Handle.uc_window)
	else:
		_do_load.call()

# ---------------------------------------------------------------------------
# Bloque 1: errores y advertencias al cargar archivo
# ---------------------------------------------------------------------------
# Antes, si la carga fallaba (archivo inaccesible, formato roto), el flujo
# se silenciaba y el usuario se quedaba con datos a medias. Ahora IFileHandler
# detecta estos casos y nos llama aquí para mostrar un diálogo informativo.
# Reusamos la ventana StyleError porque ya está montada con un TextEdit
# scrollable y queue_free al cerrar — basta con cambiar el título y el texto.

func _show_load_error(_msg: String) -> void:
	var _w := Handle.se_scene.instantiate() as Window
	_w.title = "Error loading file"
	(_w.get_node(^"TextEdit") as TextEdit).text = _msg
	add_child(_w)

func _show_load_warning(_msg: String) -> void:
	var _w := Handle.se_scene.instantiate() as Window
	_w.title = "File loaded with warnings"
	(_w.get_node(^"TextEdit") as TextEdit).text = _msg
	add_child(_w)

# ---------------------------------------------------------------------------
# Export to JSON (File menu → id 12)
# ---------------------------------------------------------------------------
# Genera un JSON {clave: valor} equivalente a lo que txt_a_json() del script
# Python produciría para el archivo actualmente cargado en memoria.
#
# Convención "null": si IStringContainer.content es la cadena literal "null"
# (4 caracteres), se exporta como JSON null. Esto hace que el round-trip
#   TXT → (cargar en DH) → Export to JSON → tu script Python → TXT
# sea idempotente.
#
# El FileDialog sigue el mismo patrón de limpieza diferida que Open/Save
# (Issue #1): cancelar no dispara window_move_to_foreground.

func export_to_json_flow() -> void:
	if _io_busy():
		return
	var _dlg := FileDialog.new()
	_dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_dlg.access = FileDialog.ACCESS_FILESYSTEM
	_dlg.use_native_dialog = true
	_dlg.show_hidden_files = true
	_dlg.add_filter("*.json", "JSON File")
	# Pre-rellenar carpeta y nombre: misma carpeta que el .txt, mismo nombre
	# base con extensión .json.
	if Handle.current_file_path != "":
		_dlg.current_dir = Handle.current_file_path.get_base_dir()
		_dlg.current_file = Handle.current_file_path.get_file().get_basename() + ".json"
	else:
		_dlg.current_file = "export.json"
	_fdj_window = _dlg
	_dlg.file_selected.connect(func(_p: String) -> void:
		_close_fdj_window_deferred()
		_do_export_json(_p)
	)
	_dlg.close_requested.connect(_close_fdj_window_deferred)
	_dlg.canceled.connect(_close_fdj_window_deferred)
	add_child(_dlg)
	_dlg.show()

# Limpieza diferida del FileDialog de Export JSON. Mismo patrón que
# _close_fd_window_deferred (ver explicación allí).
func _close_fdj_window_deferred() -> void:
	var _w: FileDialog = _fdj_window
	_fdj_window = null
	if not is_instance_valid(_w):
		return
	var _t := create_tween()
	_t.tween_callback(func() -> void:
		if is_instance_valid(_w):
			_w.queue_free()
	).set_delay(1.0 / 60.0)
	_t.play()

# Construye el dict {clave: valor} y lo escribe como JSON indentado.
# Itera Handle.entry_names para respetar el orden de inserción del .txt.
# Salta las strings con clave vacía (no deben aparecer en el JSON).
func _do_export_json(_path: String) -> void:
	var _dict := {}
	for _entry: String in Handle.entry_names:
		if not Handle.strings.has(_entry):
			continue
		for _stri: IStringContainer in (Handle.strings[_entry] as Array):
			if _stri.clave == "":
				continue
			# Convención "null": la cadena literal "null" se exporta como JSON null
			# para que el round-trip sea idempotente con txt_a_json() de Python.
			if _stri.content == "null":
				_dict[_stri.clave] = null
			else:
				_dict[_stri.clave] = _stri.content
	var _json_str: String = JSON.stringify(_dict, "\t")
	var _f := FileAccess.open(_path, FileAccess.WRITE)
	if _f == null:
		_show_load_error("Could not write JSON file:\n%s\n\nError code: %d" % [
			_path, FileAccess.get_open_error()])
		return
	_f.store_string(_json_str)
	_f.flush()
	_f.close()

# ---------------------------------------------------------------------------
# Bloque 3: Autosave y recuperación
# ---------------------------------------------------------------------------
# Mecanismo de respaldo en background. NO sustituye al guardado real:
# sigue marcando is_modified=true en el título hasta que el usuario haga
# Ctrl+S de verdad. Solo evita perder horas de trabajo si la app crashea
# o si el sistema se reinicia.
#
# Disparadores:
#   - Cualquier cambio (Handle.is_modified pasa a true) reinicia un timer
#     de debounce de 30 s. Si pasan 30 s sin más cambios → autosave.
#   - Un timer periódico de 5 min vuelca cualquier cambio pendiente.
# Limpieza:
#   - Tras un Save real exitoso, los archivos de autosave se borran.
#   - Si el usuario elige Discard en el diálogo de recuperación al
#     arrancar, se borran también.
# Ubicación:
#   - user://autosave.txt        (mismo formato que un .txt normal)
#   - user://autosave_meta.json  (ruta original + timestamp)

const _AUTOSAVE_PATH: String = "user://autosave.txt"
const _AUTOSAVE_META_PATH: String = "user://autosave_meta.json"
const _AUTOSAVE_DEBOUNCE_SECONDS: float = 30.0
const _AUTOSAVE_PERIODIC_SECONDS: float = 300.0  # 5 minutos
const _RECOVER_AUTOSAVE_SCENE: PackedScene = preload("res://Subwindows/RecoverAutosave.tscn")

# Timers creados por código en _ready_autosave. Son hijos del MainNode,
# así que se limpian solos al cerrar la app.
var _autosave_debounce_timer: Timer = null
var _autosave_periodic_timer: Timer = null
# True cuando hay cambios desde el último volcado del autosave. El periodic
# timer sólo dispara cuando este flag es true, para no escribir en disco
# innecesariamente cada 5 min.
var _autosave_pending: bool = false

func _ready_autosave() -> void:
	# Timers como hijos del nodo. autostart=false en el debounce; lo
	# arrancamos a mano cada vez que cambia is_modified.
	_autosave_debounce_timer = Timer.new()
	_autosave_debounce_timer.one_shot = true
	_autosave_debounce_timer.wait_time = _AUTOSAVE_DEBOUNCE_SECONDS
	_autosave_debounce_timer.timeout.connect(_on_autosave_debounce_timeout)
	add_child(_autosave_debounce_timer)

	_autosave_periodic_timer = Timer.new()
	_autosave_periodic_timer.one_shot = false
	_autosave_periodic_timer.wait_time = _AUTOSAVE_PERIODIC_SECONDS
	_autosave_periodic_timer.timeout.connect(_on_autosave_periodic_timeout)
	add_child(_autosave_periodic_timer)
	_autosave_periodic_timer.start()

	# Reaccionar a cambios de is_modified vía señal (sin polling).
	if not Handle.is_modified_changed.is_connected(_on_is_modified_changed):
		Handle.is_modified_changed.connect(_on_is_modified_changed)

func _on_is_modified_changed(_value: bool) -> void:
	if _value:
		# Cambio: marcar pendiente y reiniciar el debounce (start()
		# resetea el contador si ya estaba corriendo).
		_autosave_pending = true
		if _autosave_debounce_timer != null:
			_autosave_debounce_timer.start()
	else:
		# Save real exitoso o reset: ya no hay nada pendiente, paramos
		# el debounce. La limpieza de los archivos físicos del autosave
		# la hace IFileHandler invocando _discard_autosave_files.
		_autosave_pending = false
		if _autosave_debounce_timer != null:
			_autosave_debounce_timer.stop()

func _on_autosave_debounce_timeout() -> void:
	_perform_autosave()

func _on_autosave_periodic_timeout() -> void:
	if _autosave_pending:
		_perform_autosave()

# Volcado del estado actual a user://autosave.txt + meta.
# Síncrono en el main thread: en archivos típicos (decenas de miles de
# strings) tarda ms. Si en algún momento se nota lag, mover a thread.
# Falla silenciosamente: el autosave es complementario, no debe
# interrumpir al usuario con popups si no se puede escribir.
func _perform_autosave() -> void:
	# No intentar autosave si: (a) no hay datos, (b) hay un Save real
	# en curso (podría haber races con Handle.strings), (c) no hay flag
	# pendiente (puede pasar si el periodic timer dispara justo después
	# del debounce).
	if Handle.strings.is_empty():
		return
	if IFileHandler.io_in_progress:
		return
	if not _autosave_pending:
		return

	var _payload_arr := IFileHandler._build_save_payload()
	var _payload: String = "\n".join(PackedStringArray(_payload_arr))

	# Escritura atómica: tmp + rename. Si fallamos en cualquier paso,
	# salimos sin tocar el autosave previo (si lo había).
	var _tmp := _AUTOSAVE_PATH + ".tmp"
	var _f := FileAccess.open(_tmp, FileAccess.WRITE)
	if _f == null:
		return
	_f.store_string(_payload)
	_f.flush()
	_f.close()
	if DirAccess.rename_absolute(_tmp, _AUTOSAVE_PATH) != OK:
		# Si el rename falla, el .tmp queda huérfano; lo limpiamos para
		# no dejar basura en user://.
		if FileAccess.file_exists(_tmp):
			DirAccess.remove_absolute(_tmp)
		return

	# Meta: ruta original + timestamp del propio autosave. La ruta
	# vacía indica un archivo nuevo (sin guardar nunca); en ese caso,
	# tras Recover, el usuario tendrá que hacer Save As.
	var _meta := {
		"original_path": Handle.current_file_path,
		"timestamp": int(Time.get_unix_time_from_system()),
		"app_version": "DialogueHelper",
	}
	var _mf := FileAccess.open(_AUTOSAVE_META_PATH, FileAccess.WRITE)
	if _mf != null:
		_mf.store_string(JSON.stringify(_meta))
		_mf.flush()
		_mf.close()

	# Volcado completo: ya no hay nada pendiente hasta el siguiente cambio.
	# OJO: NO ponemos Handle.is_modified=false; el usuario sigue viendo
	# el asterisco en el título hasta el Save real.
	_autosave_pending = false

# Borra los archivos físicos del autosave. Llamado desde:
#   - el commit de Save real exitoso (vía call_deferred desde IFileHandler)
#   - el callback de Discard del diálogo de recuperación
#   - _on_unsaved_changes_confirmed (cuando el usuario aprieta OK en el
#     diálogo de "Unsaved Changes" para descartar cambios y proceder)
func _discard_autosave_files() -> void:
	if FileAccess.file_exists(_AUTOSAVE_PATH):
		DirAccess.remove_absolute(_AUTOSAVE_PATH)
	if FileAccess.file_exists(_AUTOSAVE_META_PATH):
		DirAccess.remove_absolute(_AUTOSAVE_META_PATH)
	_autosave_pending = false

# Bug fix: wrapper para los callbacks del diálogo "Unsaved Changes". Cuando
# el usuario aprieta OK ahí, está confirmando "descarta lo no guardado y
# continúa". Si dejamos el autosave en disco, la próxima sesión se lo
# ofrecerá de vuelta — contradictorio con la decisión que acaba de tomar.
# Borramos el autosave antes de ejecutar la acción original (cerrar la
# app, abrir otro archivo, hacer New File, etc.).
#
# Uso: en lugar de `Handle.uc_window.callback.connect(my_action)`, ahora
# se conecta `Handle.uc_window.callback.connect(_on_unsaved_changes_confirmed.bind(my_action))`.
func _on_unsaved_changes_confirmed(_action: Callable) -> void:
	_discard_autosave_files()
	_action.call()

# Detección al arrancar. Si hay un autosave en disco, mostramos el diálogo.
# Llamado desde _ready DESPUÉS de cargar el style y antes de que el usuario
# pueda hacer nada — así no compite con su input.
func _check_autosave_recovery() -> void:
	if not FileAccess.file_exists(_AUTOSAVE_PATH):
		return
	# Leer meta si existe, para mostrar info útil en el diálogo.
	var _original_path: String = ""
	var _timestamp: int = 0
	if FileAccess.file_exists(_AUTOSAVE_META_PATH):
		var _mf := FileAccess.get_file_as_string(_AUTOSAVE_META_PATH)
		var _parsed: Variant = JSON.parse_string(_mf)
		if _parsed is Dictionary:
			var _d: Dictionary = _parsed
			_original_path = str(_d.get("original_path", ""))
			# Mismo patrón que con bool(): Dictionary.get() devuelve Variant
			# y int() acepta Variant, pero el analyzer estricto se queja.
			# `as int` es la forma idiomática y silencia el warning.
			_timestamp = _d.get("timestamp", 0) as int

	var _w: WRecoverAutosave = _RECOVER_AUTOSAVE_SCENE.instantiate()
	# Mensaje: cuándo y de qué archivo. Si no hay timestamp, omitimos
	# la fecha. Si el archivo es "untitled" (no guardado), lo decimos.
	var _when: String = ""
	if _timestamp > 0:
		_when = "from " + Time.get_datetime_string_from_unix_time(_timestamp).replace("T", " ")
	var _what: String = "Untitled (never saved)"
	if _original_path != "":
		_what = _original_path
	var _msg := "An autosave from a previous session was found.\n\n"
	_msg += "File: " + _what + "\n"
	if _when != "":
		_msg += "Date: " + _when + "\n"
	_msg += "\nRecover this work, or discard it?"
	_w.message = _msg
	_w.recover_requested.connect(func() -> void:
		# Bug fix: el problema es una carrera entre `add_child(loading_window)`
		# y la liberación de RecoverAutosave. El click en Recover dispara, en
		# este orden, recover_requested.emit() (síncrono) y queue_free()
		# (programado). En Godot 4 las "deferred calls" se procesan ANTES de
		# que los nodos en cola de queue_free se liberen físicamente, así que
		# un simple call_deferred aquí ejecutaría _recover_from_autosave
		# mientras RecoverAutosave aún está en el árbol — y el `add_child`
		# del loading_window choca con su exclusividad. La solución correcta
		# es esperar a que RecoverAutosave salga del árbol de verdad usando
		# su señal `tree_exited`. Solo entonces ejecutamos el recover.
		_w.tree_exited.connect(func() -> void:
			_recover_from_autosave(_original_path)
		, CONNECT_ONE_SHOT)
	)
	_w.discard_requested.connect(func() -> void:
		_discard_autosave_files()
	)
	add_child(_w)

# Carga el contenido del autosave como si fuera el archivo original.
# Restaura current_file_path desde el meta (vía _override_path en load_file)
# y marca is_modified=true en el mismo commit, evitando races.
func _recover_from_autosave(_original_path: String) -> void:
	if not FileAccess.file_exists(_AUTOSAVE_PATH):
		return
	# Bug fix: el flujo "normal" de carga (_launch_load_thread) hace dos cosas
	# que aquí faltaban:
	#   1) Crear Handle.loading_window ANTES de lanzar el thread. Sin esto,
	#      el worker accede a Handle.loading_window.label cuando aún es null
	#      y crashea con "Invalid access to property 'label' on a base object
	#      of type 'Nil'" en la primera línea de IFileHandler.load_file.
	#   2) Guardar el Thread retornado en last_thread. Sin esto, el thread
	#      queda huérfano: _join_pending_threads() no lo encuentra al cerrar
	#      la app, el destructor del Thread se queja con "A Thread object
	#      is being destroyed without its completion having been realized",
	#      y en escenarios de quit-with-recover-en-curso podía dejar el
	#      proceso en un estado raro.
	Handle.loading_window = Handle.loading_scene.instantiate()
	add_child(Handle.loading_window)
	# load_file ahora acepta dos overrides opcionales; los pasamos para
	# que current_file_path acabe apuntando al archivo "real" (no al
	# autosave) y para que is_modified quede en true (el contenido
	# recuperado no se ha guardado aún a su archivo de destino).
	last_thread = IFileHandler.load_file(_AUTOSAVE_PATH, _original_path, true)

# ---------------------------------------------------------------------------
# Bloque 1: borrado de entries y strings
# ---------------------------------------------------------------------------
# Ambos flujos pasan por una ventana de confirmación. El borrado real lo
# hacen los métodos `_perform_delete_*` cuando el usuario confirma.

const _CONFIRM_DELETE_SCENE: PackedScene = preload("res://Subwindows/ConfirmDelete.tscn")

func delete_entry_flow() -> void:
	if _io_busy():
		return
	# Bug fix (decoupling): borramos la entry cargada, no la seleccionada en
	# dialogue_selector (que puede estar desincronizada con un filtro).
	if current_entry == "" or not Handle.strings.has(current_entry):
		return
	var _entry_name := current_entry
	var _str_count: int = (Handle.strings[_entry_name] as Array).size()
	var _w: WConfirmDelete = _CONFIRM_DELETE_SCENE.instantiate()
	_w.message = "Delete entry \"%s\" and all of its %d string(s)?\n\nThis cannot be undone after saving." % [_entry_name, _str_count]
	_w.confirmed.connect(func() -> void:
		_perform_delete_entry(_entry_name)
	)
	add_child(_w)

func delete_string_flow() -> void:
	if _io_busy():
		return
	# Bug fix (decoupling): borramos la string cargada en el editor, no la
	# selección visual de los list views.
	if current_entry == "" or current_string_index < 0:
		return
	if not Handle.strings.has(current_entry):
		return
	var _entry_name := current_entry
	var _arr: Array = Handle.strings[_entry_name]
	var _idx: int = current_string_index
	if _idx >= _arr.size():
		return
	var _w: WConfirmDelete = _CONFIRM_DELETE_SCENE.instantiate()
	# Mostramos un trozo del contenido para que el usuario vea qué va a borrar.
	var _preview: String = (_arr[_idx] as IStringContainer).content
	if _preview.length() > 80:
		_preview = _preview.substr(0, 77) + "..."
	_w.message = "Delete string %d of entry \"%s\"?\n\n\"%s\"\n\nThis cannot be undone after saving." % [_idx + 1, _entry_name, _preview]
	_w.confirmed.connect(func() -> void:
		_perform_delete_string(_entry_name, _idx)
	)
	add_child(_w)

# Borra una entry entera (todas sus strings). Limpia las estructuras globales
# (string_table, string_ids, string_sstr...) que apuntan a las strings borradas.
func _perform_delete_entry(_entry_name: String) -> void:
	if not Handle.strings.has(_entry_name):
		return
	var _doomed_arr: Array = Handle.strings[_entry_name]
	var _doomed_ids := []
	for _stri: IStringContainer in _doomed_arr:
		_doomed_ids.append(_stri.id)

	# Quitar de todas las estructuras globales.
	for _id: int in _doomed_ids:
		Handle.string_table.erase(_id)
		Handle.string_ids.erase(_id)
	_purge_ids_from_similar(_doomed_ids)
	Handle.strings.erase(_entry_name)
	Handle.entry_names.erase(_entry_name)
	Handle.string_size = max(0, Handle.string_size - _doomed_ids.size())

	# Quitar el item del dialogue_selector (sólo el que coincida en nombre real).
	for _i in range(dialogue_selector.get_item_count()):
		if dialogue_selector_entry_at(_i) == _entry_name:
			dialogue_selector.remove_item(_i)
			break

	# Si la entry borrada era la que estaba cargada en el editor, limpiamos
	# el panel de la derecha (string_selector + editor) y reseteamos la
	# fuente de verdad. El siguiente item del dialogue_selector (si existe)
	# se selecciona como conveniencia y `_on_item_list_item_selected` →
	# `change_to` reasignará current_entry/current_string_index.
	var _was_current := (_entry_name == current_entry)
	if _was_current:
		_set_loaded("", -1)
	string_selector.clear()
	similar_entries.clear()
	_set_dialogue_edit_text_silent("")
	original_dialogue.text = ""
	Handle.og_str = ""
	if dialogue_selector.get_item_count() > 0:
		var _next: int = 0
		dialogue_selector.select(_next)
		dialogue_selector.ensure_current_is_visible()
		_on_item_list_item_selected(_next)

	Handle.is_modified = true
	update_progress_stats_label()

# Borra una string concreta dentro de una entry. Re-asigna `index` a las
# strings posteriores en string_table (cada IStringTable guarda su posición
# dentro de la entry, y borrar al medio desplaza las que vienen después).
func _perform_delete_string(_entry_name: String, _idx: int) -> void:
	if not Handle.strings.has(_entry_name):
		return
	var _arr: Array = Handle.strings[_entry_name]
	if _idx < 0 or _idx >= _arr.size():
		return
	var _doomed: IStringContainer = _arr[_idx]
	var _doomed_id: int = _doomed.id

	_arr.remove_at(_idx)
	Handle.string_table.erase(_doomed_id)
	Handle.string_ids.erase(_doomed_id)
	_purge_ids_from_similar([_doomed_id])
	Handle.string_size = max(0, Handle.string_size - 1)

	# Las strings que estaban después en la misma entry tienen ahora un index
	# menor. Hay que actualizar string_table para que sigan apuntando a la
	# posición correcta dentro de la entry.
	for _i in range(_idx, _arr.size()):
		var _later: IStringContainer = _arr[_i]
		if Handle.string_table.has(_later.id):
			(Handle.string_table[_later.id] as IStringTable).index = _i

	# Refrescar el string_selector mostrando lo que queda. Sólo tiene sentido
	# si la entry borrada es la cargada en el editor — string_selector siempre
	# refleja current_entry. (Hoy delete_string_flow usa current_entry, así
	# que esta condición siempre se cumple; la dejamos defensiva por si
	# futuros flujos llaman a _perform_delete_string sobre otra entry.)
	if _entry_name == current_entry:
		string_selector.clear()
		for _stri: IStringContainer in _arr:
			string_selector.add_item(_string_progress_prefix(_stri) + _stri.content)

	# Reseleccionar algo razonable: la siguiente string en la misma posición,
	# o la última si borramos la última.
	# Bug fix (decoupling): si la entry afectada es la cargada en el editor,
	# actualizamos current_string_index. Si el array quedó vacío, lo dejamos
	# en -1 explícitamente; `_on_item_list_item_selected_str` no se llamaría
	# (lista vacía) y current_string_index quedaría obsoleto.
	if _arr.is_empty():
		# Editor/similar_entries sólo se tocan si la entry borrada es la cargada.
		if _entry_name == current_entry:
			similar_entries.clear()
			_set_dialogue_edit_text_silent("")
			original_dialogue.text = ""
			Handle.og_str = ""
			_set_loaded(current_entry, -1)
	else:
		if _entry_name == current_entry:
			var _new_idx: int = min(_idx, _arr.size() - 1)
			string_selector.select(_new_idx)
			string_selector.ensure_current_is_visible()
			# _on_item_list_item_selected_str actualiza current_string_index.
			_on_item_list_item_selected_str(_new_idx)

	# La entry pudo cambiar de "✓" a "·" (si la borrada era la única no
	# traducida) o de "·" a "∅" si era la última string de la entry.
	refresh_entry_item_prefix(_entry_name)
	Handle.is_modified = true
	update_progress_stats_label()

# Helper interno: cuando borramos strings, hay que sacar sus IDs de las
# listas `equal_strings` que comparten varias strings entre sí, y de los
# diccionarios que las indexan.
func _purge_ids_from_similar(_ids_to_remove: Array) -> void:
	if _ids_to_remove.is_empty():
		return
	var _id_set := {}
	for _id: Variant in _ids_to_remove:
		_id_set[_id] = true
	# Quitar de equal_strings de cada string que sigue viva. Cada array es
	# compartido por todas las strings del grupo, así que basta con limpiar
	# una vez por grupo (lo hacemos al recorrer string_sstr_arr abajo).
	for _arr: Array in Handle.string_sstr_arr:
		var _i := _arr.size() - 1
		while _i >= 0:
			if _id_set.has(_arr[_i]):
				_arr.remove_at(_i)
			_i -= 1
	# Lo que NO hacemos a propósito (decisiones conscientes, no olvidos):
	#   1) NO compactamos string_sstr_arr eliminando arrays vacíos. Si lo
	#      hiciéramos, todos los `equal_strings_index` posteriores que
	#      apuntan a este array quedarían desplazados y habría que
	#      recalcularlos uno por uno.
	#   2) NO purgamos string_sstr (el dict original_content → índice). Tras
	#      un borrado puede contener entradas que apuntan a arrays de
	#      tamaño 0 ó 1. No rompe nada porque:
	#        - La UI de "Similar entries" filtra el self al mostrar (un
	#          grupo de 1 elemento renderiza como vacío).
	#        - AddString hace `append` sobre el array existente al crear
	#          una string con un original_content cuyo grupo había
	#          quedado huérfano, así que el grupo "revive" limpiamente
	#          en cuanto vuelve a haber 2+ strings equivalentes.
	#      El único coste es algo de residuo en memoria que se libera al
	#      cerrar el archivo (clear_data() vacía las dos estructuras).

# ---------------------------------------------------------------------------

# Debounce para no escribir scale.txt en cada frame mientras el usuario arrastra el SpinBox.
var _scale_save_timer: SceneTreeTimer = null

func _request_scale_save() -> void:
	if _scale_save_timer != null:
		# Ya hay un guardado pendiente; no programes otro.
		return
	_scale_save_timer = tree.create_timer(0.5)
	_scale_save_timer.timeout.connect(func() -> void:
		_scale_save_timer = null
		var _f := FileAccess.open("user://scale.txt", FileAccess.WRITE)
		if _f == null:
			push_warning("Could not persist scale to user://scale.txt")
			return
		_f.store_string(str(Handle.visual_scale))
		_f.flush()
		_f.close()
	)

# ---------------------------------------------------------------------------
# Menú contextual de los TextEdits: opción "Copy Clave name".
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# CSV reference panel (Notas / ES desde EN / ES desde JP)
# ---------------------------------------------------------------------------

func _setup_reference_panel() -> void:
	if reference_panel != null:
		return
	reference_panel = PanelContainer.new()
	reference_panel.name = "ReferencePanel"
	reference_panel.tooltip_text = "Optional reference CSV, matched by the current string's Clave."
	reference_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(reference_panel)
	reference_panel.move_to_front()

	var _root := VBoxContainer.new()
	_root.name = "Root"
	_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	reference_panel.add_child(_root)

	var _header := HBoxContainer.new()
	_header.name = "Header"
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_child(_header)

	var _title := Label.new()
	_title.text = "Reference"
	_title.tooltip_text = "Shows notes and draft Spanish references from a local CSV export."
	_header.add_child(_title)

	reference_status_label = Label.new()
	reference_status_label.text = "No CSV"
	reference_status_label.clip_text = true
	reference_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	reference_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reference_status_label.custom_minimum_size = Vector2(80.0, 0.0)
	_header.add_child(reference_status_label)

	reference_toggle_button = Button.new()
	reference_toggle_button.text = "▴"
	reference_toggle_button.tooltip_text = "Hide reference panel"
	reference_toggle_button.focus_mode = Control.FOCUS_NONE
	reference_toggle_button.pressed.connect(_toggle_reference_panel_collapsed)
	_header.add_child(reference_toggle_button)

	var _load_button := Button.new()
	_load_button.text = "Load"
	_load_button.tooltip_text = "Load reference CSV..."
	_load_button.focus_mode = Control.FOCUS_NONE
	_load_button.pressed.connect(load_reference_csv_flow)
	_header.add_child(_load_button)

	var _clear_button := Button.new()
	_clear_button.text = "×"
	_clear_button.tooltip_text = "Clear reference CSV"
	_clear_button.focus_mode = Control.FOCUS_NONE
	_clear_button.pressed.connect(clear_reference_csv)
	_header.add_child(_clear_button)

	reference_body = HBoxContainer.new()
	reference_body.name = "ReferenceBody"
	reference_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reference_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(reference_body)

	reference_notes_edit = _make_reference_column("Notas", "No notes for this string.", 1.25)
	reference_es_en_edit = _make_reference_column("ES ← EN", "No Spanish-from-English reference for this string.", 1.0)
	reference_es_jp_edit = _make_reference_column("ES ← JP", "No Spanish-from-Japanese reference for this string.", 1.0)

	_update_reference_panel_visibility()
	_update_reference_panel_layout()
	update_reference_panel()

func _make_reference_column(_title: String, _placeholder: String, _ratio: float) -> TextEdit:
	var _col := VBoxContainer.new()
	_col.name = "ReferenceColumn%d" % reference_body.get_child_count()
	_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_col.size_flags_stretch_ratio = _ratio
	reference_body.add_child(_col)

	var _label := Label.new()
	_label.text = _title
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.clip_text = true
	_label.add_theme_font_size_override("font_size", _REFERENCE_PANEL_FONT_SIZE)
	_col.add_child(_label)

	var _te := _make_reference_text_edit(_title, _placeholder)
	_col.add_child(_te)
	return _te

func _make_reference_text_edit(_name: String, _placeholder: String) -> TextEdit:
	var _te := TextEdit.new()
	_te.name = _name
	_te.editable = false
	_te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_te.placeholder_text = _placeholder
	_te.tooltip_text = "Reference only. This does not get saved to the .txt."
	_te.add_theme_font_size_override("font_size", _REFERENCE_PANEL_FONT_SIZE)
	_te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_te.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return _te

func _toggle_reference_panel_collapsed() -> void:
	reference_panel_collapsed = not reference_panel_collapsed
	_update_reference_panel_visibility()
	_update_reference_panel_layout()

func _update_reference_panel_visibility() -> void:
	if reference_body != null:
		reference_body.visible = not reference_panel_collapsed
	if reference_toggle_button != null:
		if reference_panel_collapsed:
			reference_toggle_button.text = "▾"
			reference_toggle_button.tooltip_text = "Show reference panel"
		else:
			reference_toggle_button.text = "▴"
			reference_toggle_button.tooltip_text = "Hide reference panel"

func _update_reference_panel_layout() -> void:
	if reference_panel == null:
		return
	# Keep the reference panel in the empty space below the preview and above
	# the editor controls (Add new Entry/String, portrait toggle, replace toggle).
	# The first attempt placed it immediately above DialogueEdit, which made it
	# overlap those controls at 1100×700. This anchors the bottom edge to the
	# topmost editor-control row instead.
	var _h: float = _REFERENCE_PANEL_COLLAPSED_H if reference_panel_collapsed else _REFERENCE_PANEL_EXPANDED_H
	var _button_top: float = minf(add_entry.position.y, add_string.position.y)
	var _controls_top: float = dialogue_edit.position.y + _button_top - _REFERENCE_PANEL_MARGIN
	var _right_limit: float = float(tree.root.size.x) - (1100.0 - 879.0) - _REFERENCE_PANEL_MARGIN
	var _w: float = minf(dialogue_edit.size.x, maxf(260.0, _right_limit - dialogue_edit.position.x))
	reference_panel.position = Vector2(dialogue_edit.position.x, _controls_top - _h)
	reference_panel.size = Vector2(_w, _h)

func load_reference_csv_flow() -> void:
	if _reference_fd_window != null and is_instance_valid(_reference_fd_window):
		_reference_fd_window.show()
		return
	_reference_fd_window = FileDialog.new()
	_reference_fd_window.title = "Load Reference CSV"
	_reference_fd_window.ok_button_text = "Load"
	_reference_fd_window.size = Vector2i(700, 600)
	_reference_fd_window.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_reference_fd_window.access = FileDialog.ACCESS_FILESYSTEM
	_reference_fd_window.filters = PackedStringArray(["*.csv;CSV File", "*.*;All Files"])
	_reference_fd_window.show_hidden_files = true
	_reference_fd_window.use_native_dialog = true
	if reference_table.source_path != "":
		_reference_fd_window.current_path = reference_table.source_path
	elif Handle.current_file_path != "":
		_reference_fd_window.current_dir = Handle.current_file_path.get_base_dir()
	_reference_fd_window.file_selected.connect(func(_path: String) -> void:
		_load_reference_csv(_path)
		_close_reference_fd_window_deferred()
	)
	_reference_fd_window.close_requested.connect(_close_reference_fd_window_deferred)
	_reference_fd_window.canceled.connect(_close_reference_fd_window_deferred)
	add_child(_reference_fd_window)
	_reference_fd_window.show()

func _close_reference_fd_window_deferred() -> void:
	var _w: FileDialog = _reference_fd_window
	_reference_fd_window = null
	if not is_instance_valid(_w):
		return
	var _t := create_tween()
	_t.tween_callback(func() -> void:
		if is_instance_valid(_w):
			_w.queue_free()
	).set_delay(1.0 / 60.0)
	_t.play()

func _load_reference_csv(_path: String) -> void:
	# Reference CSVs are intentionally session/file scoped. They are useful while
	# working on one file, but should not be restored automatically after closing
	# the program or switching to another .txt.
	if reference_table.load_from_csv(_path):
		update_reference_panel()
	else:
		_show_reference_csv_error(reference_table.last_error)
		update_reference_panel()

func clear_reference_csv() -> void:
	reference_table.clear()
	update_reference_panel()

func _show_reference_csv_error(_msg: String) -> void:
	var _w := Handle.se_scene.instantiate() as Window
	_w.title = "Reference CSV error"
	(_w.get_node(^"TextEdit") as TextEdit).text = _msg
	add_child(_w)

func update_reference_panel() -> void:
	if reference_panel == null:
		return
	if reference_table.source_path == "":
		reference_status_label.text = "No CSV"
		reference_panel.tooltip_text = "No reference CSV loaded."
		_set_reference_texts("", "", "")
		return
	var _clave := _get_current_clave()
	if _clave == "":
		reference_status_label.text = "%d refs · no Clave" % reference_table.loaded_count()
		reference_panel.tooltip_text = "Reference CSV loaded, but the current string has no Clave."
		_set_reference_texts("", "", "")
		return
	var _ref := reference_table.get_reference(_clave)
	if _ref.is_empty():
		reference_status_label.text = "%d refs · no match" % reference_table.loaded_count()
		_set_reference_texts("", "", "")
		reference_panel.tooltip_text = "No reference found for Clave:\n%s" % _clave
		return
	reference_status_label.text = "Match"
	reference_panel.tooltip_text = "Reference found for Clave:\n%s\n\nCSV:\n%s" % [_clave, reference_table.source_path]
	_set_reference_texts(
		str(_ref.get(ReferenceTable.FIELD_NOTES, "")),
		str(_ref.get(ReferenceTable.FIELD_ES_FROM_EN, "")),
		str(_ref.get(ReferenceTable.FIELD_ES_FROM_JP, ""))
	)

func _set_reference_texts(_notes: String, _es_en: String, _es_jp: String) -> void:
	_set_reference_column_text(reference_notes_edit, _notes)
	_set_reference_column_text(reference_es_en_edit, _es_en)
	_set_reference_column_text(reference_es_jp_edit, _es_jp)

func _set_reference_column_text(_edit: TextEdit, _text: String) -> void:
	if _edit == null:
		return
	var _clean_text: String = _text.strip_edges()
	_edit.text = _clean_text
	var _column: Control = _edit.get_parent() as Control
	if _column != null:
		# Empty reference fields should not reserve space. If a row has no notes,
		# for example, the two draft columns can use the whole panel width.
		_column.visible = _clean_text != ""

# ID lejos del rango de IDs internos de TextEdit (Cut/Copy/Paste van por debajo de 30).
const _MENU_ID_COPY_CLAVE := 1000

func _setup_textedit_clave_menu(te: TextEdit) -> void:
	var _menu: PopupMenu = te.get_menu()
	_menu.add_separator()
	_menu.add_item("Copy Clave name", _MENU_ID_COPY_CLAVE)
	_menu.id_pressed.connect(_on_textedit_menu_id_pressed)
	# Habilitar / deshabilitar el ítem según haya o no Clave en la string activa.
	_menu.about_to_popup.connect(func() -> void:
		var _idx := _menu.get_item_index(_MENU_ID_COPY_CLAVE)
		if _idx == -1:
			return
		_menu.set_item_disabled(_idx, _get_current_clave() == "")
	)

func _get_current_clave() -> String:
	# Bug fix (decoupling): pasamos por la fuente de verdad.
	var _stri := _get_current_string_container()
	if _stri == null:
		return ""
	return _stri.clave

# Helper para mantener el invariante de "qué está cargado en el editor".
# change_to y _on_item_list_item_selected_str son los dos call sites
# canónicos donde el editor cambia de string; cualquier flujo nuevo que
# cargue algo debería pasar también por aquí. Así nadie puede olvidar
# actualizar las dos variables a la vez y reintroducir el bug del
# decoupling.
func _set_loaded(_entry: String, _idx: int) -> void:
	current_entry = _entry
	current_string_index = _idx
	update_reference_panel()

# Parsea referencias "EntryName:N" o "EntryName" tolerando que el nombre
# contenga `:`. Estrategia: si la parte tras el último `:` es un entero,
# es el índice (1-based); en cualquier otro caso el texto entero es el
# nombre y se asume índice 1. Devuelve [name: String, one_based_index: int].
#
# Antes el código hacía `(text + ":1").split(":")` en SearchResults, GoTo
# y _on_item_list_item_selected_similar; el split partía el nombre en el
# primer `:` y rompía la navegación cuando la entry contenía `:` en su
# nombre. Esto centraliza el parseo y lo hace robusto.
func _parse_entry_ref(_text: String) -> Array:
	var _parts := _text.rsplit(":", true, 1)
	if _parts.size() == 2 and (_parts[1] as String).is_valid_int():
		return [_parts[0], int(_parts[1])]
	return [_text, 1]

func _on_textedit_menu_id_pressed(id: int) -> void:
	if id == _MENU_ID_COPY_CLAVE:
		var _clave := _get_current_clave()
		if _clave != "":
			DisplayServer.clipboard_set(_clave)

func update_box(_i: int, _user_change: bool = true) -> void:
	if _i >= Handle.box_data.size():
		return
	current_box = _i
	current_box_label.text = Handle.box_data[_i].name
	current_box_node.value = _i + 1
	box.current_box = _i
	if _user_change:
		Handle.is_modified = true

func update_font(_i: int, _user_change: bool = true) -> void:
	if _i >= Handle.font_data.size():
		return
	current_font_id = _i
	Handle.current_font = _i
	current_font_label.text = Handle.font_data[_i].name
	current_font_node.value = _i + 1
	font = IFont.get_font(Handle.current_font)
	if _user_change:
		Handle.is_modified = true
		box.handle.force_update = true

# Devuelve true si el IStringContainer contiene etiquetas de retrato (\E, \F, \P, ...)
func _string_has_portrait_tags(_stri: IStringContainer) -> bool:
	if _stri == null:
		return false
	var portrait_tags: Array[String] = ["\\E", "\\F", "\\P"]
	# original_content y layer_strings están tipados (String y Array[String]),
	# así que no pueden ser null — sólo string/array vacíos. No tiene sentido
	# chequear null aquí.
	if not _stri.original_content.is_empty():
		for t in portrait_tags:
			if _stri.original_content.find(t) != -1:
				return true
	for layer in _stri.layer_strings:
		if typeof(layer) == TYPE_STRING:
			for t in portrait_tags:
				if (layer as String).find(t) != -1:
					return true
	return false

# ---------------------------------------------------------------------------
# Issue #3: auto-selección de caja según presencia de "*" en el texto.
# ---------------------------------------------------------------------------
# Regla: si el texto (original o traducido) contiene "*" en CUALQUIER posición
# → se trata como diálogo y se usa Box1 (índice 0). Si no contiene "*" → se
# trata como narración/descripción larga y se usa Box7 (índice 6, debe ser
# Box1 con el doble de alto).
#
# El asterisco puede no estar al inicio porque a veces hay etiquetas (\E, \F,
# colores...) antes, así que usamos `find("*") != -1` en lugar de
# `begins_with("*")`.
#
# La regla SOLO se aplica cuando el usuario no ha elegido caja explícita
# para esa string (`box_style == 0`, que es además el valor por defecto que
# IStringContainer ya trata como "no escribir BoxStyle al guardar"). Si el
# usuario seleccionó manualmente una caja distinta (Box2..6, etc.), su
# elección se respeta y la regla NO se aplica.
const _AUTO_BOX_WITH_ASTERISK: int = 0   # Box1
const _AUTO_BOX_WITHOUT_ASTERISK: int = 6 # Box7

func _compute_auto_box(_stri: IStringContainer) -> int:
	if _stri == null:
		return _AUTO_BOX_WITH_ASTERISK
	# Salvaguarda: si el style cargado todavía no tiene Box7 (p. ej. el
	# usuario abrió Deltarune sin haber añadido aún la Box7 prometida),
	# caemos a Box1 para no fijar un índice fuera de rango. update_box ya
	# hace bound-check, pero aquí lo evitamos antes para que el SpinBox
	# tampoco muestre un número que no se puede pintar.
	if Handle.box_data.size() <= _AUTO_BOX_WITHOUT_ASTERISK:
		return _AUTO_BOX_WITH_ASTERISK
	if _stri.original_content.find("*") != -1:
		return _AUTO_BOX_WITH_ASTERISK
	if _stri.content.find("*") != -1:
		return _AUTO_BOX_WITH_ASTERISK
	return _AUTO_BOX_WITHOUT_ASTERISK

# Devuelve la caja que se debe MOSTRAR para una string. Si el usuario ha
# escogido explícitamente algo distinto del valor por defecto (box_style != 0),
# se respeta su elección. Si no, se aplica la regla del asterisco.
func _resolve_box_style(_stri: IStringContainer) -> int:
	if _stri == null:
		return 0
	if _stri.box_style != 0:
		return _stri.box_style
	return _compute_auto_box(_stri)

func _on_item_list_item_selected(_index: int) -> void:
	var _item := dialogue_selector_entry_at(_index)
	change_to(_item)
	if Handle.strings.has(_item):
		var _it: Array = Handle.strings[_item]
		for _stri: IStringContainer in _it:
			# Prefijo de progreso (Bloque 1): "✓ " si está traducida, "· " si no.
			string_selector.add_item(_string_progress_prefix(_stri) + _stri.content)
		if !_it.is_empty():
			string_selector.select(0)
			string_selector.ensure_current_is_visible()
			# Bloque 2 fix: select() no emite item_selected, así que el panel
			# del validador y el checkbox de "Mark for review" no se
			# actualizaban hasta que el usuario clickeara una string. Lo
			# disparamos a mano para que el estado correcto se vea desde el
			# primer momento al abrir un archivo o cambiar de entry.
			_on_item_list_item_selected_str(0)
		else:
			# Entry vacía: no hay string que validar; limpiamos los paneles
			# para no mostrar datos huérfanos de la entry anterior.
			update_tag_validator_label()
			update_closed_sign_validator_label()
			update_needs_review_check()

func _on_item_list_item_selected_str(_index: int) -> void:
	# Bug fix (decoupling): usábamos `dialogue_selector.get_selected_items()[0]`
	# para sacar el nombre de la entry, pero tras navegar a una entry filtrada
	# por Search/GoTo/Similar, dialogue_selector podía estar vacío (la guarda
	# `if _ds_sel.is_empty(): return` salía silenciosamente y los clicks en
	# string_selector parecían no hacer nada) o apuntar a otra entry distinta
	# (se leía Handle.strings[entry_vieja][indice_de_la_nueva]: crash o datos
	# de la string equivocada). Ahora la fuente de verdad es current_entry y
	# además fijamos current_string_index = _index (vía _set_loaded) para que
	# los handlers de edición sepan en qué string está el usuario.
	if current_entry == "" or not Handle.strings.has(current_entry):
		return
	var _arr: Array = Handle.strings[current_entry]
	if _index < 0 or _index >= _arr.size():
		return
	_set_loaded(current_entry, _index)
	current_layer = 0
	current_layer_node.value = 1
	similar_entries.clear()
	var _stri: IStringContainer = _arr[_index]
	# Asignamos las cadenas de capas primero
	Handle.layer_strings = _stri.layer_strings

	# Reiniciar por defecto la casilla "Portrait" al cambiar de línea (condicional para evitar parpadeos)
	var new_has_portrait := _string_has_portrait_tags(_stri)
	if not (prev_has_portrait and new_has_portrait):
		if box:
			box.portrait_enabled = false
		if enable_portrait:
			enable_portrait.button_pressed = false
	prev_has_portrait = new_has_portrait

	if box and box.handle:
		if str(_stri.speaker) != "":
			box.handle.global_env["speaker"] = str(_stri.speaker)
		else:
			if box.handle.global_env.has("speaker"):
				box.handle.global_env.erase("speaker")
	Handle.layer_colors = _stri.layer_colors
	Handle.og_str = _stri.original_content
	var _t := create_tween()
	_t.tween_callback(func() -> void:
		current_font_node.set_value(_stri.font_style + 1)
		# Issue #3: en lugar de usar `_stri.box_style` directamente, pasamos
		# por _resolve_box_style. Si la string tiene caja explícita
		# (box_style != 0) se respeta; si no, aplicamos la regla del
		# asterisco (Box1 con `*`, Box7 sin `*`).
		current_box_node.set_value(_resolve_box_style(_stri) + 1)
	).set_delay(1.0 / 60.0)
	_t.play()
	current_color_node.color = Handle.layer_colors[current_layer]
	_set_dialogue_edit_text_silent(str(Handle.layer_strings[current_layer]))
	dialogue_edit.clear_undo_history()
	# Bloque 2: refrescar el panel del validador y el checkbox de Review
	# para reflejar la string que acabamos de seleccionar.
	update_tag_validator_label()
	update_closed_sign_validator_label()
	update_needs_review_check()
	if last_sthread is Thread:
		last_sthread.wait_to_finish()
	last_sthread = Thread.new()
	last_sthread.start(func() -> void:
		similar_entries.call_deferred("clear")
		for sstri in _stri.equal_strings:
			if sstri != _stri.id:
				var _r: IStringTable = Handle.string_table[sstri]
				similar_entries.call_deferred("add_item", "%s:%s" % [_r.name, _r.index + 1])
	)

func change_to(item: String, index: int = 0) -> void:
	if Handle.strings.has(item):
		# Bug fix (decoupling): change_to es la puerta de entrada para "cargar
		# una entry/string en el editor". Las dos asignaciones a
		# current_entry/current_string_index pasan por _set_loaded para que
		# nadie pueda olvidar actualizar las dos a la vez. A partir de aquí,
		# los handlers leen current_entry/current_string_index en lugar de
		# dialogue_selector/string_selector — el editor funciona aunque
		# dialogue_selector no contenga la entry (filtro activo).
		current_layer = 0
		current_layer_node.value = 1
		string_selector.clear()
		var _it: Array = Handle.strings[item]
		if _it.size() > index and index >= 0:
			_set_loaded(item, index)
			var _stri: IStringContainer = _it[index]
			Handle.layer_strings = _stri.layer_strings

			# Reiniciar por defecto la casilla "Portrait" al cambiar de línea (condicional para evitar parpadeos)
			var new_has_portrait := _string_has_portrait_tags(_stri)
			if not (prev_has_portrait and new_has_portrait):
				if box:
					box.portrait_enabled = false
				if enable_portrait:
					enable_portrait.button_pressed = false
			prev_has_portrait = new_has_portrait

			if str(_stri.speaker) != "":
				box.handle.global_env["speaker"] = str(_stri.speaker)
			else:
				if box.handle.global_env.has("speaker"):
					box.handle.global_env.erase("speaker")
			Handle.layer_colors = _stri.layer_colors
			Handle.og_str = _stri.original_content
			var _t := create_tween()
			_t.tween_callback(func() -> void:
				current_font_node.set_value(_stri.font_style + 1)
				# Issue #3: ver _on_item_list_item_selected_str para la
				# explicación. Mismo razonamiento aquí.
				current_box_node.set_value(_resolve_box_style(_stri) + 1)
			).set_delay(1.0 / 60.0)
			_t.play()
			current_color_node.color = Handle.layer_colors[current_layer]
			_set_dialogue_edit_text_silent(str(Handle.layer_strings[current_layer]))
			dialogue_edit.clear_undo_history()
			if last_sthread is Thread:
				last_sthread.wait_to_finish()
			last_sthread = Thread.new()
			last_sthread.start(func() -> void:
				similar_entries.call_deferred("clear")
				for sstri in _stri.equal_strings: # String ID
					if sstri != _stri.id:
						var r: IStringTable = Handle.string_table[sstri]
						similar_entries.call_deferred("add_item", "%s:%s" % [r.name, r.index + 1])
			)
		else:
			# Entry existe pero el índice está fuera de rango (típicamente entry
			# vacía). Marcamos "ninguna string cargada" pero conservamos la
			# entry como current_entry para que AddString sepa dónde añadir.
			_set_loaded(item, -1)
			if last_sthread is Thread:
				last_sthread.wait_to_finish()
			last_sthread = Thread.new()
			last_sthread.start(func() -> void:
				similar_entries.call_deferred("clear")
			)

func _on_item_list_item_selected_similar(_index: int) -> void:
	# Bug fix: parseo "name:N" robusto a `:` en el nombre (ver _parse_entry_ref).
	var _ref: Array = _parse_entry_ref(similar_entries.get_item_text(_index))
	var _item_name: String = _ref[0]
	if Handle.strings.has(_item_name):
		var _idx := (_ref[1] as int) - 1
		change_to(_item_name, _idx)
		similar_entries.deselect_all()
		similar_entries.get_v_scroll_bar().value = 0
		if last_sthread is Thread:
			last_sthread.wait_to_finish()
		last_sthread = Thread.new()
		last_sthread.start(func() -> void:
			similar_entries.call_deferred("clear")
			var _src: IStringContainer = Handle.strings[_item_name][_idx]
			for sstri: int in _src.equal_strings: # String ID
				if sstri != _src.id:
					var _r: IStringTable = Handle.string_table[sstri]
					similar_entries.call_deferred("add_item", "%s:%s" % [_r.name, _r.index + 1])
		)
		string_selector.clear()
		for _stri: IStringContainer in Handle.strings[_item_name]:
			string_selector.add_item(_string_progress_prefix(_stri) + str(_stri.layer_strings[0]))
		string_selector.select(_idx)
		string_selector.ensure_current_is_visible()
		for _i in range(dialogue_selector.get_item_count()):
			if dialogue_selector_entry_at(_i) == _item_name:
				dialogue_selector.select(_i)
				dialogue_selector.ensure_current_is_visible()
				break

func _on_dialogue_edit_text_changed() -> void:
	# Bug fix: si la asignación viene de código (cambio de string/capa/limpieza),
	# no debe contar como edición del usuario y NO debe marcar is_modified.
	if _suppress_text_signal:
		return
	# Bug fix (decoupling): leíamos `dialogue_selector.get_selected_items()[0]`
	# para sacar el nombre de la entry. Si el usuario llegó a esta entry por
	# Search/GoTo/Similar y la entry está filtrada, dialogue_selector apunta a
	# otra entry o está vacío. En el primer caso escribíamos en la string
	# equivocada (corrupción silenciosa) o crasheábamos por índice fuera de
	# rango; en el segundo, la guarda salía y la edición no tenía efecto. La
	# fuente de verdad es current_entry/current_string_index.
	if current_entry == "" or current_string_index < 0:
		return
	if not Handle.strings.has(current_entry):
		return
	var _arr_curr: Array = Handle.strings[current_entry]
	if current_string_index >= _arr_curr.size():
		return
	var _c := current_entry
	var _ss_idx := current_string_index
	# Bug fix: hasta ahora `_entries_to_refresh_global` se usaba para dos
	# decisiones a la vez —qué entries refrescar el prefijo (✓/·/⚠/★) y
	# si refrescar las stats globales—, y se rellenaba SOLO cuando una
	# string cambiaba de no-traducida a traducida. Eso causaba que un
	# cambio de tag mismatch sobre una string ya traducida (p. ej. quitas
	# un \E[x] vía replace_similar) actualizara el ⚠ en string_selector
	# pero no en la entry afectada (sobre todo en entries distintas a la
	# actual). Las separamos en dos variables:
	#   - _entries_to_refresh: SIEMPRE. Lista de entries cuyas strings
	#     cambiaron y necesitan recalcular su prefijo.
	#   - _stats_count_changed: SOLO si alguna string pasó de no-traducida
	#     a traducida (la única condición bajo la que el conteo X/Y de
	#     stats globales cambia realmente).
	var _entries_to_refresh: Dictionary = {}
	var _stats_count_changed: bool = false
	if current_layer == 0:
		# Bug fix: equal_strings YA contiene el ID propio (se construye así
		# en IFileHandler.load_file y en AddString). Antes hacíamos
		# `.duplicate() ... .append(id_propio)` directamente, lo que metía
		# el propio ID dos veces y el bucle de actualización procesaba la
		# string actual dos pasadas idénticas. Idempotente, pero trabajo
		# doble por cada tecla pulsada cuando replace_similar está activo.
		var _own_id: int = (_arr_curr[_ss_idx] as IStringContainer).id
		var _e: Array = ((_arr_curr[_ss_idx] as IStringContainer).equal_strings as Array).duplicate() if replace_similar.button_pressed else []
		if not _e.has(_own_id):
			_e.append(_own_id)
		var _entry_table := {}
		var _i := 0
		for _g: IStringContainer in _arr_curr:
			_entry_table[_g.id] = _i
			_i += 1
		Handle.is_modified = true
		for _f: int in _e: # Update all strings first (before making the entry table), then change the visualization.
			var _t: IStringTable = Handle.string_table[_f]
			var _entr: IStringContainer = Handle.strings[_t.name][_t.index]
			var _was_translated := Handle.is_string_translated(_entr)
			_entr.last_edited.author = author
			_entr.last_edited.timestamp = int(Time.get_unix_time_from_system())
			_entr.content = dialogue_edit.text
			_entr.layer_strings[0] = _entr.content
			Handle.string_ids[_entr.id] = _entr.content # We need to update properly the String ID Dictionary
			if _entry_table.has(_entr.id):
				if _entry_table[_entr.id] == _t.index:
					# El item del string_selector también lleva el prefijo de progreso.
					# Solo lo actualizamos si la entry de _entr coincide con la
					# entry cargada — string_selector muestra current_entry.
					if _t.name == _c:
						string_selector.set_item_text(_t.index, _string_progress_prefix(_entr) + dialogue_edit.text)
			# SIEMPRE marcamos la entry para refresh: el content cambió, lo
			# que puede haber alterado el tag mismatch (⚠) aunque la string
			# siguiera marcada como traducida.
			_entries_to_refresh[_t.name] = true
			if not _was_translated:
				_stats_count_changed = true
	else:
		Handle.is_modified = true
		var _f: IStringTable = Handle.string_table[(_arr_curr[_ss_idx] as IStringContainer).id]
		var _entr: IStringContainer = Handle.strings[_f.name][_f.index]
		var _was_translated := Handle.is_string_translated(_entr)
		_entr.last_edited.author = author
		_entr.last_edited.timestamp = int(Time.get_unix_time_from_system())
		_entr.layer_strings[current_layer] = dialogue_edit.text
		# Mismo criterio que en la rama de arriba: refresh de prefijo
		# siempre, stats solo si cambió el conteo de traducidas.
		_entries_to_refresh[_f.name] = true
		if not _was_translated:
			_stats_count_changed = true
		# El string_selector muestra layer_strings[0]; al editar layer != 0
		# no hace falta cambiar el texto del item, pero sí su prefijo. Solo
		# si la string editada vive en la entry actualmente cargada.
		if _f.name == _c:
			refresh_string_item_prefix(_f.index, _entr)

	# Refresco de UI. Coalescemos las partes caras en el Timer del debounce
	# (refresh_entry_item_prefix corre regex por cada string traducida; con
	# replace_similar y muchas equal_strings se notaba al teclear). Los datos
	# ya están escritos arriba, así que un save inmediato encuentra los
	# valores correctos; lo único que tarda hasta _EDIT_REFRESH_DEBOUNCE_S
	# en aplicarse es el repintado de prefijos y stats globales.
	for _en: String in _entries_to_refresh.keys():
		_entries_to_refresh_pending[_en] = true
	if _stats_count_changed:
		_stats_count_changed_pending = true
	if _edit_refresh_timer != null:
		_edit_refresh_timer.start()

	# Validador SÍ síncrono: es una sola regex y da feedback en vivo sobre
	# la string que el usuario está editando ahora mismo.
	update_tag_validator_label()
	update_closed_sign_validator_label()

# QoL: ahora delega a las funciones-flujo. Cada ID del menú mapea a una acción.
func file_menu_selected(_id: int) -> void:
	match _id:
		1:    # Open File
			open_file_flow()
		2:    # Save File
			save_file_flow()
		8:    # Save File As...
			save_as_flow()
		3:    # Settings
			settings_flow()
		5:    # Quit
			quit_flow()
		6, 7: # New File, Close File (misma funcionalidad, mismo código)
			new_file_flow()
		9:    # Delete Selected Entry (Bloque 1)
			delete_entry_flow()
		10:   # Delete Selected String (Bloque 1)
			delete_string_flow()
		12:   # Export to JSON...
			export_to_json_flow()
		13:   # Load Reference CSV...
			load_reference_csv_flow()
		14:   # Clear Reference CSV
			clear_reference_csv()

func clear_data() -> void:
	# A reference CSV is tied to the file being edited. New File / Close File
	# should remove it from the panel instead of carrying it into the next file.
	clear_reference_csv()
	# Descartar trabajo pendiente del debounce: las entries pendientes están
	# a punto de desaparecer y refrescar prefijos sobre el árbol vacío sería
	# ruido.
	_cancel_edit_refresh()
	dialogue_selector.clear()
	string_selector.clear()
	similar_entries.clear()
	# Bug fix (decoupling): reset de la fuente de verdad del editor.
	_set_loaded("", -1)
	Handle.entry_names.clear()
	Handle.strings.clear()
	Handle.string_ids.clear()
	Handle.string_table.clear()
	Handle.string_sstr.clear()
	Handle.string_sstr_arr.clear()
	Handle.string_size = 0  # Fix #3: mantener consistente con string_table.

	for _i in range(Handle.layer_colors.size()):
		Handle.layer_colors[_i] = Color.WHITE
	for _i in range(Handle.layer_strings.size()):
		Handle.layer_strings[_i] = ""
	Handle.og_str = ""
	original_dialogue.text = ""
	_set_dialogue_edit_text_silent("")
	dialogue_edit.clear_undo_history()
	current_color_node.color = Color.WHITE
	current_font_node.value = current_font_node.min_value
	current_box_node.value = current_box_node.min_value
	current_color_node.color = Color.WHITE
	Handle.last_string_id = 0
	Handle.is_modified = false
	# QoL: al hacer New File / Close File, olvidamos la ruta actual.
	Handle.current_file_path = ""
	# Archivo nuevo: las entries pueden crearse y borrarse libremente.
	_file_was_opened = false
	# Bloque 1: reset del label de progreso al cerrar el archivo.
	update_progress_stats_label()
	update_reference_panel()

func about_menu_selected(_id: int) -> void:
	match _id:
		0: # Show String Info
			Handle.show_info_window = Handle.show_info_scene.instantiate()
			add_child(Handle.show_info_window)
			Handle.show_info_window.close_requested.connect(func() -> void:
				Handle.show_info_window.queue_free()
			)
			var _n: Label = Handle.show_info_window.get_node("Label")
			var _n2: Label = Handle.show_info_window.get_node("Label2")
			var _l: LineEdit = Handle.show_info_window.get_node("LineEdit")
			var _l2: TextEdit = Handle.show_info_window.get_node("LineEdit2")
			# Bug fix (decoupling): leemos de current_entry/current_string_index
			# (la string realmente cargada en el editor) en lugar de la
			# selección de las ItemList, que pueden estar desincronizadas.
			var _stri_info := _get_current_string_container()
			if _stri_info != null:
				var _ename := current_entry
				var _eindex := current_string_index
				var _laste := _stri_info.last_edited
				var _td := Time.get_datetime_dict_from_unix_time(_laste.timestamp + int((Time.get_time_zone_from_system().bias as int) * 60)) # Local timezone?
				if _laste.author == "" || _laste.timestamp == -1:
					_n2.text = "\n\n\nNo last edit was made."
				else:
					_n2.text = _n2.text \
						.replace("AUTHOR_NAME", _laste.author) \
						.replace("TIMESTAMP", "{DAY}/{MONTH}/{YEAR} {HOUR}:{MINUTE}:{SECOND} {HFORMAT}".format({
								"DAY": str(_td["day"]).pad_zeros(2),
								"MONTH": str(_td["month"]).pad_zeros(2),
								"YEAR": str(_td["year"]).pad_zeros(4),
								"HOUR": str(12 if _td["hour"] == 0 else _td["hour"] if _td["hour"] < 13 else _td["hour"] - 12).pad_zeros(2),
								"MINUTE": str(_td["minute"]).pad_zeros(2),
								"SECOND": str(_td["second"]).pad_zeros(2),
								"HFORMAT": "a.m." if _td["hour"] < 12 else "p.m",
							}))
				_l.text = "%s:%s" % [_ename, _eindex + 1]
				_l2.text = _stri_info.original_content
			else:
				_n.text = "But Nobody Came." if randi() % 50 == 0 else "But there was nothing to see."
				_n2.hide()
				_l.hide()
				_l2.hide()
		1: # Set Author Details
			Handle.author_window = Handle.author_scene.instantiate()
			add_child(Handle.author_window)
			(Handle.author_window.get_node("Label/LineEdit") as LineEdit).text = author
		3: # About DH...
			Handle.adh_window = Handle.adh_scene.instantiate()
			add_child(Handle.adh_window)

func open_search_menu() -> void:
	Handle.search_window = Handle.search_scene.instantiate()
	add_child(Handle.search_window)

func open_go_to_menu() -> void:
	Handle.goto_window = Handle.goto_scene.instantiate()
	add_child(Handle.goto_window)
	(Handle.goto_window.get_node("GoTo/GoButton") as Button).pressed.connect(func() -> void:
		var _te := (Handle.goto_window.get_node("GoTo/Str") as LineEdit).text
		if _te.length() > 0:
			# Bug fix: parseo "name:N" robusto a `:` en el nombre (ver _parse_entry_ref).
			var _ref: Array = _parse_entry_ref(_te)
			var _item_name: String = _ref[0]
			var _idx_zero: int = (_ref[1] as int) - 1
			if Handle.strings.has(_item_name):
				change_to(_item_name, _idx_zero)
				string_selector.clear()
				for _stri: IStringContainer in Handle.strings[_item_name]:
					string_selector.add_item(_string_progress_prefix(_stri) + str(_stri.layer_strings[0]))
				string_selector.select(_idx_zero)
				string_selector.ensure_current_is_visible()
				for _i in range(dialogue_selector.get_item_count()):
					if dialogue_selector_entry_at(_i) == _item_name:
						dialogue_selector.select(_i)
						dialogue_selector.ensure_current_is_visible()
						break
		Handle.goto_window.queue_free()
	)

func entry_search_text_changed(_t: String) -> void:
	_rebuild_entry_list()

# Bloque 2: handler del OptionButton de filtros. Sólo dispara la
# reconstrucción de la lista; la lógica está centralizada en
# `_rebuild_entry_list` para que búsqueda y filtro compartan el mismo flujo.
# Aplica el trabajo de UI pendiente acumulado por
# `_on_dialogue_edit_text_changed`. Lo invoca el Timer cuando termina su
# espera; también se llama directamente desde `clear_data` (vía
# `_cancel_edit_refresh`) para descartar el pendiente cuando el archivo se
# cierra. Es idempotente y seguro de llamar con el pendiente vacío.
func _flush_edit_refresh() -> void:
	for _en: String in _entries_to_refresh_pending.keys():
		refresh_entry_item_prefix(_en)
	if _stats_count_changed_pending:
		update_progress_stats_label()
	_entries_to_refresh_pending.clear()
	_stats_count_changed_pending = false

# Descarta el trabajo pendiente y para el Timer. Se llama desde clear_data
# (las entries pendientes están a punto de desaparecer; ejecutar el flush
# sería trabajo sobre datos vacíos). Si el flujo necesitara también aplicar
# el pendiente antes de descartar (p. ej. al guardar) habría que llamar
# `_flush_edit_refresh()` antes; hoy nadie lo necesita.
func _cancel_edit_refresh() -> void:
	if _edit_refresh_timer != null:
		_edit_refresh_timer.stop()
	_entries_to_refresh_pending.clear()
	_stats_count_changed_pending = false

func _on_entry_filter_changed(_id: int) -> void:
	_rebuild_entry_list()

# Reconstruye dialogue_selector aplicando filtro + texto de búsqueda. Se
# llama desde EntrySearch.text_changed y desde EntryFilter.item_selected.
#
# Bug fix (decoupling): antes este método leía la selección actual del
# dialogue_selector para "preservarla", y si la entry no pasaba el nuevo
# filtro limpiaba string_selector y el editor —para evitar el crash conocido
# de get_selected_items()[0] vacío al clickear en una "string fantasma" de
# una entry deseleccionada—. Con la refactorización a current_entry,
# string_selector y el editor son consistentes incluso si dialogue_selector
# no contiene la entry cargada, por lo que ya no hace falta limpiar nada.
# El filtro vuelve a ser una vista pura: cambiar el filtro NO altera lo que
# se está editando. Si current_entry pasa el nuevo filtro, lo seleccionamos
# en dialogue_selector como cortesía visual; si no, dialogue_selector queda
# sin selección pero el editor sigue funcional sobre current_entry.
func _rebuild_entry_list() -> void:
	var _filter_id: int = 0
	if has_node("EntryFilter"):
		_filter_id = ($EntryFilter as OptionButton).get_selected_id()
	var _search_text: String = ""
	if has_node("EntrySearch"):
		_search_text = ($EntrySearch as LineEdit).text.to_lower()

	# Bloque 2 perf: en archivos grandes, recorrer dos veces las strings de
	# cada entry (una para _entry_passes_filter, otra para _entry_progress_prefix)
	# se notaba al cambiar filtro. Ahora calculamos un "estado agregado" en
	# una sola pasada por entry y lo usamos para ambas decisiones.
	dialogue_selector.clear()
	for _e: String in Handle.entry_names:
		if _search_text != "" and not _e.to_lower().contains(_search_text):
			continue
		var _state := _compute_entry_state(_e)
		if not _state_passes_filter(_state, _filter_id):
			continue
		dialogue_selector.add_item(_state_to_prefix(_state) + _e)

	# Cortesía visual: si la entry cargada pasa el filtro, marcarla como
	# seleccionada en la lista. Si no pasa, no se selecciona nada — pero el
	# editor sigue editando current_entry normalmente.
	if current_entry != "":
		for _i in range(dialogue_selector.get_item_count()):
			if dialogue_selector_entry_at(_i) == current_entry:
				dialogue_selector.select(_i)
				dialogue_selector.ensure_current_is_visible()
				break

# Estado agregado de una entry. Calculado en una sola pasada para que filtro
# y prefijo se compartan (perf en archivos grandes). Devuelve un Dictionary
# con flags booleanos.
func _compute_entry_state(_entry_name: String) -> Dictionary:
	var _state := {
		"empty": true,
		"all_translated": true,
		"any_untranslated": false,
		"any_review": false,
		"any_mismatch": false,
		"any_misclosed_sign": false,
	}
	if not Handle.strings.has(_entry_name):
		return _state
	var _arr: Array = Handle.strings[_entry_name]
	if _arr.is_empty():
		return _state
	_state["empty"] = false
	for _stri: IStringContainer in _arr:
		if not Handle.is_string_translated(_stri):
			_state["all_translated"] = false
			_state["any_untranslated"] = true
		if _stri.needs_review:
			_state["any_review"] = true
		# Validamos aunque no haya LastEdited. Algunos archivos pueden traer
		# Content ya distinto/problemas de tags sin metadatos de edición; si
		# aquí se saltan, la entry no muestra ⚠ hasta que el usuario toca el
		# texto y se crea LastEdited. Las regex están cacheadas en ITagValidator.
		var _diff := ITagValidator.validate_string(_stri)
		var _diff_sign := IClosedSignValidator.validate_string(_stri)
		if not _diff.ok:
			_state["any_mismatch"] = true
		if not _diff_sign.ok:
			_state["any_misclosed_sign"] = true
	return _state

func _state_passes_filter(_state: Dictionary, _filter_id: int) -> bool:
	# Castear los flags como `as bool` (no `bool(...)`): Dictionary devuelve
	# Variant y bool() acepta Variant pero el analyzer estricto se queja.
	# `as bool` es la forma idiomática y silencia UNSAFE_CALL_ARGUMENT.
	match _filter_id:
		0: return true
		1: return (_state["empty"] as bool) or (_state["any_untranslated"] as bool)
		2: return not (_state["empty"] as bool) and (_state["all_translated"] as bool)
		3: return _state["any_review"] as bool
		4: return _state["any_mismatch"] as bool
		5: return _state["any_misclosed_sign"] as bool
	return true

func _state_to_prefix(_state: Dictionary) -> String:
	# Prioridad: tag_mismatch > review > empty > done > todo. Tag mismatch es
	# un problema técnico real (rompe el juego), tiene precedencia sobre la
	# marca manual de "necesita revisión". Si la entry está marcada por el
	# usuario y además tiene mismatch, mostramos el ⚠ porque es lo más
	# urgente; el ★ vuelve a aparecer en cuanto se arregle el mismatch.
	if _state["any_mismatch"] as bool:
		return _PROGRESS_PREFIX_WARN
	if _state["any_review"] as bool:
		return _PROGRESS_PREFIX_REVIEW
	if _state["any_misclosed_sign"] as bool:
		return _PROGRESS_PREFIX_UNCLOSED_SIGN
	if _state["empty"] as bool:
		return _PROGRESS_PREFIX_EMPTY
	if _state["all_translated"] as bool:
		return _PROGRESS_PREFIX_DONE
	return _PROGRESS_PREFIX_TODO

func _on_reload_style_pressed() -> void:
	Handle.load_style()
	Handle.main_node.box.handle.force_update = true

func _on_add_entry_pressed() -> void:
	Handle.ae_window = Handle.ae_scene.instantiate()
	add_child(Handle.ae_window)

func _on_add_string_pressed() -> void:
	# Bug fix (decoupling): añadimos a la entry cargada en el editor, no a la
	# que esté marcada en dialogue_selector (puede estar desincronizada con un
	# filtro o vacía).
	if current_entry == "" or not Handle.strings.has(current_entry):
		return
	Handle.as_window = Handle.as_scene.instantiate()
	Handle.as_window.entry = current_entry
	# Si hay una string cargada, la pasamos como fuente para el modo "duplicar".
	# Si no hay (entry vacía o nada cargado), el diálogo caerá en modo "blanco".
	if current_string_index >= 0:
		var _arr: Array = Handle.strings[current_entry]
		if current_string_index < _arr.size():
			Handle.as_window.source_index = current_string_index
			Handle.as_window.source_container = _arr[current_string_index]
	add_child(Handle.as_window)
