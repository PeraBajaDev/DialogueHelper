extends RefCounted
class_name IStringContainer

var id := -1
var content := ""
var original_content := ""
var last_edited := ILastEdited.new()
var layer_strings: Array[String] = []
var layer_colors: Array[Color] = []
var box_style := 0
var font_style := 0
var enable_portrait := false
var key := ""  # Nueva propiedad para almacenar Clave
var speaker := ""  # Nuevo: almacena el campo Speaker del .txt

# Bloque 2: marcador "necesita revisión". Persiste en el .txt sólo cuando
# es true (campo NeedsReview:true). Si es false (la mayoría de strings),
# no se escribe nada — así no se ensucia el archivo con miles de
# "NeedsReview:false" repetidos.
var needs_review := false

var equal_strings: Array[int] = []
var equal_strings_index := -1

func _init(json: IFormatEntry = null) -> void:
	var json_data := json.data if json != null else {}
	if json_data.has(&"ID"):
		id = json_data.ID as int

	# Asignación de OriginalContent y Content, evitando sobrescribir Content con vacío
	if json_data.has(&"OriginalContent"):
		original_content = str(json_data.OriginalContent)
		content = original_content  # fallback si Content no existe
	if json_data.has(&"Content") and str(json_data.Content) != "":
		content = str(json_data.Content)

	if json_data.has(&"LastEdited"):
		last_edited = ILastEdited.new(json_data.LastEdited)

	if json_data.has(&"LayerStrings"):
		var ls := str(json_data.LayerStrings).split(&",")
		var sls := [content]
		for _e in ls:
			sls.append(_e.uri_decode())
		layer_strings.clear()
		layer_strings.assign(sls)
	else:
		layer_strings = [content]
	while layer_strings.size() < Handle.layers:
		layer_strings.append(&"")

	if json_data.has(&"LayerColors"):
		var lc := str(json_data.LayerColors).split(&",")
		var clc := []
		for _e in lc:
			clc.append(Color.hex(_e.hex_to_int()))
		layer_colors.clear()
		layer_colors.assign(clc)
	else:
		layer_colors = []
	while layer_colors.size() < Handle.layers:
		layer_colors.append(Color.WHITE)

	if json_data.has(&"BoxStyle"):
		box_style = json_data.BoxStyle as int
	if json_data.has(&"FontStyle"):
		font_style = json_data.FontStyle as int
	if json_data.has(&"EnablePortrait"):
		enable_portrait = json_data.EnablePortrait as bool
	if json_data.has(&"Clave"):
		key = str(json_data.Clave)
	if json_data.has(&"Speaker"):
		speaker = str(json_data.Speaker)
	if json_data.has(&"NeedsReview"):
		# Bloque 2: el campo aparece sólo cuando está activado. Su mera
		# presencia ya implica true; el valor (vacío en archivos nuevos,
		# "true" en archivos guardados con versiones intermedias) sólo se
		# mira para detectar un explícito "false" que podría dejar alguien
		# editando a mano.
		var needs_review_raw := str(json_data.NeedsReview).to_lower().strip_edges()
		needs_review = needs_review_raw != "false" and needs_review_raw != "0"

	#if json_data.has(&"EqualStringsIndex"):
	#	equal_strings_index = json_data.EqualStringsIndex as int

func _to_string() -> String:
	var entry := IFormatEntry.new()
	entry.disable_uri = [&"LayerStrings", &"LayerColors", &"LastEdited"]
	entry.kind = 1

	# Solo sobrescribir Content si difiere de OriginalContent
	if content != original_content:
		entry.data.Content = content
	entry.data.OriginalContent = original_content

	if last_edited.author != "" and last_edited.timestamp != -1:
		entry.data.LastEdited = str(last_edited)

	if !&"".join(PackedStringArray(layer_strings.slice(1))).is_empty():
		var ls: Array[String] = layer_strings.slice(1)
		var last := 0
		for i in range(ls.size()):
			if !ls[i].is_empty():
				last = i + 1
		entry.data.LayerStrings = &",".join(PackedStringArray(ls.slice(0, last)))

	var lc := []
	var last_color_index := 0
	for i in range(layer_colors.size()):
		if layer_colors[i] != Color.WHITE:
			last_color_index = i + 1
		lc.append(String.num_uint64(layer_colors[i].to_rgba32(), 16))

	if !&"".join(PackedStringArray(lc)).replace(&"f", &"").is_empty():
		entry.data.LayerColors = &",".join(PackedStringArray(lc.slice(0, last_color_index)))

	if box_style != 0:
		entry.data.BoxStyle = box_style
	if font_style != 0:
		entry.data.FontStyle = font_style
	if enable_portrait:
		entry.data.EnablePortrait = enable_portrait
	#if equal_strings_index != -1:
	#	entry.data.EqualStringsIndex = equal_strings_index

	# Guardar Clave al final si existe
	if key != "":
		entry.data.Clave = key


	if speaker != "":
		entry.data.Speaker = speaker

	# Bloque 2: el campo NeedsReview sólo aparece en el archivo cuando está
	# activado. Lo escribimos con valor explícito (`NeedsReview:true`) en vez
	# de `NeedsReview:` vacío: el parser antiguo no capturaba un campo vacío
	# si era el último de la línea, así que al reabrir el .txt se perdía la
	# marca. El loader sigue aceptando el formato vacío por compatibilidad.
	if needs_review:
		entry.data.NeedsReview = "true"

	return str(entry)

func update() -> void:
	if layer_strings.is_empty():
		layer_strings.append(content)
		while layer_strings.size() < Handle.layers:
			layer_strings.append(&"")
	if layer_colors.is_empty():
		while layer_colors.size() < Handle.layers:
			layer_colors.append(Color.WHITE)
	if id is not int:
		push_warning("ID is not an Integer!")
	elif id < 0:
		push_warning("ID is not initialized (ID < 0)!")
