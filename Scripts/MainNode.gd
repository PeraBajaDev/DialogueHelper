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

func _configure_dialogue_tab_visuals(edit: TextEdit) -> void:
	# draw_tabs usa el indicador nativo de TextEdit (flecha/marca de tab según
	# el tema). No reemplaza U+0009 por un carácter visible ni toca el texto.
	edit.draw_tabs = true
	edit.draw_spaces = false
	edit.set_tab_size(_DIALOGUE_EDITOR_TAB_SIZE)

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
			Handle.unsaved_changes_window = Handle.unsaved_changes_scene.instantiate()
			Handle.unsaved_changes_window.callback.connect(_on_unsaved_changes_confirmed.bind(tree.quit))
			add_child(Handle.unsaved_changes_window)
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
	var recent_idx: int = file_popup.get_item_index(11)  # id 11 = "Open Recent"
	if recent_idx != -1:
		file_popup.set_item_submenu_node(recent_idx, recent_popup)
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
		author = FileAccess.get_file_as_string("user://userlocal_name.txt").strip_edges()
	if FileAccess.file_exists("user://enable_git.bool"):
		var branch := ""
		if FileAccess.file_exists("user://git_branch.txt"):
			branch = FileAccess.get_file_as_string("user://git_branch.txt").strip_edges()
		Handle.git.url = FileAccess.get_file_as_string("user://git_url.txt").strip_edges()
		Handle.git.branch = branch
	if FileAccess.file_exists("user://scale.txt"):
		var raw := FileAccess.get_file_as_string("user://scale.txt").strip_escapes().strip_edges()
		var v := float(raw)
		if v > 0.0:
			current_scale_node.value = v
			Handle.visual_scale = v  # Sync para evitar is_modified=true espurio en el primer frame.

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
	var stored_style: String = ""
	if FileAccess.file_exists("user://last_style.txt"):
		stored_style = FileAccess.get_file_as_string("user://last_style.txt").strip_edges()

	var stored_is_valid: bool = stored_style != "" \
		and FileAccess.file_exists(Handle.style_get_path("Metadata.json", stored_style))

	if stored_is_valid:
		Handle.load_style(stored_style)
	else:
		Handle.load_style(Handle.pick_default_style())
		if Handle.list_available_styles().size() >= 2:
			# Diferimos al siguiente frame para que el resto de _ready termine
			# de configurar la UI antes de superponer el diálogo modal.
			_show_style_picker()
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
	_check_autosave_recovery()

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
		var new_font := int(current_font_node.value - 1)
		# Detectar si esto es sincronización con la string seleccionada (cambió
		# el SpinBox porque cambió la string activa) o si fue el usuario quien
		# pulsó el SpinBox. Si el valor coincide con el font_style de la string
		# actual, es sync y NO hay que marcar is_modified ni reescribir nada.
		# Bug fix (decoupling): leíamos dialogue_selector + string_selector,
		# pero con una entry filtrada esos no apuntan a la string cargada.
		# Vamos por _get_current_string_container, que consulta current_entry
		# y current_string_index.
		var is_sync := false
		var stri_ref: IStringContainer = _get_current_string_container()
		if stri_ref != null and stri_ref.font_style == new_font:
			is_sync = true
		update_font(new_font, !is_sync)
		if !is_sync && stri_ref != null:
			stri_ref.font_style = current_font_id
	if current_box_node.value - 1 != current_box:
		var new_box := int(current_box_node.value - 1)
		var is_sync_b := false
		var stri_ref_b: IStringContainer = _get_current_string_container()
		if stri_ref_b != null:
			# Issue #3: además del valor guardado en `box_style`,
			# aceptamos como "sync" cualquier valor que coincida con
			# `_resolve_box_style`. Sin esto, al seleccionar una
			# string sin asterisco la regla del asterisco fija el
			# SpinBox en Box7, _process detecta el cambio, no
			# encuentra match con `box_style` (que sigue siendo 0)
			# y marca el archivo como modificado al instante.
			if stri_ref_b.box_style == new_box:
				is_sync_b = true
			elif _resolve_box_style(stri_ref_b) == new_box:
				is_sync_b = true
		update_box(new_box, !is_sync_b)
		if !is_sync_b && stri_ref_b != null:
			stri_ref_b.box_style = current_box
	if current_scale_node.value != Handle.visual_scale:
		Handle.is_modified = true
		Handle.visual_scale = current_scale_node.value
		box.handle.queue_redraw()
		box.sprite.scale = Vector2(Handle.visual_scale, Handle.visual_scale)
		_request_scale_save()
	while Handle.layer_strings.size() < Handle.layers:
		Handle.layer_strings.append("")
	while Handle.layer_colors.size() < Handle.layers:
		Handle.layer_colors.append(Color.WHITE)
	Handle.layer_strings[current_layer] = dialogue_edit.text
	if Handle.layer_colors[current_layer] != current_color_node.color:
		Handle.is_modified = true
		Handle.layer_colors[current_layer] = current_color_node.color
	if original_dialogue.text != Handle.original_string:
		original_dialogue.text = Handle.original_string
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
	var key_event: InputEventKey = event
	if not key_event.pressed or key_event.echo:
		return
	# Exigimos Ctrl, pero NO Alt ni Meta (evita colisiones con atajos del SO).
	if not key_event.ctrl_pressed or key_event.alt_pressed or key_event.meta_pressed:
		return
	# Si hay una operación de disco en curso, ignoramos los atajos.
	if _io_busy():
		return

	match key_event.keycode:
		KEY_S:
			if key_event.shift_pressed:
				save_as_flow()
			else:
				save_file_flow()
			get_viewport().set_input_as_handled()
		KEY_O:
			if key_event.shift_pressed:
				return
			open_file_flow()
			get_viewport().set_input_as_handled()
		KEY_W:
			if key_event.shift_pressed:
				return
			close_file_flow()
			get_viewport().set_input_as_handled()
		KEY_Q:
			if key_event.shift_pressed:
				return
			quit_flow()
			get_viewport().set_input_as_handled()
		KEY_F:
			if key_event.shift_pressed:
				return
			open_search_menu()
			get_viewport().set_input_as_handled()
		KEY_G:
			if key_event.shift_pressed:
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
	var key_event: InputEventKey = event
	if not key_event.pressed:
		return
	# OJO: aquí NO filtramos ke.echo. Godot marca como echo los eventos
	# repetidos al mantener pulsada una tecla; dejarlos pasar es justo lo
	# que permite mantener Ctrl/Alt + ↑/↓ para navegar rápido. Los atajos
	# de menú (Ctrl+S/O/etc.) siguen filtrando echo en _unhandled_key_input.
	# Solo nos interesan ↑/↓; cualquier otra tecla se deja pasar intacta.
	if key_event.keycode != KEY_UP and key_event.keycode != KEY_DOWN:
		return
	# Meta (tecla Win/Cmd) no se usa aquí: evita colisiones con atajos del SO.
	if key_event.meta_pressed:
		return
	# Modificadores EXCLUSIVOS: Ctrl-solo mueve strings; Alt-solo mueve entries.
	# Cualquier otra combinación (Shift de por medio, los dos a la vez, o ninguno)
	# no hace nada y deja pasar el evento, para no romper la edición/selección
	# normal del texto.
	var only_ctrl: bool = key_event.ctrl_pressed and not key_event.alt_pressed and not key_event.shift_pressed
	var only_alt: bool = key_event.alt_pressed and not key_event.ctrl_pressed and not key_event.shift_pressed
	if not (only_ctrl or only_alt):
		return
	# Si hay una operación de disco en curso, ignoramos los atajos.
	if _io_busy():
		return
	var delta: int = -1 if key_event.keycode == KEY_UP else 1
	if only_ctrl:
		_nav_string(delta)
	else:
		_nav_entry(delta)
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
	var last_line: int = maxi(dialogue_edit.get_line_count() - 1, 0)
	dialogue_edit.deselect()
	dialogue_edit.set_caret_line(last_line)
	dialogue_edit.set_caret_column(dialogue_edit.get_line(last_line).length())

# Navegación por teclado entre STRINGS de la entry cargada (Ctrl+↑ / Ctrl+↓).
# Mueve la selección de string_selector y dispara el mismo handler que un click,
# porque select() no emite la señal item_selected por sí solo.
func _nav_string(delta: int) -> void:
	if current_entry == "" or not Handle.strings.has(current_entry):
		return
	var count: int = string_selector.get_item_count()
	if count == 0:
		return
	# Sin string cargada todavía: la primera pulsación selecciona la primera.
	if current_string_index < 0:
		string_selector.select(0)
		string_selector.ensure_current_is_visible()
		_on_item_list_item_selected_str(0)
		return
	var new: int = clampi(current_string_index + delta, 0, count - 1)
	if new == current_string_index:
		return
	string_selector.select(new)
	string_selector.ensure_current_is_visible()
	_on_item_list_item_selected_str(new)

