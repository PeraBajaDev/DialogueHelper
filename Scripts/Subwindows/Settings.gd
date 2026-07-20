extends Window

@onready var enable_git: CheckBox = $EnableGit
@onready var git_url: LineEdit = $EnableGit/RepoLabel/LineEdit
@onready var url_valid: Label = $EnableGit/RepoLabel/ValidLabel
@onready var repo_label: Label = $EnableGit/RepoLabel
@onready var git_branch: LineEdit = $EnableGit/RepoLabel/BranchLabel/LineEdit
@onready var author: LineEdit = $FontStyle/Author/LineEdit
@onready var style_select: OptionButton = $FontStyle/OptionButton

var folders: Dictionary[int, String] = {}
var changed_style := false

# Bug fix: el _process anterior reescribía author.text y aplicaba theme overrides
# en cada frame. Ahora cacheamos el último estado aplicado y sólo refrescamos
# cuando algo realmente cambia (texto de URL, estado del checkbox de git).
# El label del autor del estilo se carga una vez en _ready y se vuelve a cargar
# sólo al cambiar de estilo.
var _last_url_text: String = ""
var _last_git_enabled: bool = false
var _last_url_valid: int = -1  # -1 desconocido, 0 inválida, 1 válida

func _ready() -> void:
	style_select.clear()
	var i := 0
	var logs := PackedStringArray()
	# Fix: iterar sobre Handle.list_available_styles() en lugar de
	# DirAccess.get_directories_at directamente. El helper ya filtra carpetas
	# que NO contienen Metadata.json, así que ahora el dropdown sólo muestra
	# Styles reales. Antes, cualquier carpeta dentro de res://Styles/ (incluso
	# .git, temporales o basura del usuario) acababa como opción seleccionable
	# y al elegirla load_style fallaba silenciosamente.
	for directory in Handle.list_available_styles():
		var local_name := directory
		var style_metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Handle.style_get_path(&"Metadata.json", directory)))
		if style_metadata == null:
			logs.append("%s had a JSON parsing error." % Handle.style_get_relative_path(&"Metadata.json", directory))
			continue
		elif style_metadata.has(&"Name"):
			local_name = str(style_metadata.Name)
		style_select.add_item(local_name, i)
		folders[i] = directory
		if directory == Handle.style:
			style_select.select(i)
		i += 1
	if !logs.is_empty(): # An error ocurred.
		Handle.style_error_window = Handle.style_error_scene.instantiate()
		(Handle.style_error_window.get_node(^"TextEdit") as TextEdit).text = "\n".join(PackedStringArray(logs))
		Handle.add_child(Handle.style_error_window)
	enable_git.button_pressed = FileAccess.file_exists(&"user://enable_git.bool")
	repo_label.visible = enable_git.button_pressed
	if FileAccess.file_exists(&"user://git_url.txt"):
		git_url.text = FileAccess.get_file_as_string(&"user://git_url.txt").strip_edges()
	if FileAccess.file_exists(&"user://git_branch.txt"):
		git_branch.text = FileAccess.get_file_as_string(&"user://git_branch.txt").strip_edges()
	# Estado inicial del label de autor del estilo y de la validez de la URL.
	_refresh_style_author()
	_last_git_enabled = enable_git.button_pressed
	_last_url_text = git_url.text

# Refresca el label "Author: ..." que se lee del Metadata.json del estilo
# actualmente cargado. Sólo se llama en _ready y al cambiar de estilo, no
# en cada frame.
func _refresh_style_author() -> void:
	author.text = "-----"
	if !Handle.style_metadata.is_empty() and Handle.style_metadata.has(&"Author"):
		author.text = str(Handle.style_metadata.Author)

