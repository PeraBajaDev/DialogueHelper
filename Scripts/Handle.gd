extends Node

var loading_scene := preload("res://Subwindows/ProgressBars/Loading.tscn")
var saving_scene := preload("res://Subwindows/ProgressBars/Saving.tscn")
var load_file_scene := preload("res://Subwindows/FileAction/LoadFile.tscn")
var show_info_scene := preload("res://Subwindows/ShowInfo.tscn")
var author_scene := preload("res://Subwindows/AuthorInfo.tscn")
var settings_scene := preload("res://Subwindows/Settings.tscn")
var save_file_scene := preload("res://Subwindows/FileAction/SaveFile.tscn")
var goto_scene := preload("res://Subwindows/GoTo.tscn")
var search_scene := preload("res://Subwindows/Search.tscn")
var git_conflict_scene := preload("res://Subwindows/GitConflict.tscn")
var git_conflict_unreplaced_scene := preload("res://Subwindows/GitConflictUnreplaced.tscn")
var style_error_scene := preload("res://Subwindows/StyleError.tscn")
var loading_style_scene := preload("res://Subwindows/ProgressBars/LoadingStyle.tscn")
var unsaved_changes_scene := preload("res://Subwindows/UnsavedChanges.tscn")
var about_scene := preload("res://Subwindows/AboutDh.tscn")
var add_entry_scene := preload("res://Subwindows/AddEntry.tscn")
var add_string_scene := preload("res://Subwindows/AddString.tscn")

var loading_window: WLoading = null
var saving_window: WLoading = null
var file_dialog_window: FileDialog = null
var show_info_window: Window = null
var author_window: Node = null
var settings_window: Node = null
var save_file_window: FileDialog = null
var goto_window: Node = null
var search_window: Node = null
var git_conflict_window: WGitConflict = null
var git_conflict_unreplaced_window: Node = null
var style_error_window: Node = null
var load_style_window: Node = null
var unsaved_changes_window: WUnsavedChanges = null
var about_window: Node = null
var add_entry_window: Node = null
var add_string_window: WAddString = null

var style := "Template"

var font_metadata := {}
var box_metadata := {}
var style_metadata := {}
var font_data := []
var box_data := []
var user_script := GDScript.new()
var user_script_obj: RefCounted = null

var visual_scale := 1.0
var current_font := 0
var layers := 5
var layer_strings := []
var layer_colors := []
var original_string := ""

var strings := {}
var string_table := {}
var string_ids := {}
var string_sstr := {}

var string_sstr_arr: Array[Array] = []
var entry_names := []
var last_string_id := 0
var string_size := 0
# Bloque 3: is_modified con setter para que MainNode pueda reaccionar a
# cambios sin tener que hacer polling. La señal se emite SÓLO cuando el
# valor cambia (de false a true o viceversa), no en cada asignación.
# - true: el usuario tocó algo desde el último save real → arranca el
#   debounce del autosave.
# - false: se acaba de guardar correctamente → cancela el debounce y
#   borra el autosave huérfano.
# Toda la lógica del autosave vive en MainNode; Handle sólo emite.
signal is_modified_changed(value: bool)
var _is_modified: bool = false
var is_modified: bool:
	get: return _is_modified
	set(value):
		if _is_modified == value:
			return
		_is_modified = value
		is_modified_changed.emit(value)

# QoL: ruta del archivo actualmente abierto. "" = ningún archivo / sin guardar todavía.
# Se usa para que Ctrl+S no tenga que volver a pedir la ruta.
var current_file_path: String = ""

var git := IGit.new()
var main_node: WDialogueHelper = null

# Devuelve la lista de carpetas dentro de res://Styles/ que contienen un
# Metadata.json válido. Una carpeta sin Metadata.json no se considera Style.
# Usa la ruta globalizada para que también funcione en builds donde los
# Styles están al lado del .exe (no embebidos en el .pck).
func list_available_styles() -> PackedStringArray:
	var result := PackedStringArray()
	var styles_directories := ProjectSettings.globalize_path("res://Styles/")
	if not DirAccess.dir_exists_absolute(styles_directories):
		return result
	for directory in DirAccess.get_directories_at(styles_directories):
		if FileAccess.file_exists(style_get_path("Metadata.json", directory)):
			result.append(directory)
	return result