# Navegación por teclado entre ENTRIES (Alt+↑ / Alt+↓).
# Opera sobre dialogue_selector, que puede estar filtrado por Search/GoTo, así
# que el índice actual se resuelve por selección visible y, si no, por nombre.
func _nav_entry(delta: int) -> void:
	var count: int = dialogue_selector.get_item_count()
	if count == 0:
		return
	var cur: int = -1
	var sel: PackedInt32Array = dialogue_selector.get_selected_items()
	if sel.size() > 0:
		cur = sel[0]
	else:
		for i in count:
			if dialogue_selector_entry_at(i) == current_entry:
				cur = i
				break
	var new: int
	if cur == -1:
		# La entry cargada no está en la lista visible (filtro activo): arrancamos
		# por el extremo correspondiente al sentido de la pulsación.
		new = 0 if delta > 0 else count - 1
	else:
		new = clampi(cur + delta, 0, count - 1)
		if new == cur:
			return
	dialogue_selector.select(new)
	dialogue_selector.ensure_current_is_visible()
	# select() no emite item_selected; replicamos el click: change_to() limpia y
	# carga la entry, y se repuebla string_selector seleccionando la primera string.
	_on_item_list_item_selected(new)

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
	var idx: int = file_popup.get_item_index(menu_id)
	if idx != -1:
		file_popup.set_item_accelerator(idx, accel)

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
	var idx_del_entry: int = file_popup.get_item_index(9)
	var idx_del_string: int = file_popup.get_item_index(10)
	var idx_clear_ref: int = file_popup.get_item_index(14)

	if idx_del_entry != -1:
		file_popup.set_item_disabled(idx_del_entry, _file_was_opened)

	if idx_del_string != -1:
		var clave: String = _get_current_clave()
		var is_sp: bool = clave.begins_with("sp_")
		file_popup.set_item_disabled(idx_del_string, not is_sp)

	if idx_clear_ref != -1:
		file_popup.set_item_disabled(idx_clear_ref, reference_table.source_path == "")

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
	var w := preload("res://Subwindows/StyleSelector.tscn").instantiate()
	add_child(w)

# Helper: asigna texto al editor sin disparar la lógica de "edición del usuario".
# Lo usamos en cualquier sitio que reescriba `dialogue_edit.text` por motivos
# que NO son una pulsación del usuario (cambio de string, cambio de capa,
# clear_data...). Sin esto, esas asignaciones disparan text_changed y
# is_modified termina marcado a true por nada.
func _set_dialogue_edit_text_silent(text: String) -> void:
	_suppress_text_signal = true
	dialogue_edit.text = text
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

func _strip_progress_prefix(text: String) -> String:
	for _p: String in _PROGRESS_PREFIXES:
		if text.begins_with(_p):
			return text.substr(_p.length())
	return text

# Wrapper público: devuelve el nombre real (sin prefijo) del item del
# dialogue_selector en el índice indicado. Es el equivalente "limpio" de
# `dialogue_selector_entry_at(i)` y debe usarse siempre que el valor
# se vaya a buscar en Handle.strings o comparar con un nombre real.
func dialogue_selector_entry_at(index: int) -> String:
	if index < 0 or index >= dialogue_selector.get_item_count():
		return ""
	return _strip_progress_prefix(dialogue_selector.get_item_text(index))

func _entry_progress_prefix(entry_local_name: String) -> String:
	if not Handle.strings.has(entry_local_name):
		return _PROGRESS_PREFIX_EMPTY
	var array: Array = Handle.strings[entry_local_name]
	if array.is_empty():
		return _PROGRESS_PREFIX_EMPTY
	# Bloque 2: prioridad de prefijo (mismo orden que _state_to_prefix).
	# Tag mismatch tiene prioridad sobre review porque es un problema
	# técnico que rompe el juego, mientras que review es un recordatorio.
	var has_mismatch: bool = false
	var has_review: bool = false
	var has_unclosed_sign: bool = false
	for _stri: IStringContainer in array:
		if _string_has_tag_mismatch(_stri):
			has_mismatch = true
			break  # No hace falta seguir, mismatch ya gana
		if _stri.needs_review:
			has_review = true
		has_unclosed_sign = _string_has_misclosed_sign(_stri)
	if has_mismatch:
		return _PROGRESS_PREFIX_WARN
	if has_review:
		return _PROGRESS_PREFIX_REVIEW
	if has_unclosed_sign:
		return _PROGRESS_PREFIX_UNCLOSED_SIGN
	if Handle.is_entry_fully_translated(entry_local_name):
		return _PROGRESS_PREFIX_DONE
	return _PROGRESS_PREFIX_TODO

func _string_progress_prefix(string_container: IStringContainer) -> String:
	# Misma prioridad que en entries: mismatch > review > done > todo.
	if _string_has_tag_mismatch(string_container):
		return _PROGRESS_PREFIX_WARN
	if string_container != null and string_container.needs_review:
		return _PROGRESS_PREFIX_REVIEW
	if _string_has_misclosed_sign(string_container):
		return _PROGRESS_PREFIX_UNCLOSED_SIGN
	if Handle.is_string_translated(string_container):
		return _PROGRESS_PREFIX_DONE
	return _PROGRESS_PREFIX_TODO

# Bloque 2: validación de tags. Sólo se aplica si la string tiene tags
# relevantes (en original o en traducción). Una string sin tags no se
# considera "mismatch" — `validate_string` devuelve ok=true igualmente,
# pero centralizamos aquí por claridad.
func _string_has_tag_mismatch(string_container: IStringContainer) -> bool:
	if string_container == null:
		return false
	var diff := ITagValidator.validate_string(string_container)
	return not diff.ok

func _string_has_misclosed_sign(string_container: IStringContainer) -> bool:
	if string_container == null:
		return false
	var diff := IClosedSignValidator.validate_string(string_container)
	return not diff.ok
# Recalcula el prefijo del item de dialogue_selector que corresponde a la
# entry indicada. Si por algún motivo no se encuentra, no hace nada.
func refresh_entry_item_prefix(entry_local_name: String) -> void:
	if dialogue_selector == null:
		return
	for i in range(dialogue_selector.get_item_count()):
		var txt := _strip_progress_prefix(dialogue_selector.get_item_text(i))
		if txt == entry_local_name:
			dialogue_selector.set_item_text(i, _entry_progress_prefix(entry_local_name) + entry_local_name)
			return

# Recalcula el prefijo de un item del string_selector. La string vista en el
# selector usa _stri.content como texto.
func refresh_string_item_prefix(index: int, string_container: IStringContainer) -> void:
	if string_selector == null or index < 0 or index >= string_selector.get_item_count():
		return
	string_selector.set_item_text(index, _string_progress_prefix(string_container) + string_container.content)

# Refresca todos los items de dialogue_selector. Útil tras cargar un archivo.
func refresh_all_entry_prefixes() -> void:
	if dialogue_selector == null:
		return
	for i in range(dialogue_selector.get_item_count()):
		var local_name := _strip_progress_prefix(dialogue_selector.get_item_text(i))
		dialogue_selector.set_item_text(i, _entry_progress_prefix(local_name) + local_name)

# Label de estadísticas globales: "1234 / 5678 strings (21.7%)"
func update_progress_stats_label() -> void:
	if progress_stats_label == null:
		return
	var p := Handle.global_translation_progress()
	var done: int = p[0]
	var total: int = p[1]
	if total == 0:
		progress_stats_label.text = "0 / 0 strings"
		return
	var pct := 100.0 * float(done) / float(total)
	progress_stats_label.text = "%d / %d strings (%.1f%%)" % [done, total, pct]

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
	var string_container := _get_current_string_container()
	if string_container == null:
		tag_validator_label.text = ""
		tag_validator_label.tooltip_text = ""
		return
	var diff := ITagValidator.validate_string(string_container)
	# Bloque 2: si NI el original NI la traducción contienen tags, el panel
	# se queda vacío. Mostrar "✓ Tags OK" en cada línea de texto plano sólo
	# añade ruido visual sin informar de nada útil. El panel sólo aparece
	# cuando hay algo que validar (o cuando el usuario rompió la simetría
	# añadiendo tags donde no había).
	if not diff.has_any_tag:
		tag_validator_label.text = ""
		tag_validator_label.tooltip_text = ""
		return
	tag_validator_label.text = diff.to_label_text()
	# Color sobrio: verde apagado si OK, ámbar si hay mismatch.
	if diff.ok:
		tag_validator_label.add_theme_color_override(&"font_color", Color(0.55, 0.85, 0.55))
		tag_validator_label.tooltip_text = "Tag count matches the original."
	else:
		tag_validator_label.add_theme_color_override(&"font_color", Color(1.0, 0.65, 0.4))
		tag_validator_label.tooltip_text = "Tag mismatch with the original. Check \\E[x], \\F[x], %, /, etc."

func update_closed_sign_validator_label() -> void:
	if closed_sign_validator_label == null:
		return
	var string_container := _get_current_string_container()

	if string_container == null:
		closed_sign_validator_label.text = ""
		closed_sign_validator_label.tooltip_text = ""
		return

	var diff := IClosedSignValidator.validate_string(string_container)
	if not diff.has_any_sign:
		closed_sign_validator_label.text = ""
		closed_sign_validator_label.tooltip_text = ""
		return
	closed_sign_validator_label.text = diff.to_label_text()
	# Color sobrio: verde apagado si OK, ámbar si hay mismatch.
	if diff.ok:
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
	var string_container := _get_current_string_container()
	if string_container == null:
		needs_review_check.set_pressed_no_signal(false)
		needs_review_check.disabled = true
		return
	needs_review_check.disabled = false
	needs_review_check.set_pressed_no_signal(string_container.needs_review)

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
	var array: Array = Handle.strings[current_entry]
	if current_string_index >= array.size():
		return null
	return array[current_string_index]

