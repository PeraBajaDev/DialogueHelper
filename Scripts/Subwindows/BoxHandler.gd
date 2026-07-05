extends Control
class_name BoxHandler

@onready var box: WBox = get_parent()

# Placeholders PUA (U+E000..) para representar chars escapados con ` (backtick).
# Un `X en el texto fuente significa "dibuja X literal, no interpretes como escape".
# Mapeamos cada char "peligroso" a un code-point privado; la lógica de Deltarune
# ve el placeholder y NO dispara sus ramas especiales. Luego en el draw loop
# rehidratamos char.char al original y marcamos is_escaped = true.
# La definición canónica vive en IFont (clase sin dependencias), que además los
# usa para registrar alias de glifo y que el ancho del char escapado cuente en
# el cálculo del salto de línea.
const ESCAPE_PLACEHOLDERS := IFont.ESCAPE_PLACEHOLDERS
const PLACEHOLDER_TO_CHAR := IFont.PLACEHOLDER_TO_CHAR

var last_layer_strings := []
var last_layer_colors := []
var last_pos := Vector2.ZERO
var queue_update_secs := -1.0
var force_update := false

var global_env := {}

func _process(_delta: float) -> void:
	var _update := false
	if Handle.layer_strings != last_layer_strings:
		last_layer_strings = Handle.layer_strings.duplicate()
		_update = true
	if Handle.layer_colors != last_layer_colors:
		last_layer_colors = Handle.layer_colors.duplicate()
		_update = true
	var _posx := (box.portrait_offset.x if box.supports_portrait && box.portrait_enabled else box.dialogue_offset.x) * Handle.visual_scale
	var _posy := (box.portrait_offset.y if box.supports_portrait && box.portrait_enabled else box.dialogue_offset.y) * Handle.visual_scale
	if Vector2(_posx, _posy) != last_pos:
		last_pos = Vector2(_posx, _posy)
		_update = true
	if queue_update_secs > 0.0:
		queue_update_secs -= _delta
		if queue_update_secs <= 0.0:
			_update = true
	if force_update:
		force_update = false
		_update = true
	if _update:
		queue_redraw()

# Procesa `X (backtick-escape) antes que cualquier otra cosa.
# - `X donde X ∈ {&,%,/,^,\,`,#} → placeholder PUA (renderizado literal luego).
# - `X para cualquier otro X  → X (el backtick se consume, X queda tal cual).
func _process_backtick_escapes(s: String) -> String:
	# Primero `` (doble backtick) → placeholder de backtick, para que un backtick
	# suelto no interfiera con los reemplazos siguientes.
	s = s.replace("``", ESCAPE_PLACEHOLDERS["`"])
	for orig: String in ESCAPE_PLACEHOLDERS.keys():
		if orig == "`":
			continue
		s = s.replace("`" + orig, ESCAPE_PLACEHOLDERS[orig])
	# Cualquier `X restante → X (el backtick se come, queda el char).
	var _rx := RegEx.new()
	_rx.compile("`(.)")
	s = _rx.sub(s, "$1", true)
	return s

# Limpieza de tags de preview que no queremos mostrar (\f[X], \m[X]...).
# Importante: esta función prepara una cadena temporal para el dibujo. Nunca
# modifica el contenido que se guarda en el TXT ni el que se exporta como JSON.
func _clean_preview_text(s: String) -> String:
	var regex := RegEx.new()
	# \f[X] → eliminar (X puede ser dígito o letra).
	regex.compile(r"\\f.")
	s = regex.sub(s, "", true)
	# \m[X] ANTES se eliminaba aquí por ser "sólo" un tag de control sin
	# efecto visual. Ahora Script.gd (estilo Deltarune) SÍ interpreta "\mN"
	# para pintar la línea del color del personaje, así que ya no se quita
	# en el preprocesado: se deja que el estilo lo consuma él mismo (igual
	# que hace con "\E", "\c", etc.), sin dibujar el tag ni afectar el
	# ancho/posición del texto.
	# Los marcadores inline ~n se conservan SIEMPRE como texto literal. Antes
	# un ~n al inicio se convertía en TAB y desaparecía; ahora ~1, ~2, etc.
	# se dibujan y ocupan el ancho real de sus glifos en cualquier posición.
	return s
	