# Elige un Style por defecto razonable cuando el usuario no ha indicado uno
# o cuando el indicado ya no existe en disco. Preferencias en orden:
#   1) "Deltarune" — el caso más común de uso de la herramienta
#   2) "Template"  — el placeholder que viene en el repo
#   3) Primer Style alfabético disponible
# Devuelve "" si no hay ninguno.
func pick_default_style() -> String:
	var available := list_available_styles()
	if available.is_empty():
		return ""
	for preferred: String in [&"Deltarune", &"Template"]:
		if preferred in available:
			return preferred
	return available[0]

# Mensaje amigable cuando no hay ningún Style en disco. Reutiliza la ventana
# StyleError porque ya está cableada y queue_free al cerrar; no merece un
# .tscn aparte.
func _show_no_styles_message() -> void:
	style_error_window = style_error_scene.instantiate()
	var message := "No Styles were found.\n\n" \
		+ "To use Dialogue Helper, place at least one Style folder " \
		+ "(such as \"Deltarune\") inside the \"Styles\" directory next to " \
		+ "the executable.\n\n" \
		+ "Expected layout:\n" \
		+ "  Dialogue Helper.exe\n" \
		+ "  Styles/\n" \
		+ "    Deltarune/\n" \
		+ "      Metadata.json\n" \
		+ "      ...\n\n" \
		+ "You can download Styles from:\n" \
		+ "  https://github.com/ryi3r/DialogueHelper/\n\n" \
		+ "Close the app, add the Styles folder, and re-open."
	(style_error_window.get_node(^"TextEdit") as TextEdit).text = message
	add_child(style_error_window)

func load_style(new_style: Variant = null) -> void:
	if new_style is String:
		style = new_style
	font_metadata.clear()
	box_metadata.clear()
	style_metadata.clear()
	font_data.clear()
	box_data.clear()
	user_script_obj = null
	var logs := PackedStringArray()

	# Si el style pedido no existe en disco (primer arranque del .exe sin
	# preferencia guardada, o last_style.txt apunta a una carpeta borrada),
	# intentamos un fallback automático antes de mostrar pantalla de error.
	if not FileAccess.file_exists(style_get_path(&"Metadata.json")):
		var picked := pick_default_style()
		if picked == "":
			# Caso "no hay nada en disco": mensaje amigable con instrucciones.
			_show_no_styles_message()
			return
		if picked != style:
			# Solo `print`, no `logs.append`: el fallback es información, no
			# error, y los logs activan la ventana StyleError al final.
			print("Style \"%s\" was not found. Loading \"%s\" instead." % [style, picked])
		style = picked

	load_style_window = loading_style_scene.instantiate()
	add_child(load_style_window)
	var progress_bar: ProgressBar = load_style_window.get_node(^"ProgressBar")
	if FileAccess.file_exists(style_get_path(&"Metadata.json")):
		style_metadata = JSON.parse_string(FileAccess.get_file_as_string(style_get_path(&"Metadata.json")))
		if style_metadata == null:
			logs.append("%s had a JSON parsing error." % style_get_relative_path(&"Metadata.json"))
			style_metadata = {}
		elif style_metadata.has(&"Script"):
			# Bug fix: el bloque tenía 4 tabs en lugar de 3, lo que visualmente
			# lo metía dentro del `elif` siguiente. Funcionaba por accidente
			# porque GDScript dedent-tolera niveles incorrectos siempre que
			# sean consistentes, pero un cambio futuro lo rompería en silencio.
			user_script.source_code = FileAccess.get_file_as_string(style_get_path(str(style_metadata.Script)))
			var error := user_script.reload()
			if error != OK:
				logs.append("Script failed to compile with error %s." % error)
		if FileAccess.file_exists(style_get_path(&"Fonts/Metadata.json")):
			font_metadata = JSON.parse_string(FileAccess.get_file_as_string(style_get_path(&"Fonts/Metadata.json")))
			if font_metadata == null:
				logs.append("%s had a JSON parsing error." % style_get_relative_path(&"Metadata.json"))
			elif font_metadata.has(&"Fonts"):
				progress_bar.max_value += (font_metadata.Fonts as Array).size()
				for font: String in font_metadata.Fonts as Array:
					if FileAccess.file_exists(style_get_path("Fonts/%s.json" % font)):
						var font_json: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(style_get_path("Fonts/%s.json" % font)))
						if font_json == null:
							logs.append("%s had a JSON parsing error." % style_get_relative_path("Fonts/%s.json" % font))
						else:
							font_data.append(IFont.new(font_json))
						progress_bar.value += 1
					else:
						logs.append("%s does not exist." % style_get_relative_path("Fonts/%s.json" % font))
		else:
			logs.append("%s does not exist." % style_get_relative_path(&"Fonts/Metadata.json"))
		if FileAccess.file_exists(style_get_path(&"Boxes/Metadata.json")):
			box_metadata = JSON.parse_string(FileAccess.get_file_as_string(style_get_path(&"Boxes/Metadata.json")))
			if box_metadata == null:
				logs.append("%s had a JSON parsing error." % style_get_relative_path(&"Metadata.json"))
			elif box_metadata.has("Boxes"):
				progress_bar.max_value += (box_metadata.Boxes as Array).size()
				for box: String in box_metadata.Boxes as Array:
					if FileAccess.file_exists(style_get_path("Boxes/%s.json" % box)):
						var box_json: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(style_get_path("Boxes/%s.json" % box)))
						if box_json == null:
							logs.append("%s had a JSON parsing error." % style_get_relative_path("Boxes/%s.json" % box))
						else:
							box_data.append(IBox.new(box_json))
					else:
						logs.append("%s does not exist." % style_get_relative_path("Boxes/%s.json" % box))
					progress_bar.value += 1
		else:
			logs.append("%s does not exist." % style_get_relative_path(&"Boxes/Metadata.json"))
		progress_bar.value = progress_bar.max_value
	else:
		logs.append("Style Path \"%s\" was not found." % style_get_relative_path(&""))
	load_style_window.queue_free()
	if !logs.is_empty(): # An error ocurred.
		style_error_window = style_error_scene.instantiate()
		(style_error_window.get_node(^"TextEdit") as TextEdit).text = "\n".join(PackedStringArray(logs))
		add_child(style_error_window)