func _on_needs_review_toggled(pressed: bool) -> void:
	var string_container := _get_current_string_container()
	if string_container == null:
		return
	if string_container.needs_review == pressed:
		return  # Ya estaba en ese estado (sync programático).
	string_container.needs_review = pressed
	Handle.is_modified = true
	# Refrescar el ítem actual del string_selector y el de la entry.
	# Bug fix (decoupling): leemos current_entry/current_string_index, que es
	# lo que de verdad está cargado. Si la entry no aparece en
	# dialogue_selector (filtrada) refresh_entry_item_prefix es no-op para esa
	# entry; refresh_string_item_prefix sí actualiza porque string_selector
	# siempre refleja current_entry.
	if current_string_index >= 0:
		refresh_string_item_prefix(current_string_index, string_container)
	if current_entry != "":
		refresh_entry_item_prefix(current_entry)

# Título de la ventana: "archivo.txt* — Dialogue Helper".
# El asterisco aparece cuando hay cambios sin guardar.
func update_window_title() -> void:
	var base: String = "Dialogue Helper"
	var flocal_name: String = "Untitled"
	if Handle.current_file_path != "":
		flocal_name = Handle.current_file_path.get_file()
	var mod: String = "*" if Handle.is_modified else ""
	tree.root.title = "%s%s — %s" % [flocal_name, mod, base]

# ---------------------------------------------------------------------------
# QoL: flujos reutilizables para File (los llama tanto el menú como los atajos)
# ---------------------------------------------------------------------------

func _on_files_dropped(files: PackedStringArray) -> void:
	# Bug fix: el resto de flujos de carga (open_file_flow, _on_recent_selected,
	# atajos de teclado) pasan por _io_busy() para no pisar un save/load en
	# curso. El drop de archivo no lo hacía: si el usuario soltaba un .txt
	# mientras un thread anterior seguía vivo, _launch_load_thread reasignaba
	# last_thread y el viejo nunca se unía.
	if _io_busy():
		return
	if files.size() != 1 or not files.get(0).ends_with(".txt"):
		return
	var path: String = files.get(0)
	var do_load := func() -> void:
		_launch_load_thread(path)
	if Handle.is_modified:
		Handle.unsaved_changes_window = Handle.unsaved_changes_scene.instantiate()
		Handle.unsaved_changes_window.callback.connect(_on_unsaved_changes_confirmed.bind(do_load))
		add_child(Handle.unsaved_changes_window)
	else:
		do_load.call()

func open_file_flow() -> void:
	if _io_busy():
		return
	var do_open := func() -> void:
		if FileAccess.file_exists("user://enable_git.bool"):
			_launch_load_thread("user://repo/Strings.txt")
		else:
			Handle.file_dialog_window = Handle.load_file_scene.instantiate()
			# Pre-rellena la ruta con el archivo actual, si hay uno.
			if Handle.current_file_path != "":
				Handle.file_dialog_window.current_path = Handle.current_file_path
			Handle.file_dialog_window.file_selected.connect(_launch_load_thread)
			# Bug fix (Issue #1): al cancelar/cerrar el FileDialog nativo, Godot
			# emite el error interno
			#   window_move_to_foreground: Condition "!windows.has(p_window)" is true.
			# (godotengine/godot#98083, fix en PR #98194). El motor intenta
			# devolver el foco a una ventana ya liberada porque hacíamos
			# `queue_free` inmediatamente al cancelar. La solución es la misma
			# que ya usa el flujo de éxito (_launch_load_thread): liberar la
			# ventana 1 frame más tarde con un tween, y poner la referencia
			# global a null en el acto para que ningún otro código la toque.
			Handle.file_dialog_window.close_requested.connect(_close_fd_window_deferred)
			Handle.file_dialog_window.canceled.connect(_close_fd_window_deferred)
			add_child(Handle.file_dialog_window)
			Handle.file_dialog_window.show()
	if Handle.is_modified:
		Handle.unsaved_changes_window = Handle.unsaved_changes_scene.instantiate()
		Handle.unsaved_changes_window.callback.connect(_on_unsaved_changes_confirmed.bind(do_open))
		add_child(Handle.unsaved_changes_window)
	else:
		do_open.call()

# Limpieza diferida del FileDialog de Open. Patrón equivalente al de
# _launch_load_thread pero pensado para cancelaciones: capturamos el nodo en
# una variable local, anulamos Handle.fd_window inmediatamente, y un frame
# después hacemos queue_free. Así Godot ya ha terminado de devolver el foco
# a la ventana principal cuando el FileDialog desaparece.
func _close_fd_window_deferred() -> void:
	var window: FileDialog = Handle.file_dialog_window
	Handle.file_dialog_window = null
	if not is_instance_valid(window):
		return
	var tween := create_tween()
	tween.tween_callback(func() -> void:
		if is_instance_valid(window):
			window.queue_free()
	).set_delay(1.0 / 60.0)
	tween.play()

func _launch_load_thread(path: String) -> void:
	# A reference CSV belongs to the currently opened .txt only. Opening another
	# file should start with a clean reference panel.
	clear_reference_csv()
	var tween := create_tween()
	tween.tween_callback(func() -> void:
		if Handle.file_dialog_window != null:
			Handle.file_dialog_window.free()
			Handle.file_dialog_window = null
		Handle.loading_window = Handle.loading_scene.instantiate()
		add_child(Handle.loading_window)
		last_thread = IFileHandler.load_file(path)
	).set_delay(1.0 / 60.0)
	tween.play()

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
	Handle.save_file_window = Handle.save_file_scene.instantiate()
	# Pre-rellena con la ruta actual si existe, para que el diálogo no parta de cero.
	if Handle.current_file_path != "":
		Handle.save_file_window.current_path = Handle.current_file_path
	Handle.save_file_window.file_selected.connect(_launch_save_thread)
	# Bug fix (Issue #1): mismo razonamiento que en open_file_flow. El
	# FileDialog nativo de Save también soltaba
	#   window_move_to_foreground: Condition "!windows.has(p_window)" is true.
	# si se cancelaba estando ya con un archivo abierto. Liberamos diferido.
	Handle.save_file_window.close_requested.connect(_close_fds_window_deferred)
	Handle.save_file_window.canceled.connect(_close_fds_window_deferred)
	add_child(Handle.save_file_window)
	Handle.save_file_window.show()

# Limpieza diferida del FileDialog de Save. Mismo patrón que
# _close_fd_window_deferred (ver explicación allí).
func _close_fds_window_deferred() -> void:
	var w: FileDialog = Handle.save_file_window
	Handle.save_file_window = null
	if not is_instance_valid(w):
		return
	var tween := create_tween()
	tween.tween_callback(func() -> void:
		if is_instance_valid(w):
			w.queue_free()
	).set_delay(1.0 / 60.0)
	tween.play()

func _launch_save_thread(path: String) -> void:
	var tween := create_tween()
	tween.tween_callback(func() -> void:
		if Handle.save_file_window != null:
			Handle.save_file_window.free()
			Handle.save_file_window = null
		Handle.saving_window = Handle.saving_scene.instantiate()
		add_child(Handle.saving_window)
		# save_file ya no devuelve Thread; el seguimiento se hace vía
		# IFileHandler.io_in_progress, consultado por _io_busy().
		IFileHandler.save_file(path)
	).set_delay(1.0 / 60.0)
	tween.play()

func new_file_flow() -> void:
	if _io_busy():
		return
	if Handle.is_modified:
		Handle.unsaved_changes_window = Handle.unsaved_changes_scene.instantiate()
		Handle.unsaved_changes_window.callback.connect(_on_unsaved_changes_confirmed.bind(clear_data))
		add_child(Handle.unsaved_changes_window)
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
		Handle.unsaved_changes_window = Handle.unsaved_changes_scene.instantiate()
		Handle.unsaved_changes_window.callback.connect(_on_unsaved_changes_confirmed.bind(tree.quit))
		add_child(Handle.unsaved_changes_window)
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
	var txt := FileAccess.get_file_as_string(_RECENT_FILES_PATH)
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Array:
		var result: Array = []
		for v: Variant in (parsed as Array):
			if v is String and (v as String) != "":
				result.append(v)
				if result.size() >= _RECENT_FILES_MAX:
					break
		return result
	return []

func _save_recent_files(list: Array) -> void:
	var f := FileAccess.open(_RECENT_FILES_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(list))
	f.flush()
	f.close()

# Añade una ruta al principio de la lista (deduplica) y persiste. Llamada
# por load_file_data tras un open exitoso y por el flujo de save tras
# guardar. Manteniendo "exitoso" como única condición evita rutas inválidas.
func push_recent_file(path: String) -> void:
	if path == "" or path.begins_with("user://"):
		# No guardamos rutas internas (modo git escribe a user://repo/...).
		return
	var list := _load_recent_files()
	# Deduplicar (case-insensitive en Windows sería más correcto, pero el
	# sistema de archivos del usuario lo arbitrará si abre dos veces).
	list.erase(path)
	list.push_front(path)
	while list.size() > _RECENT_FILES_MAX:
		list.pop_back()
	_save_recent_files(list)

func _rebuild_recent_submenu() -> void:
	if recent_popup == null:
		return
	recent_popup.clear()
	var list := _load_recent_files()
	if list.is_empty():
		recent_popup.add_item("(no recent files)")
		recent_popup.set_item_disabled(0, true)
		return
	var i := 0
	for path: String in list:
		var label: String = path.get_file()
		if not FileAccess.file_exists(path):
			label += "  (missing)"
		# Usamos el índice como id del item; la posición es estable durante
		# la vida del popup (lo limpiamos antes de cada mostrar).
		recent_popup.add_item(label, i)
		recent_popup.set_item_tooltip(i, path)
		i += 1
	recent_popup.add_separator()
	recent_popup.add_item("Clear Recent Files", _RECENT_CLEAR_ID)