func _draw() -> void:
	custom_minimum_size = Vector2.ZERO
	if Handle.font_data.is_empty():
		return
	# Bug fix: durante un Reload Style hay una ventana de un par de frames en la
	# que current_font/current_box pueden quedar fuera de rango (Style nuevo
	# con menos fuentes/cajas que el anterior, antes de que MainNode._process
	# ajuste los SpinBox). Sin estos chequeos, los accesos a font_data[] /
	# box_data[] del bucle de abajo crashean. Salir del frame en silencio es
	# preferible: el siguiente frame ya tendrá los índices saneados.
	if Handle.current_font < 0 or Handle.current_font >= Handle.font_data.size():
		return
	if Handle.box_data.is_empty() or box.current_box < 0 or box.current_box >= Handle.box_data.size():
		return
	if Handle.user_script is GDScript:
		if Handle.user_script_obj == null:
			Handle.user_script_obj = Handle.user_script.new()
		var _env := {}
		var _ls := Handle.layer_strings.duplicate()
		var _lc := Handle.layer_colors.duplicate()
		
		var _data := IUserData.new()
		_data.__parent = self
		_data.env = _env
		_data.global_env = global_env
		_data.glyph.layer_strings = _ls
		_data.glyph.layer_colors = _lc
		_data.glyph.vscale = Handle.visual_scale
		_data.char.start_position.x = last_pos.x
		_data.char.start_position.y = last_pos.y
		if Handle.user_script_obj.has_method("prepare_draw"):
			@warning_ignore("unsafe_method_access")
			Handle.user_script_obj.prepare_draw(_data)
		for _layer in range(Handle.layer_strings.size()):
			_data.glyph.current_layer = _layer
			_data.char.position_offset = Vector2.ZERO
			var _index := 0
			var _current_string: String = Handle.layer_strings[_layer]

			# 🔹 Primero procesar los escapes con backtick (`X → placeholder / literal).
			_current_string = _process_backtick_escapes(_current_string)
			# 🔹 Luego limpiar etiquetas de preview que no queremos mostrar.
			_current_string = _clean_preview_text(_current_string)

			_data.glyph.color = Handle.layer_colors[_layer]
			# ya no necesitamos _escaped_amp porque usamos placeholder
			for _layer_char: String in _current_string:
				# do this so that if the font was changed it changes in real time
				_data.font = Handle.font_data[Handle.current_font]
				_data.box = Handle.box_data[box.current_box]
				#
				_data.char.char = _layer_char
				_data.char.glyph = Rect2()
				_data.char.index = _index
				_data.char.string = _current_string

				# Si es cualquiera de los placeholders de backtick-escape, rehidratamos
				# al char literal y levantamos is_escaped para que el script del estilo
				# salte TODA su lógica de interpretación (/, ^, %, \, &, skip...).
				var _escaped_to: String = PLACEHOLDER_TO_CHAR.get(_layer_char, "")
				if _escaped_to != "":
					_data.char.char = _escaped_to
					_data.char.is_newline = false
					_data.char.is_ignore = false
					_data.char.is_escaped = true
				else:
					_data.char.is_escaped = false
					# --- Lógica normal para is_newline
					if Handle.style_metadata.has("NewLines"):
						var _is_newline: bool = (Handle.style_metadata.NewLines as Array).has(_layer_char)
						_data.char.is_newline = _is_newline
					# Mantener la lógica de "Ignore" del style (sin sobreescribir si ya es true)
					if Handle.style_metadata.has("Ignore"):
						_data.char.is_ignore = _data.char.is_ignore or (Handle.style_metadata.Ignore as Array).has(_layer_char)
				
				if Handle.user_script_obj.has_method("draw_glyph"):
					@warning_ignore("unsafe_method_access")
					Handle.user_script_obj.draw_glyph(_data)
				_index += 1
		if Handle.user_script_obj.has_method("draw_portrait") && Handle.main_node.box.portrait_enabled && Handle.main_node.box.supports_portrait:
			_data.char = null
			@warning_ignore("unsafe_method_access")
			Handle.user_script_obj.draw_portrait(_data)
		queue_update_secs = _data.queue_update_secs
		for _node in box.handle.get_children():
			if _node is Sprite2D:
				var _spr: Sprite2D = _node
				if _spr.texture != null:
					if _spr.position.x + (_spr.texture.get_width() * _spr.scale.x) > custom_minimum_size.x:
						custom_minimum_size.x = _spr.position.x + (_spr.texture.get_width() * _spr.scale.x)
					if _spr.position.y + (_spr.texture.get_height() * _spr.scale.y) > custom_minimum_size.y:
						custom_minimum_size.y = _spr.position.y + (_spr.texture.get_height() * _spr.scale.y)
						
		# Si el retrato está activo, retrasar la aparición de la barra horizontal unos px
		if box.portrait_enabled and box.supports_portrait:
			custom_minimum_size.x = max(0.0, custom_minimum_size.x - 8.0)