func style_get_path(path: String, style_file_name: String = style) -> String:
	return "res://Styles/%s/%s" % [style_file_name, path]

func style_get_relative_path(path: String, style_file_name: String = style) -> String:
	return "/%s/%s" % [style_file_name, path]

func handle_git_output(response: IGitResponse) -> void:
	if !response.success:
		var window := preload("res://Subwindows/GitError.tscn").instantiate()
		add_child(window)
		(window.get_node(^"TextEdit") as TextEdit).text = "".join(PackedStringArray(response.output))

# ---------------------------------------------------------------------------
# Helpers de progreso de traducción.
# Una string se considera "traducida" si tiene LastEdited (es decir, si algún
# autor la ha tocado al menos una vez). Es un criterio más fiable que comparar
# `content == original_content`, ya que puede haber casos legítimos donde la
# traducción coincida con el original (nombres propios, "OK", "NO"...).
# ---------------------------------------------------------------------------

func is_string_translated(string_container: IStringContainer) -> bool:
	if string_container == null:
		return false
	return string_container.last_edited.timestamp != -1

# Devuelve [traducidas, total] para una entry concreta.
func entry_translation_progress(entry_name: String) -> Array:
	if not strings.has(entry_name):
		return [0, 0]
	var array: Array = strings[entry_name]
	var done: int = 0
	for string_container: IStringContainer in array:
		if is_string_translated(string_container):
			done += 1
	return [done, array.size()]

# Devuelve [traducidas, total] global.
func global_translation_progress() -> Array:
	var done: int = 0
	var total: int = 0
	for entry_name: String in strings.keys():
		var array: Array = strings[entry_name]
		total += array.size()
		for string_container: IStringContainer in array:
			if is_string_translated(string_container):
				done += 1
	return [done, total]

# Una entry está completamente traducida si todas sus strings lo están y no
# está vacía (una entry sin strings no se cuenta como "completa", se cuenta
# como "vacía", para no engañar al ojo del traductor).
func is_entry_fully_translated(entry_name: String) -> bool:
	var progress_pair := entry_translation_progress(entry_name)
	if (progress_pair[1] as int) == 0:
		return false
	return (progress_pair[0] as int) == (progress_pair[1] as int)