func _on_recent_selected(id: int) -> void:
	if id == _RECENT_CLEAR_ID:
		_save_recent_files([])
		return
	var list := _load_recent_files()
	if id < 0 or id >= list.size():
		return
	var path: String = list[id]
	if not FileAccess.file_exists(path):
		# La ruta ya no es válida: la sacamos de la lista y avisamos al usuario.
		list.remove_at(id)
		_save_recent_files(list)
		_show_load_error("File no longer exists:\n%s\n\nIt has been removed from the recent list." % path)
		return
	# Mismo flujo que un Open File normal, respetando "unsaved changes".
	if _io_busy():
		return
	var do_load := func() -> void:
		_launch_load_thread(path)
	if Handle.is_modified:
		Handle.unsaved_changes_window = Handle.unsaved_changes_scene.instantiate()
		Handle.unsaved_changes_window.callback.connect(_on_unsaved_changes_confirmed.bind(do_load))
		add_child(Handle.unsaved_changes_window)
	else:
		do_load.call()

# ---------------------------------------------------------------------------
# Bloque 1: errores y advertencias al cargar archivo
# ---------------------------------------------------------------------------
# Antes, si la carga fallaba (archivo inaccesible, formato roto), el flujo
# se silenciaba y el usuario se quedaba con datos a medias. Ahora IFileHandler
# detecta estos casos y nos llama aquí para mostrar un diálogo informativo.
# Reusamos la ventana StyleError porque ya está montada con un TextEdit
# scrollable y queue_free al cerrar — basta con cambiar el título y el texto.

func _show_load_error(msg: String) -> void:
	var w := Handle.style_error_scene.instantiate() as Window
	w.title = "Error loading file"
	(w.get_node(^"TextEdit") as TextEdit).text = msg
	add_child(w)

func _show_load_warning(msg: String) -> void:
	var w := Handle.style_error_scene.instantiate() as Window
	w.title = "File loaded with warnings"
	(w.get_node(^"TextEdit") as TextEdit).text = msg
	add_child(w)

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
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.use_native_dialog = true
	dlg.show_hidden_files = true
	dlg.add_filter("*.json", "JSON File")
	# Pre-rellenar carpeta y nombre: misma carpeta que el .txt, mismo nombre
	# base con extensión .json.
	if Handle.current_file_path != "":
		dlg.current_dir = Handle.current_file_path.get_base_dir()
		dlg.current_file = Handle.current_file_path.get_file().get_basename() + ".json"
	else:
		dlg.current_file = "export.json"
	_fdj_window = dlg
	dlg.file_selected.connect(func(p: String) -> void:
		_close_fdj_window_deferred()
		_do_export_json(p)
	)
	dlg.close_requested.connect(_close_fdj_window_deferred)
	dlg.canceled.connect(_close_fdj_window_deferred)
	add_child(dlg)
	dlg.show()

# Limpieza diferida del FileDialog de Export JSON. Mismo patrón que
# _close_fd_window_deferred (ver explicación allí).
func _close_fdj_window_deferred() -> void:
	var w: FileDialog = _fdj_window
	_fdj_window = null
	if not is_instance_valid(w):
		return
	var tween := create_tween()
	tween.tween_callback(func() -> void:
		if is_instance_valid(w):
			w.queue_free()
	).set_delay(1.0 / 60.0)
	tween.play()

# Construye el dict {clave: valor} y lo escribe como JSON indentado.
# Itera Handle.entry_names para respetar el orden de inserción del .txt.
# Salta las strings con clave vacía (no deben aparecer en el JSON).
func _do_export_json(path: String) -> void:
	var dict := {}
	for _entry: String in Handle.entry_names:
		if not Handle.strings.has(_entry):
			continue
		for string_container: IStringContainer in (Handle.strings[_entry] as Array):
			if string_container.key == "":
				continue
			# Convención "null": la cadena literal "null" se exporta como JSON null
			# para que el round-trip sea idempotente con txt_a_json() de Python.
			if string_container.content == "null":
				dict[string_container.key] = null
			else:
				dict[string_container.key] = string_container.content
	var json_str: String = JSON.stringify(dict, "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_show_load_error("Could not write JSON file:\n%s\n\nError code: %d" % [
			path, FileAccess.get_open_error()])
		return
	f.store_string(json_str)
	f.flush()
	f.close()

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

func _on_is_modified_changed(value: bool) -> void:
	if value:
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

	var payload_arr := IFileHandler._build_save_payload()
	var payload: String = "\n".join(PackedStringArray(payload_arr))

	# Escritura atómica: tmp + relocal_name. Si fallamos en cualquier paso,
	# salimos sin tocar el autosave previo (si lo había).
	var tmp := _AUTOSAVE_PATH + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(payload)
	f.flush()
	f.close()
	if DirAccess.rename_absolute(tmp, _AUTOSAVE_PATH) != OK:
		# Si el relocal_name falla, el .tmp queda huérfano; lo limpiamos para
		# no dejar basura en user://.
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(tmp)
		return

	# Meta: ruta original + timestamp del propio autosave. La ruta
	# vacía indica un archivo nuevo (sin guardar nunca); en ese caso,
	# tras Recover, el usuario tendrá que hacer Save As.
	var meta := {
		"original_path": Handle.current_file_path,
		"timestamp": int(Time.get_unix_time_from_system()),
		"app_version": "DialogueHelper",
	}
	var mf := FileAccess.open(_AUTOSAVE_META_PATH, FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify(meta))
		mf.flush()
		mf.close()

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
func _on_unsaved_changes_confirmed(action: Callable) -> void:
	_discard_autosave_files()
	action.call()

# Detección al arrancar. Si hay un autosave en disco, mostramos el diálogo.
# Llamado desde _ready DESPUÉS de cargar el style y antes de que el usuario
# pueda hacer nada — así no compite con su input.
func _check_autosave_recovery() -> void:
	if not FileAccess.file_exists(_AUTOSAVE_PATH):
		return
	# Leer meta si existe, para mostrar info útil en el diálogo.
	var original_path: String = ""
	var timestamp: int = 0
	if FileAccess.file_exists(_AUTOSAVE_META_PATH):
		var mf := FileAccess.get_file_as_string(_AUTOSAVE_META_PATH)
		var parsed: Variant = JSON.parse_string(mf)
		if parsed is Dictionary:
			var d: Dictionary = parsed
			original_path = str(d.get("original_path", ""))
			# Mismo patrón que con bool(): Dictionary.get() devuelve Variant
			# y int() acepta Variant, pero el analyzer estricto se queja.
			# `as int` es la forma idiomática y silencia el warning.
			timestamp = d.get("timestamp", 0) as int

	var w: WRecoverAutosave = _RECOVER_AUTOSAVE_SCENE.instantiate()
	# Mensaje: cuándo y de qué archivo. Si no hay timestamp, omitimos
	# la fecha. Si el archivo es "untitled" (no guardado), lo decimos.
	var when: String = ""
	if timestamp > 0:
		when = "from " + Time.get_datetime_string_from_unix_time(timestamp).replace("T", " ")
	var what: String = "Untitled (never saved)"
	if original_path != "":
		what = original_path
	var msg := "An autosave from a previous session was found.\n\n"
	msg += "File: " + what + "\n"
	if when != "":
		msg += "Date: " + when + "\n"
	msg += "\nRecover this work, or discard it?"
	w.message = msg
	w.recover_requested.connect(func() -> void:
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
		w.tree_exited.connect(func() -> void:
			_recover_from_autosave(original_path)
		, CONNECT_ONE_SHOT)
	)
	w.discard_requested.connect(func() -> void:
		_discard_autosave_files()
	)
	add_child(w)

# Carga el contenido del autosave como si fuera el archivo original.
# Restaura current_file_path desde el meta (vía _override_path en load_file)
# y marca is_modified=true en el mismo commit, evitando races.
func _recover_from_autosave(original_path: String) -> void:
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
	last_thread = IFileHandler.load_file(_AUTOSAVE_PATH, original_path, true)

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
	var entry_local_name := current_entry
	var str_count: int = (Handle.strings[entry_local_name] as Array).size()
	var w: WConfirmDelete = _CONFIRM_DELETE_SCENE.instantiate()
	w.message = "Delete entry \"%s\" and all of its %d string(s)?\n\nThis cannot be undone after saving." % [entry_local_name, str_count]
	w.confirmed.connect(func() -> void:
		_perform_delete_entry(entry_local_name)
	)
	add_child(w)

func delete_string_flow() -> void:
	if _io_busy():
		return
	# Bug fix (decoupling): borramos la string cargada en el editor, no la
	# selección visual de los list views.
	if current_entry == "" or current_string_index < 0:
		return
	if not Handle.strings.has(current_entry):
		return
	var entry_local_name := current_entry
	var array: Array = Handle.strings[entry_local_name]
	var idx: int = current_string_index
	if idx >= array.size():
		return
	var w: WConfirmDelete = _CONFIRM_DELETE_SCENE.instantiate()
	# Mostramos un trozo del contenido para que el usuario vea qué va a borrar.
	var preview: String = (array[idx] as IStringContainer).content
	if preview.length() > 80:
		preview = preview.substr(0, 77) + "..."
	w.message = "Delete string %d of entry \"%s\"?\n\n\"%s\"\n\nThis cannot be undone after saving." % [idx + 1, entry_local_name, preview]
	w.confirmed.connect(func() -> void:
		_perform_delete_string(entry_local_name, idx)
	)
	add_child(w)

