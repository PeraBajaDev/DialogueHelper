extends Window

@onready var search_type: OptionButton = $SearchTypeLabel/OptionButton
@onready var search_for: TextEdit = $SearchForLabel/TextEdit
@onready var case_sensitive: CheckBox = $CaseSensitive

var searching_scene := preload("res://Subwindows/ProgressBars/Searching.tscn")
var search_results_scene := preload("res://Subwindows/SearchResults.tscn")
var searching_window: WLoading = null
var search_results_window: WSearchResults = null

var last_thread: Thread = null

# Bug fix: si el usuario cerraba la ventana mientras el thread aún iteraba,
# el worker seguía haciendo call_deferred sobre `searching_window` y sobre el
# `ItemList` de resultados, que ya estaban en cola de free. Eso producía
# warnings y, en algunos casos, crashes. Con este flag el worker se entera
# de la cancelación y abandona limpiamente; además protegemos cada
# call_deferred con is_instance_valid().
var _cancelled: bool = false

func _ready() -> void:
	# Bloque 2 fix: search_kind se persiste como ID (no como índice). Antes
	# el código hacía `search_type.select(search_kind)`, que toma índice y
	# no ID — al cambiar las opciones del OptionButton (quitamos "Entry",
	# añadimos "Clave"), un valor antiguo de search_kind acababa
	# seleccionando la opción equivocada o causaba "Index out of bounds".
	# Ahora resolvemos ID → índice y caemos a "String" si el ID guardado
	# ya no existe en esta versión.
	var saved_id: int = (get_parent() as WDialogueHelper).search_kind
	var idx: int = search_type.get_item_index(saved_id)
	if idx == -1:
		# Fallback: buscar el item con id 1 (String); si no existe, el
		# primero. Esto cubre tanto archivos antiguos (kind=0 era "Entry")
		# como cualquier valor inválido.
		var string_idx: int = search_type.get_item_index(1)
		if string_idx != -1:
			search_type.select(string_idx)
		elif search_type.item_count > 0:
			search_type.select(0)
	else:
		search_type.select(idx)

func _process(_delta: float) -> void:
	if last_thread is Thread:
		if !last_thread.is_alive():
			last_thread.wait_to_finish()
			last_thread = null
			# Sólo auto-cerramos si el usuario no la cerró ya.
			if not _cancelled:
				queue_free()

func _on_close_requested() -> void:
	# Marcamos cancelación ANTES de queue_free; el worker chequea esto y
	# se detiene en el siguiente call_deferred. La ventana se libera ahora;
	# el thread terminará en background y _process lo recoge con
	# wait_to_finish() en el siguiente tick.
	_cancelled = true
	# Persistimos el modo de búsqueda elegido para la próxima apertura.
	# Guardamos el ID, no el índice — los IDs son estables aunque cambien
	# las posiciones de los items en futuras versiones.
	if search_type.get_selected_id() != -1:
		(get_parent() as WDialogueHelper).search_kind = search_type.get_selected_id()
	if last_thread is Thread:
		last_thread.wait_to_finish()
		last_thread = null
	queue_free()

func _on_search_button_pressed() -> void:
	if search_type.get_selected_id() == -1:
		return
	# Si ya hay una búsqueda en curso, la cancelamos antes de empezar otra.
	if last_thread is Thread:
		_cancelled = true
		last_thread.wait_to_finish()
		last_thread = null
		_cancelled = false
	var do_casing := case_sensitive.button_pressed
	var search := search_for.text
	# Modo de búsqueda: "String" busca en el contenido de la traducción,
	# "Clave" busca en el campo Clave. La opción "Entry" del search por
	# nombre de entry se eliminó: para eso ya está la barra "Search..."
	# del panel principal que filtra en vivo el dialogue_selector.
	var kind_id: int = search_type.get_selected_id()
	var kind: String = search_type.get_item_text(search_type.get_item_index(kind_id))
	if !do_casing:
		search = search.to_lower()
	(get_parent() as WDialogueHelper).search_kind = kind_id
	var data: Dictionary = Handle.strings
	searching_window = searching_scene.instantiate()
	add_child(searching_window)
	searching_window.progress_bar.set_max(Handle.string_size)
	last_thread = Thread.new()
	search_results_window = search_results_scene.instantiate()
	get_parent().add_child(search_results_window)
	search_results_window.title = "Search results for: " + str(search_for.text)
	var item_list: ItemList = search_results_window.get_node("ItemList")
	# Capturamos una referencia local al ItemList y a la ventana de progreso
	# para checkear validez antes de tocarlos desde el worker.
	last_thread.start(func() -> void:
		var progress_value := 0
		for _entry_local_name: String in data.keys():
			if _cancelled:
				return
			var index := 0
			for _strg: IStringContainer in data[_entry_local_name]:
				if _cancelled:
					return
				var haystack: String
				match kind:
					"Clave":
						haystack = str(_strg.key)
					_:
						haystack = str(_strg.content)
				if !do_casing:
					haystack = haystack.to_lower()
				if haystack.contains(search):
					if is_instance_valid(item_list):
						item_list.add_item.call_deferred( _entry_local_name + ":" + str(index + 1))
				progress_value += 1
				index += 1
				if is_instance_valid(searching_window) and is_instance_valid(searching_window.progress_bar):
					searching_window.progress_bar.set_value.call_deferred(progress_value)
		# Al terminar, ocultamos la ventana de búsqueda y damos foco a los
		# resultados. Sólo si seguimos vivos y no se canceló.
		if not _cancelled and is_instance_valid(self):
			set_visible.call_deferred(false)
		if not _cancelled and is_instance_valid(search_results_window):
			search_results_window.grab_focus.call_deferred()
	)