func _process(_delta: float) -> void:
	# Sólo reaccionamos a cambios reales del checkbox de git o del texto de URL.
	# Sin esto, _process hacía trabajo (asignar text, aplicar theme override)
	# en cada frame, sin necesidad.
	var git_now := enable_git.button_pressed
	if git_now != _last_git_enabled:
		_last_git_enabled = git_now
		repo_label.visible = git_now
		# Forzamos recálculo de validez al re-mostrar el panel.
		_last_url_valid = -1
		_last_url_text = ""

	if git_now:
		var url_now := git_url.text
		if url_now != _last_url_text:
			_last_url_text = url_now
			var is_valid: bool = check_git_url()
			var flag: int = 1 if is_valid else 0
			if flag != _last_url_valid:
				_last_url_valid = flag
				if is_valid:
					url_valid.add_theme_color_override(&"font_color", Color.LIME)
					url_valid.text = "Url is valid."
				else:
					url_valid.add_theme_color_override(&"font_color", Color.RED)
					url_valid.text = "Url is NOT valid."

func check_git_url() -> bool:
	var url := git_url.text
	var starts_with := false
	for _begin: String in [&"https://", &"http://", &"git://", &"ssh://"]:
		if url.begins_with(_begin):
			starts_with = true
	if starts_with && url.ends_with(&".git"):
		return true
	return false

func _on_ok_button_pressed() -> void:
	# Fix: chequear null tras FileAccess.open en todas las escrituras a user://.
	# Si user:// está bloqueado (permisos, antivirus en Windows, disco lleno),
	# la app crasheaba al llamar store_string/close sobre un null. Skip silencioso
	# es el mismo patrón defensivo que ya usa MainNode._save_recent_files.
	var last_style_file := FileAccess.open(&"user://last_style.txt", FileAccess.WRITE)
	if last_style_file != null:
		last_style_file.store_string(style_select.get_item_text(style_select.selected))
		last_style_file.flush()
		last_style_file.close()
	if enable_git.button_pressed:
		var enable_git_file := FileAccess.open(&"user://enable_git.bool", FileAccess.WRITE)
		if enable_git_file != null:
			enable_git_file.close()
		last_style_file = FileAccess.open(&"user://git_url.txt", FileAccess.WRITE)
		if last_style_file != null:
			last_style_file.store_string(git_url.text.strip_edges())
			last_style_file.flush()
			last_style_file.close()
		last_style_file = FileAccess.open(&"user://git_branch.txt", FileAccess.WRITE)
		if last_style_file != null:
			last_style_file.store_string(git_branch.text.strip_edges())
			last_style_file.flush()
			last_style_file.close()
		Handle.git.url = git_url.text.strip_edges()
		Handle.git.branch = git_branch.text.strip_edges()
		# Usamos la variante estática para no depender de DirAccess.open
		# (que devuelve null si user:// no se puede abrir, y .dir_exists()
		# sobre null crashearía).
		if !DirAccess.dir_exists_absolute("user://repo/"):
			var clone_response := Handle.git.clone()
			Handle.handle_git_output.call_deferred(clone_response)
			if !clone_response.success:
				return
		else:
			var set_url_response := Handle.git.set_url()
			Handle.handle_git_output.call_deferred(set_url_response)
			if !set_url_response.success:
				return
			var pull_response := Handle.git.pull()
			Handle.handle_git_output.call_deferred(pull_response)
			if !pull_response.success:
				return
	else:
		if FileAccess.file_exists(&"user://enable_git.bool"):
			# Variante estática: si DirAccess.open(...) devolvía null por
			# permisos / disco lleno, .remove() sobre null crasheaba.
			DirAccess.remove_absolute("user://enable_git.bool")
	if !changed_style && style_select.selected != -1:
		_on_option_button_item_selected(style_select.selected)
	queue_free()

func _on_cancel_button_pressed() -> void:
	queue_free()

func _on_close_requested() -> void:
	queue_free()

func _on_option_button_item_selected(index: int) -> void:
	Handle.load_style(folders[index])
	Handle.main_node.box.handle.force_update = true
	changed_style = true
	# El estilo cambió → el label del autor puede haber cambiado también.
	_refresh_style_author()