# Borra una entry entera (todas sus strings). Limpia las estructuras globales
# (string_table, string_ids, string_sstr...) que apuntan a las strings borradas.
func _perform_delete_entry(entry_local_name: String) -> void:
	if not Handle.strings.has(entry_local_name):
		return
	var doomed_arr: Array = Handle.strings[entry_local_name]
	var doomed_ids := []
	for string_container: IStringContainer in doomed_arr:
		doomed_ids.append(string_container.id)

	# Quitar de todas las estructuras globales.
	for id: int in doomed_ids:
		Handle.string_table.erase(id)
		Handle.string_ids.erase(id)
	_purge_ids_from_similar(doomed_ids)
	Handle.strings.erase(entry_local_name)
	Handle.entry_names.erase(entry_local_name)
	Handle.string_size = max(0, Handle.string_size - doomed_ids.size())

	# Quitar el item del dialogue_selector (sólo el que coincida en nombre real).
	for i in range(dialogue_selector.get_item_count()):
		if dialogue_selector_entry_at(i) == entry_local_name:
			dialogue_selector.remove_item(i)
			break

	# Si la entry borrada era la que estaba cargada en el editor, limpiamos
	# el panel de la derecha (string_selector + editor) y reseteamos la
	# fuente de verdad. El siguiente item del dialogue_selector (si existe)
	# se selecciona como conveniencia y `_on_item_list_item_selected` →
	# `change_to` reasignará current_entry/current_string_index.
	var was_current := (entry_local_name == current_entry)
	if was_current:
		_set_loaded("", -1)
	string_selector.clear()
	similar_entries.clear()
	_set_dialogue_edit_text_silent("")
	original_dialogue.text = ""
	Handle.original_string = ""
	if dialogue_selector.get_item_count() > 0:
		var next: int = 0
		dialogue_selector.select(next)
		dialogue_selector.ensure_current_is_visible()
		_on_item_list_item_selected(next)

	Handle.is_modified = true
	update_progress_stats_label()

# Borra una string concreta dentro de una entry. Re-asigna `index` a las
# strings posteriores en string_table (cada IStringTable guarda su posición
# dentro de la entry, y borrar al medio desplaza las que vienen después).
func _perform_delete_string(entry_local_name: String, idx: int) -> void:
	if not Handle.strings.has(entry_local_name):
		return
	var array: Array = Handle.strings[entry_local_name]
	if idx < 0 or idx >= array.size():
		return
	var doomed: IStringContainer = array[idx]
	var doomed_id: int = doomed.id

	array.remove_at(idx)
	Handle.string_table.erase(doomed_id)
	Handle.string_ids.erase(doomed_id)
	_purge_ids_from_similar([doomed_id])
	Handle.string_size = max(0, Handle.string_size - 1)

	# Las strings que estaban después en la misma entry tienen ahora un index
	# menor. Hay que actualizar string_table para que sigan apuntando a la
	# posición correcta dentro de la entry.
	for i in range(idx, array.size()):
		var later: IStringContainer = array[i]
		if Handle.string_table.has(later.id):
			(Handle.string_table[later.id] as IStringTable).index = i

	# Refrescar el string_selector mostrando lo que queda. Sólo tiene sentido
	# si la entry borrada es la cargada en el editor — string_selector siempre
	# refleja current_entry. (Hoy delete_string_flow usa current_entry, así
	# que esta condición siempre se cumple; la dejamos defensiva por si
	# futuros flujos llaman a _perform_delete_string sobre otra entry.)
	if entry_local_name == current_entry:
		string_selector.clear()
		for string_container: IStringContainer in array:
			string_selector.add_item(_string_progress_prefix(string_container) + string_container.content)

	# Reseleccionar algo razonable: la siguiente string en la misma posición,
	# o la última si borramos la última.
	# Bug fix (decoupling): si la entry afectada es la cargada en el editor,
	# actualizamos current_string_index. Si el array quedó vacío, lo dejamos
	# en -1 explícitamente; `_on_item_list_item_selected_str` no se llamaría
	# (lista vacía) y current_string_index quedaría obsoleto.
	if array.is_empty():
		# Editor/similar_entries sólo se tocan si la entry borrada es la cargada.
		if entry_local_name == current_entry:
			similar_entries.clear()
			_set_dialogue_edit_text_silent("")
			original_dialogue.text = ""
			Handle.original_string = ""
			_set_loaded(current_entry, -1)
	else:
		if entry_local_name == current_entry:
			var new_idx: int = min(idx, array.size() - 1)
			string_selector.select(new_idx)
			string_selector.ensure_current_is_visible()
			# _on_item_list_item_selected_str actualiza current_string_index.
			_on_item_list_item_selected_str(new_idx)

	# La entry pudo cambiar de "✓" a "·" (si la borrada era la única no
	# traducida) o de "·" a "∅" si era la última string de la entry.
	refresh_entry_item_prefix(entry_local_name)
	Handle.is_modified = true
	update_progress_stats_label()

# Helper interno: cuando borramos strings, hay que sacar sus IDs de las
# listas `equal_strings` que comparten varias strings entre sí, y de los
# diccionarios que las indexan.
func _purge_ids_from_similar(ids_to_remove: Array) -> void:
	if ids_to_remove.is_empty():
		return
	var id_set := {}
	for id: Variant in ids_to_remove:
		id_set[id] = true
	# Quitar de equal_strings de cada string que sigue viva. Cada array es
	# compartido por todas las strings del grupo, así que basta con limpiar
	# una vez por grupo (lo hacemos al recorrer string_sstr_arr abajo).
	for array: Array in Handle.string_sstr_arr:
		var i := array.size() - 1
		while i >= 0:
			if id_set.has(array[i]):
				array.remove_at(i)
			i -= 1
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
		var f := FileAccess.open("user://scale.txt", FileAccess.WRITE)
		if f == null:
			push_warning("Could not persist scale to user://scale.txt")
			return
		f.store_string(str(Handle.visual_scale))
		f.flush()
		f.close()
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

	var root := VBoxContainer.new()
	root.name = "Root"
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	reference_panel.add_child(root)

	var header := HBoxContainer.new()
	header.name = "Header"
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(header)

	var title := Label.new()
	title.text = "Reference"
	title.tooltip_text = "Shows notes and draft Spanish references from a local CSV export."
	header.add_child(title)

	reference_status_label = Label.new()
	reference_status_label.text = "No CSV"
	reference_status_label.clip_text = true
	reference_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	reference_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reference_status_label.custom_minimum_size = Vector2(80.0, 0.0)
	header.add_child(reference_status_label)

	reference_toggle_button = Button.new()
	reference_toggle_button.text = "▴"
	reference_toggle_button.tooltip_text = "Hide reference panel"
	reference_toggle_button.focus_mode = Control.FOCUS_NONE
	reference_toggle_button.pressed.connect(_toggle_reference_panel_collapsed)
	header.add_child(reference_toggle_button)

	var load_button := Button.new()
	load_button.text = "Load"
	load_button.tooltip_text = "Load reference CSV..."
	load_button.focus_mode = Control.FOCUS_NONE
	load_button.pressed.connect(load_reference_csv_flow)
	header.add_child(load_button)

	var clear_button := Button.new()
	clear_button.text = "×"
	clear_button.tooltip_text = "Clear reference CSV"
	clear_button.focus_mode = Control.FOCUS_NONE
	clear_button.pressed.connect(clear_reference_csv)
	header.add_child(clear_button)

	reference_body = HBoxContainer.new()
	reference_body.name = "ReferenceBody"
	reference_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reference_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(reference_body)

	reference_notes_edit = _make_reference_column("Notas", "No notes for this string.", 1.25)
	reference_es_en_edit = _make_reference_column("ES ← EN", "No Spanish-from-English reference for this string.", 1.0)
	reference_es_jp_edit = _make_reference_column("ES ← JP", "No Spanish-from-Japanese reference for this string.", 1.0)

	_update_reference_panel_visibility()
	_update_reference_panel_layout()
	update_reference_panel()

func _make_reference_column(title: String, placeholder: String, ratio: float) -> TextEdit:
	var col := VBoxContainer.new()
	col.name = "ReferenceColumn%d" % reference_body.get_child_count()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = ratio
	reference_body.add_child(col)

	var label := Label.new()
	label.text = title
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.clip_text = true
	label.add_theme_font_size_override("font_size", _REFERENCE_PANEL_FONT_SIZE)
	col.add_child(label)

	var text_edit := _make_reference_text_edit(title, placeholder)
	col.add_child(text_edit)
	return text_edit

func _make_reference_text_edit(local_name: String, placeholder: String) -> TextEdit:
	var text_edit := TextEdit.new()
	text_edit.name = local_name
	text_edit.editable = false
	text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	text_edit.placeholder_text = placeholder
	text_edit.tooltip_text = "Reference only. This does not get saved to the .txt."
	text_edit.add_theme_font_size_override("font_size", _REFERENCE_PANEL_FONT_SIZE)
	text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return text_edit

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
	var h: float = _REFERENCE_PANEL_COLLAPSED_H if reference_panel_collapsed else _REFERENCE_PANEL_EXPANDED_H
	var button_top: float = minf(add_entry.position.y, add_string.position.y)
	var controls_top: float = dialogue_edit.position.y + button_top - _REFERENCE_PANEL_MARGIN
	var right_limit: float = float(tree.root.size.x) - (1100.0 - 879.0) - _REFERENCE_PANEL_MARGIN
	var w: float = minf(dialogue_edit.size.x, maxf(260.0, right_limit - dialogue_edit.position.x))
	reference_panel.position = Vector2(dialogue_edit.position.x, controls_top - h)
	reference_panel.size = Vector2(w, h)

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
	_reference_fd_window.file_selected.connect(func(path: String) -> void:
		_load_reference_csv(path)
		_close_reference_fd_window_deferred()
	)
	_reference_fd_window.close_requested.connect(_close_reference_fd_window_deferred)
	_reference_fd_window.canceled.connect(_close_reference_fd_window_deferred)
	add_child(_reference_fd_window)
	_reference_fd_window.show()

func _close_reference_fd_window_deferred() -> void:
	var w: FileDialog = _reference_fd_window
	_reference_fd_window = null
	if not is_instance_valid(w):
		return
	var tween := create_tween()
	tween.tween_callback(func() -> void:
		if is_instance_valid(w):
			w.queue_free()
	).set_delay(1.0 / 60.0)
	tween.play()

func _load_reference_csv(path: String) -> void:
	# Reference CSVs are intentionally session/file scoped. They are useful while
	# working on one file, but should not be restored automatically after closing
	# the program or switching to another .txt.
	if reference_table.load_from_csv(path):
		update_reference_panel()
	else:
		_show_reference_csv_error(reference_table.last_error)
		update_reference_panel()

func clear_reference_csv() -> void:
	reference_table.clear()
	update_reference_panel()

func _show_reference_csv_error(msg: String) -> void:
	var w := Handle.style_error_scene.instantiate() as Window
	w.title = "Reference CSV error"
	(w.get_node(^"TextEdit") as TextEdit).text = msg
	add_child(w)

func update_reference_panel() -> void:
	if reference_panel == null:
		return
	if reference_table.source_path == "":
		reference_status_label.text = "No CSV"
		reference_panel.tooltip_text = "No reference CSV loaded."
		_set_reference_texts("", "", "")
		return
	var clave := _get_current_clave()
	if clave == "":
		reference_status_label.text = "%d refs · no Clave" % reference_table.loaded_count()
		reference_panel.tooltip_text = "Reference CSV loaded, but the current string has no Clave."
		_set_reference_texts("", "", "")
		return
	var ref := reference_table.get_reference(clave)
	if ref.is_empty():
		reference_status_label.text = "%d refs · no match" % reference_table.loaded_count()
		_set_reference_texts("", "", "")
		reference_panel.tooltip_text = "No reference found for Clave:\n%s" % clave
		return
	reference_status_label.text = "Match"
	reference_panel.tooltip_text = "Reference found for Clave:\n%s\n\nCSV:\n%s" % [clave, reference_table.source_path]
	_set_reference_texts(
		str(ref.get(ReferenceTable.FIELD_NOTES, "")),
		str(ref.get(ReferenceTable.FIELD_ES_FROM_EN, "")),
		str(ref.get(ReferenceTable.FIELD_ES_FROM_JP, ""))
	)

func _set_reference_texts(notes: String, es_en: String, es_jp: String) -> void:
	_set_reference_column_text(reference_notes_edit, notes)
	_set_reference_column_text(reference_es_en_edit, es_en)
	_set_reference_column_text(reference_es_jp_edit, es_jp)

func _set_reference_column_text(edit: TextEdit, text: String) -> void:
	if edit == null:
		return
	var clean_text: String = text.strip_edges()
	edit.text = clean_text
	var column: Control = edit.get_parent() as Control
	if column != null:
		# Empty reference fields should not reserve space. If a row has no notes,
		# for example, the two draft columns can use the whole panel width.
		column.visible = clean_text != ""

# ID lejos del rango de IDs internos de TextEdit (Cut/Copy/Paste van por debajo de 30).
const _MENU_ID_COPY_CLAVE := 1000

func _setup_textedit_clave_menu(text_edit: TextEdit) -> void:
	var menu: PopupMenu = text_edit.get_menu()
	menu.add_separator()
	menu.add_item("Copy Clave name", _MENU_ID_COPY_CLAVE)
	menu.id_pressed.connect(_on_textedit_menu_id_pressed)
	# Habilitar / deshabilitar el ítem según haya o no Clave en la string activa.
	menu.about_to_popup.connect(func() -> void:
		var item_index := menu.get_item_index(_MENU_ID_COPY_CLAVE)
		if item_index == -1:
			return
		menu.set_item_disabled(item_index, _get_current_clave() == "")
	)

func _get_current_clave() -> String:
	# Bug fix (decoupling): pasamos por la fuente de verdad.
	var string_container := _get_current_string_container()
	if string_container == null:
		return ""
	return string_container.key

# Helper para mantener el invariante de "qué está cargado en el editor".
# change_to y _on_item_list_item_selected_str son los dos call sites
# canónicos donde el editor cambia de string; cualquier flujo nuevo que
# cargue algo debería pasar también por aquí. Así nadie puede olvidar
# actualizar las dos variables a la vez y reintroducir el bug del
# decoupling.
func _set_loaded(entry: String, idx: int) -> void:
	current_entry = entry
	current_string_index = idx
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
func _parse_entry_ref(text: String) -> Array:
	var parts := text.rsplit(":", true, 1)
	if parts.size() == 2 and (parts[1] as String).is_valid_int():
		return [parts[0], int(parts[1])]
	return [text, 1]

func _on_textedit_menu_id_pressed(id: int) -> void:
	if id == _MENU_ID_COPY_CLAVE:
		var clave := _get_current_clave()
		if clave != "":
			DisplayServer.clipboard_set(clave)

func update_box(i: int, user_change: bool = true) -> void:
	if i >= Handle.box_data.size():
		return
	current_box = i
	current_box_label.text = Handle.box_data[i].name
	current_box_node.value = i + 1
	box.current_box = i
	if user_change:
		Handle.is_modified = true

func update_font(i: int, user_change: bool = true) -> void:
	if i >= Handle.font_data.size():
		return
	current_font_id = i
	Handle.current_font = i
	current_font_label.text = Handle.font_data[i].name
	current_font_node.value = i + 1
	font = IFont.get_font(Handle.current_font)
	if user_change:
		Handle.is_modified = true
		box.handle.force_update = true

# Devuelve true si el IStringContainer contiene etiquetas de retrato (\E, \F, \P, ...)
func _string_has_portrait_tags(string_container: IStringContainer) -> bool:
	if string_container == null:
		return false
	var portrait_tags: Array[String] = ["\\E", "\\F", "\\P"]
	# original_content y layer_strings están tipados (String y Array[String]),
	# así que no pueden ser null — sólo string/array vacíos. No tiene sentido
	# chequear null aquí.
	if not string_container.original_content.is_empty():
		for tag in portrait_tags:
			if string_container.original_content.find(tag) != -1:
				return true
	for layer in string_container.layer_strings:
		if typeof(layer) == TYPE_STRING:
			for tag in portrait_tags:
				if (layer as String).find(tag) != -1:
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

func _compute_auto_box(string_container: IStringContainer) -> int:
	if string_container == null:
		return _AUTO_BOX_WITH_ASTERISK
	# Salvaguarda: si el style cargado todavía no tiene Box7 (p. ej. el
	# usuario abrió Deltarune sin haber añadido aún la Box7 prometida),
	# caemos a Box1 para no fijar un índice fuera de rango. update_box ya
	# hace bound-check, pero aquí lo evitamos antes para que el SpinBox
	# tampoco muestre un número que no se puede pintar.
	if Handle.box_data.size() <= _AUTO_BOX_WITHOUT_ASTERISK:
		return _AUTO_BOX_WITH_ASTERISK
	if string_container.original_content.find("*") != -1:
		return _AUTO_BOX_WITH_ASTERISK
	if string_container.content.find("*") != -1:
		return _AUTO_BOX_WITH_ASTERISK
	return _AUTO_BOX_WITHOUT_ASTERISK

# Devuelve la caja que se debe MOSTRAR para una string. Si el usuario ha
# escogido explícitamente algo distinto del valor por defecto (box_style != 0),
# se respeta su elección. Si no, se aplica la regla del asterisco.
func _resolve_box_style(string_container: IStringContainer) -> int:
	if string_container == null:
		return 0
	if string_container.box_style != 0:
		return string_container.box_style
	return _compute_auto_box(string_container)

func _on_item_list_item_selected(index: int) -> void:
	var item := dialogue_selector_entry_at(index)
	change_to(item)
	if Handle.strings.has(item):
		var it: Array = Handle.strings[item]
		for string_container: IStringContainer in it:
			# Prefijo de progreso (Bloque 1): "✓ " si está traducida, "· " si no.
			string_selector.add_item(_string_progress_prefix(string_container) + string_container.content)
		if !it.is_empty():
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

func _on_item_list_item_selected_str(index: int) -> void:
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
	var array: Array = Handle.strings[current_entry]
	if index < 0 or index >= array.size():
		return
	_set_loaded(current_entry, index)
	current_layer = 0
	current_layer_node.value = 1
	similar_entries.clear()
	var string_container: IStringContainer = array[index]
	# Asignamos las cadenas de capas primero
	Handle.layer_strings = string_container.layer_strings

	# Reiniciar por defecto la casilla "Portrait" al cambiar de línea (condicional para evitar parpadeos)
	var new_has_portrait := _string_has_portrait_tags(string_container)
	if not (prev_has_portrait and new_has_portrait):
		if box:
			box.portrait_enabled = false
		if enable_portrait:
			enable_portrait.button_pressed = false
	prev_has_portrait = new_has_portrait

	if box and box.handle:
		if str(string_container.speaker) != "":
			box.handle.global_env["speaker"] = str(string_container.speaker)
		else:
			if box.handle.global_env.has("speaker"):
				box.handle.global_env.erase("speaker")
	Handle.layer_colors = string_container.layer_colors
	Handle.original_string = string_container.original_content
	var tween := create_tween()
	tween.tween_callback(func() -> void:
		current_font_node.set_value(string_container.font_style + 1)
		# Issue #3: en lugar de usar `_stri.box_style` directamente, pasamos
		# por _resolve_box_style. Si la string tiene caja explícita
		# (box_style != 0) se respeta; si no, aplicamos la regla del
		# asterisco (Box1 con `*`, Box7 sin `*`).
		current_box_node.set_value(_resolve_box_style(string_container) + 1)
	).set_delay(1.0 / 60.0)
	tween.play()
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
		similar_entries.clear.call_deferred()
		for sstri in string_container.equal_strings:
			if sstri != string_container.id:
				var r: IStringTable = Handle.string_table[sstri]
				similar_entries.add_item.call_deferred("%s:%s" % [r.name, r.index + 1])
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
		var it: Array = Handle.strings[item]
		if it.size() > index and index >= 0:
			_set_loaded(item, index)
			var string_container: IStringContainer = it[index]
			Handle.layer_strings = string_container.layer_strings

			# Reiniciar por defecto la casilla "Portrait" al cambiar de línea (condicional para evitar parpadeos)
			var new_has_portrait := _string_has_portrait_tags(string_container)
			if not (prev_has_portrait and new_has_portrait):
				if box:
					box.portrait_enabled = false
				if enable_portrait:
					enable_portrait.button_pressed = false
			prev_has_portrait = new_has_portrait

			if str(string_container.speaker) != "":
				box.handle.global_env["speaker"] = str(string_container.speaker)
			else:
				if box.handle.global_env.has("speaker"):
					box.handle.global_env.erase("speaker")
			Handle.layer_colors = string_container.layer_colors
			Handle.original_string = string_container.original_content
			var tween := create_tween()
			tween.tween_callback(func() -> void:
				current_font_node.set_value(string_container.font_style + 1)
				# Issue #3: ver _on_item_list_item_selected_str para la
				# explicación. Mismo razonamiento aquí.
				current_box_node.set_value(_resolve_box_style(string_container) + 1)
			).set_delay(1.0 / 60.0)
			tween.play()
			current_color_node.color = Handle.layer_colors[current_layer]
			_set_dialogue_edit_text_silent(str(Handle.layer_strings[current_layer]))
			dialogue_edit.clear_undo_history()
			if last_sthread is Thread:
				last_sthread.wait_to_finish()
			last_sthread = Thread.new()
			last_sthread.start(func() -> void:
				similar_entries.clear.call_deferred()
				for sstri in string_container.equal_strings: # String ID
					if sstri != string_container.id:
						var r: IStringTable = Handle.string_table[sstri]
						similar_entries.add_item.call_deferred( "%s:%s" % [r.name, r.index + 1])
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
				similar_entries.clear.call_deferred()
			)

func _on_item_list_item_selected_similar(index: int) -> void:
	# Bug fix: parseo "local_name:N" robusto a `:` en el nombre (ver _parse_entry_ref).
	var ref: Array = _parse_entry_ref(similar_entries.get_item_text(index))
	var item_local_name: String = ref[0]
	if Handle.strings.has(item_local_name):
		var idx := (ref[1] as int) - 1
		change_to(item_local_name, idx)
		similar_entries.deselect_all()
		similar_entries.get_v_scroll_bar().value = 0
		if last_sthread is Thread:
			last_sthread.wait_to_finish()
		last_sthread = Thread.new()
		last_sthread.start(func() -> void:
			similar_entries.clear.call_deferred()
			var src: IStringContainer = Handle.strings[item_local_name][idx]
			for sstri: int in src.equal_strings: # String ID
				if sstri != src.id:
					var r: IStringTable = Handle.string_table[sstri]
					similar_entries.add_item.call_deferred( "%s:%s" % [r.name, r.index + 1])
		)
		string_selector.clear()
		for string_container: IStringContainer in Handle.strings[item_local_name]:
			string_selector.add_item(_string_progress_prefix(string_container) + str(string_container.layer_strings[0]))
		string_selector.select(idx)
		string_selector.ensure_current_is_visible()
		for i in range(dialogue_selector.get_item_count()):
			if dialogue_selector_entry_at(i) == item_local_name:
				dialogue_selector.select(i)
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
	var arr_curr: Array = Handle.strings[current_entry]
	if current_string_index >= arr_curr.size():
		return
	var c := current_entry
	var ss_idx := current_string_index
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
	var entries_to_refresh: Dictionary = {}
	var stats_count_changed: bool = false
	if current_layer == 0:
		# Bug fix: equal_strings YA contiene el ID propio (se construye así
		# en IFileHandler.load_file y en AddString). Antes hacíamos
		# `.duplicate() ... .append(id_propio)` directamente, lo que metía
		# el propio ID dos veces y el bucle de actualización procesaba la
		# string actual dos pasadas idénticas. Idempotente, pero trabajo
		# doble por cada tecla pulsada cuando replace_similar está activo.
		var own_id: int = (arr_curr[ss_idx] as IStringContainer).id
		var equal_strings: Array = ((arr_curr[ss_idx] as IStringContainer).equal_strings as Array).duplicate() if replace_similar.button_pressed else []
		if not equal_strings.has(own_id):
			equal_strings.append(own_id)
		var entry_table := {}
		var i := 0
		for string_container: IStringContainer in arr_curr:
			entry_table[string_container.id] = i
			i += 1
		Handle.is_modified = true
		for f: int in equal_strings: # Update all strings first (before making the entry table), then change the visualization.
			var table: IStringTable = Handle.string_table[f]
			var entr: IStringContainer = Handle.strings[table.name][table.index]
			var was_translated := Handle.is_string_translated(entr)
			entr.last_edited.author = author
			entr.last_edited.timestamp = int(Time.get_unix_time_from_system())
			entr.content = dialogue_edit.text
			entr.layer_strings[0] = entr.content
			Handle.string_ids[entr.id] = entr.content # We need to update properly the String ID Dictionary
			if entry_table.has(entr.id):
				if entry_table[entr.id] == table.index:
					# El item del string_selector también lleva el prefijo de progreso.
					# Solo lo actualizamos si la entry de _entr coincide con la
					# entry cargada — string_selector muestra current_entry.
					if table.name == c:
						string_selector.set_item_text(table.index, _string_progress_prefix(entr) + dialogue_edit.text)
			# SIEMPRE marcamos la entry para refresh: el content cambió, lo
			# que puede haber alterado el tag mismatch (⚠) aunque la string
			# siguiera marcada como traducida.
			entries_to_refresh[table.name] = true
			if not was_translated:
				stats_count_changed = true
	else:
		Handle.is_modified = true
		var f: IStringTable = Handle.string_table[(arr_curr[ss_idx] as IStringContainer).id]
		var entry: IStringContainer = Handle.strings[f.name][f.index]
		var was_translated := Handle.is_string_translated(entry)
		entry.last_edited.author = author
		entry.last_edited.timestamp = int(Time.get_unix_time_from_system())
		entry.layer_strings[current_layer] = dialogue_edit.text
		# Mismo criterio que en la rama de arriba: refresh de prefijo
		# siempre, stats solo si cambió el conteo de traducidas.
		entries_to_refresh[f.name] = true
		if not was_translated:
			stats_count_changed = true
		# El string_selector muestra layer_strings[0]; al editar layer != 0
		# no hace falta cambiar el texto del item, pero sí su prefijo. Solo
		# si la string editada vive en la entry actualmente cargada.
		if f.name == c:
			refresh_string_item_prefix(f.index, entry)

	# Refresco de UI. Coalescemos las partes caras en el Timer del debounce
	# (refresh_entry_item_prefix corre regex por cada string traducida; con
	# replace_similar y muchas equal_strings se notaba al teclear). Los datos
	# ya están escritos arriba, así que un save inmediato encuentra los
	# valores correctos; lo único que tarda hasta _EDIT_REFRESH_DEBOUNCE_S
	# en aplicarse es el repintado de prefijos y stats globales.
	for entry: String in entries_to_refresh.keys():
		_entries_to_refresh_pending[entry] = true
	if stats_count_changed:
		_stats_count_changed_pending = true
	if _edit_refresh_timer != null:
		_edit_refresh_timer.start()

	# Validador SÍ síncrono: es una sola regex y da feedback en vivo sobre
	# la string que el usuario está editando ahora mismo.
	update_tag_validator_label()
	update_closed_sign_validator_label()

# QoL: ahora delega a las funciones-flujo. Cada ID del menú mapea a una acción.
func file_menu_selected(id: int) -> void:
	match id:
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

	for i in range(Handle.layer_colors.size()):
		Handle.layer_colors[i] = Color.WHITE
	for i in range(Handle.layer_strings.size()):
		Handle.layer_strings[i] = ""
	Handle.original_string = ""
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

func about_menu_selected(id: int) -> void:
	match id:
		0: # Show String Info
			Handle.show_info_window = Handle.show_info_scene.instantiate()
			add_child(Handle.show_info_window)
			Handle.show_info_window.close_requested.connect(func() -> void:
				Handle.show_info_window.queue_free()
			)
			var n: Label = Handle.show_info_window.get_node("Label")
			var n2: Label = Handle.show_info_window.get_node("Label2")
			var l: LineEdit = Handle.show_info_window.get_node("LineEdit")
			var l2: TextEdit = Handle.show_info_window.get_node("LineEdit2")
			# Bug fix (decoupling): leemos de current_entry/current_string_index
			# (la string realmente cargada en el editor) en lugar de la
			# selección de las ItemList, que pueden estar desincronizadas.
			var stri_info := _get_current_string_container()
			if stri_info != null:
				var elocal_name := current_entry
				var eindex := current_string_index
				var laste := stri_info.last_edited
				var td := Time.get_datetime_dict_from_unix_time(laste.timestamp + int((Time.get_time_zone_from_system().bias as int) * 60)) # Local timezone?
				if laste.author == "" || laste.timestamp == -1:
					n2.text = "\n\n\nNo last edit was made."
				else:
					n2.text = n2.text \
						.replace("AUTHOR_NAME", laste.author) \
						.replace("TIMESTAMP", "{DAY}/{MONTH}/{YEAR} {HOUR}:{MINUTE}:{SECOND} {HFORMAT}".format({
								"DAY": str(td["day"]).pad_zeros(2),
								"MONTH": str(td["month"]).pad_zeros(2),
								"YEAR": str(td["year"]).pad_zeros(4),
								"HOUR": str(12 if td["hour"] == 0 else td["hour"] if td["hour"] < 13 else td["hour"] - 12).pad_zeros(2),
								"MINUTE": str(td["minute"]).pad_zeros(2),
								"SECOND": str(td["second"]).pad_zeros(2),
								"HFORMAT": "a.m." if td["hour"] < 12 else "p.m",
							}))
				l.text = "%s:%s" % [elocal_name, eindex + 1]
				l2.text = stri_info.original_content
			else:
				n.text = "But Nobody Came." if randi() % 50 == 0 else "But there was nothing to see."
				n2.hide()
				l.hide()
				l2.hide()
		1: # Set Author Details
			Handle.author_window = Handle.author_scene.instantiate()
			add_child(Handle.author_window)
			(Handle.author_window.get_node("Label/LineEdit") as LineEdit).text = author
		3: # About DH...
			Handle.about_window = Handle.about_scene.instantiate()
			add_child(Handle.about_window)

func open_search_menu() -> void:
	Handle.search_window = Handle.search_scene.instantiate()
	add_child(Handle.search_window)

func open_go_to_menu() -> void:
	Handle.goto_window = Handle.goto_scene.instantiate()
	add_child(Handle.goto_window)
	(Handle.goto_window.get_node("GoTo/GoButton") as Button).pressed.connect(func() -> void:
		var text := (Handle.goto_window.get_node("GoTo/Str") as LineEdit).text
		if text.length() > 0:
			# Bug fix: parseo "local_name:N" robusto a `:` en el nombre (ver _parse_entry_ref).
			var ref: Array = _parse_entry_ref(text)
			var item_local_name: String = ref[0]
			var idx_zero: int = (ref[1] as int) - 1
			if Handle.strings.has(item_local_name):
				change_to(item_local_name, idx_zero)
				string_selector.clear()
				for string_container: IStringContainer in Handle.strings[item_local_name]:
					string_selector.add_item(_string_progress_prefix(string_container) + str(string_container.layer_strings[0]))
				string_selector.select(idx_zero)
				string_selector.ensure_current_is_visible()
				for i in range(dialogue_selector.get_item_count()):
					if dialogue_selector_entry_at(i) == item_local_name:
						dialogue_selector.select(i)
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
	for entry: String in _entries_to_refresh_pending.keys():
		refresh_entry_item_prefix(entry)
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
	var filter_id: int = 0
	if has_node("EntryFilter"):
		filter_id = ($EntryFilter as OptionButton).get_selected_id()
	var search_text: String = ""
	if has_node("EntrySearch"):
		search_text = ($EntrySearch as LineEdit).text.to_lower()

	# Bloque 2 perf: en archivos grandes, recorrer dos veces las strings de
	# cada entry (una para _entry_passes_filter, otra para _entry_progress_prefix)
	# se notaba al cambiar filtro. Ahora calculamos un "estado agregado" en
	# una sola pasada por entry y lo usamos para ambas decisiones.
	dialogue_selector.clear()
	for entry_name: String in Handle.entry_names:
		if search_text != "" and not entry_name.to_lower().contains(search_text):
			continue
		var state := _compute_entry_state(entry_name)
		if not _state_passes_filter(state, filter_id):
			continue
		dialogue_selector.add_item(_state_to_prefix(state) + entry_name)

	# Cortesía visual: si la entry cargada pasa el filtro, marcarla como
	# seleccionada en la lista. Si no pasa, no se selecciona nada — pero el
	# editor sigue editando current_entry normalmente.
	if current_entry != "":
		for i in range(dialogue_selector.get_item_count()):
			if dialogue_selector_entry_at(i) == current_entry:
				dialogue_selector.select(i)
				dialogue_selector.ensure_current_is_visible()
				break

# Estado agregado de una entry. Calculado en una sola pasada para que filtro
# y prefijo se compartan (perf en archivos grandes). Devuelve un Dictionary
# con flags booleanos.
func _compute_entry_state(entry_local_name: String) -> Dictionary:
	var state := {
		"empty": true,
		"all_translated": true,
		"any_untranslated": false,
		"any_review": false,
		"any_mismatch": false,
		"any_misclosed_sign": false,
	}
	if not Handle.strings.has(entry_local_name):
		return state
	var array: Array = Handle.strings[entry_local_name]
	if array.is_empty():
		return state
	state["empty"] = false
	for string_container: IStringContainer in array:
		if not Handle.is_string_translated(string_container):
			state["all_translated"] = false
			state["any_untranslated"] = true
		if string_container.needs_review:
			state["any_review"] = true
		# Validamos aunque no haya LastEdited. Algunos archivos pueden traer
		# Content ya distinto/problemas de tags sin metadatos de edición; si
		# aquí se saltan, la entry no muestra ⚠ hasta que el usuario toca el
		# texto y se crea LastEdited. Las regex están cacheadas en ITagValidator.
		var diff := ITagValidator.validate_string(string_container)
		var diff_sign := IClosedSignValidator.validate_string(string_container)
		if not diff.ok:
			state["any_mismatch"] = true
		if not diff_sign.ok:
			state["any_misclosed_sign"] = true
	return state

func _state_passes_filter(state: Dictionary, filter_id: int) -> bool:
	# Castear los flags como `as bool` (no `bool(...)`): Dictionary devuelve
	# Variant y bool() acepta Variant pero el analyzer estricto se queja.
	# `as bool` es la forma idiomática y silencia UNSAFE_CALL_ARGUMENT.
	match filter_id:
		0: return true
		1: return (state["empty"] as bool) or (state["any_untranslated"] as bool)
		2: return not (state["empty"] as bool) and (state["all_translated"] as bool)
		3: return state["any_review"] as bool
		4: return state["any_mismatch"] as bool
		5: return state["any_misclosed_sign"] as bool
	return true

func _state_to_prefix(state: Dictionary) -> String:
	# Prioridad: tag_mismatch > review > empty > done > todo. Tag mismatch es
	# un problema técnico real (rompe el juego), tiene precedencia sobre la
	# marca manual de "necesita revisión". Si la entry está marcada por el
	# usuario y además tiene mismatch, mostramos el ⚠ porque es lo más
	# urgente; el ★ vuelve a aparecer en cuanto se arregle el mismatch.
	if state["any_mismatch"] as bool:
		return _PROGRESS_PREFIX_WARN
	if state["any_review"] as bool:
		return _PROGRESS_PREFIX_REVIEW
	if state["any_misclosed_sign"] as bool:
		return _PROGRESS_PREFIX_UNCLOSED_SIGN
	if state["empty"] as bool:
		return _PROGRESS_PREFIX_EMPTY
	if state["all_translated"] as bool:
		return _PROGRESS_PREFIX_DONE
	return _PROGRESS_PREFIX_TODO

func _on_reload_style_pressed() -> void:
	Handle.load_style()
	Handle.main_node.box.handle.force_update = true

func _on_add_entry_pressed() -> void:
	Handle.add_entry_window = Handle.add_entry_scene.instantiate()
	add_child(Handle.add_entry_window)

func _on_add_string_pressed() -> void:
	# Bug fix (decoupling): añadimos a la entry cargada en el editor, no a la
	# que esté marcada en dialogue_selector (puede estar desincronizada con un
	# filtro o vacía).
	if current_entry == "" or not Handle.strings.has(current_entry):
		return
	Handle.add_string_window = Handle.add_string_scene.instantiate()
	Handle.add_string_window.entry = current_entry
	# Si hay una string cargada, la pasamos como fuente para el modo "duplicar".
	# Si no hay (entry vacía o nada cargado), el diálogo caerá en modo "blanco".
	if current_string_index >= 0:
		var array: Array = Handle.strings[current_entry]
		if current_string_index < array.size():
			Handle.add_string_window.source_index = current_string_index
			Handle.add_string_window.source_container = array[current_string_index]
	add_child(Handle.add_string_window)
