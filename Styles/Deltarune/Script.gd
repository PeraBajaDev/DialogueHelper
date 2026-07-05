extends RefCounted
# This is the template for GameMaker fonts. (2022.2+ supported.)

# Un TAB del archivo de diálogo equivale a una celda visible del glifo de
# espacio. No se expande a cuatro espacios: los TAB reales del texto fuente
# son las unidades que determinan la alineación.
const TAB_WIDTH_IN_SPACE_CELLS: float = 1.0
# Sangría colgante ("hanging indent") de un bullet: las líneas de
# continuación deben alinearse con el TEXTO del bullet, no con la columna
# del "*" en sí. Por defecto "*" y el espacio que le sigue ("* ") ocupan
# 2 celdas. Pero si el autor no deja espacio tras el "*" (p. ej.
# "*Texto"), el texto empieza 1 celda antes, así que ese caso usa
# ASTERISK_PREFIX_WIDTH_CELLS - 1.0 (ver detección dinámica más abajo,
# junto al bloque que reconoce el "*" inicial de línea).
const ASTERISK_PREFIX_WIDTH_CELLS: float = 2.0

# Colores de personaje para el tag "\mN" (medidos directamente de la
# previsualización de referencia que envió el usuario). Cada personaje
# tiene su línea de diálogo completa en un color pastel distinto.
const MOOD_COLORS: Dictionary = {
	0: 0x83f9ffff, # cian (flecha azul)
	1: 0xe1a7fcff, # lila (estandarte)
	2: 0xffab86ff, # naranja (globo)
	3: 0xadffbbff, # verde (cuchara/chef)
	4: 0xfff8a0ff, # amarillo (sombrero vaquero)
	5: 0x85a6ffff, # azul-violeta (llave)
}

const DELTARUNE_FONTS: Array[String] = [
	"fnt_main",
	"fnt_mainbig",
	"fnt_small",
	"fnt_comicsans",
	"fnt_dotumche",
	"fnt_tinynoelle",
	"fnt_ja_main",
	"fnt_ja_mainbig",
	"fnt_ja_small",
	"fnt_ja_comicsans",
	"fnt_ja_dotumche",
	"fnt_ja_kakugo",
	"fnt_ja_tinynoelle",
]

static func prepare_draw(data: IUserData) -> void:
	data.env.last_newline = false
	data.env.started_asterisk = false
	# Sangría de continuación después de un bullet. Si la línea fuente trae
	# TAB antes del asterisco, guardamos esa posición exacta para reutilizarla
	# en un salto automático. La fallback se calcula con TAB, no con espacios.
	data.env.asterisk_indent_x = -1.0
	# Ancho por defecto del prefijo del bullet ("* ", asterisco + espacio).
	# Se ajusta dinámicamente a 1 celda si el "*" no trae espacio detrás
	# (ver el bloque que detecta "*" al inicio de línea, más abajo).
	data.env.asterisk_prefix_width_cells = ASTERISK_PREFIX_WIDTH_CELLS
	data.env.checked_index = -1
	data.env._e = 0
	data.env._c = 0
	data.env._f = 0
	#data.set_current_font(0)
	data.env._sx = -1
	data.env._sy = -1
	data.env.skip = 0
	data.env.first_drawn_char = true
	data.global_env.portrait_target = ""
	if !data.global_env.has("face_texture"):
		data.global_env.face_texture = null
		data.global_env.face_path = ""
		data.global_env.toribody_texture = data.load_texture("Assets/spr_face_tbody.png")
		
	if data.global_env.has("speaker") and str(data.global_env.speaker) != "":
		var has_E_tag := false
		for _ls: String in data.glyph.layer_strings:
			if _ls.find("\\E") != -1:
				has_E_tag = true
				break
			
		if has_E_tag:
			var s := str(data.global_env.speaker)
			if s.length() > 0:
				var ch := s[0]
				var fcharset := "0SRNTLs!!UAaBk!JrcvubKQC"
				data.env._c = fcharset.find(ch)
				if data.env._c != -1:
					data.set_box_portrait(true)

# Devuelve true cuando el carácter actual está al inicio lógico de una línea:
# sólo puede haber espacios/TAB antes de él desde el último salto de línea.
# Esto permite reconocer "\t\t* Texto" como bullet aunque los TAB ya se
# hayan dibujado antes de llegar al asterisco.
# También ignora los tags de control tipo "\XY" (portrait "\EK", mood "\m3",
# color "\cW", etc.) que puedan preceder al "*", ya que no son texto visible
# y no deben impedir que el bullet se reconozca como inicio de línea. Sin
# esto, un "*" precedido de "\EK" (sin TAB) se consideraba "no inicial" y
# la sangría colgante de sus líneas de continuación nunca se activaba.
static func _is_line_leading_char(data: IUserData) -> bool:
	var _newline_chars: Array = []
	if Handle.style_metadata.has("NewLines"):
		_newline_chars = Handle.style_metadata.NewLines as Array
	var _i: int = data.char.index - 1
	while _i >= 0:
		var _char: String = data.char.string[_i]
		if _newline_chars.has(_char):
			return true
		if _char == " " || _char == "\t":
			_i -= 1
			continue
		# Si los 2 caracteres justo antes de esta posición son "\<letra>",
		# _char es el segundo carácter de un tag de control de 3 caracteres
		# ("\" + letra + letra/dígito). Lo saltamos entero y seguimos.
		if _i >= 2 && data.char.string[_i - 2] == "\\":
			_i -= 3
			continue
		return false
	return true

# Color asociado al tag "\mN". Si N no está en la tabla, se devuelve blanco
# (comportamiento por defecto, sin pintar nada).
static func _mood_color(_n: int) -> Color:
	if MOOD_COLORS.has(_n):
		# MOOD_COLORS es un Dictionary, así que leer una clave siempre
		# devuelve Variant para el analizador estático, aunque en tiempo de
		# ejecución el valor guardado sea siempre int (ver la declaración
		# de la constante más arriba).
		@warning_ignore("unsafe_call_argument")
		var _hex: int = int(MOOD_COLORS[_n])
		return Color.hex(_hex)
	return Color.WHITE

# Mira hacia adelante desde start_index (justo después del tag "\mN") y
# comprueba si, tras saltarse los TAB/espacios de sangría, lo que sigue es
# un bullet con el formato "* Texto" (asterisco + espacio). Si el asterisco
# no trae espacio detrás (p. ej. "*Texto"), devuelve false y la línea se
# queda sin colorear.
static func _bullet_has_space_after_asterisk(data: IUserData, start_index: int) -> bool:
	var _i := start_index
	while _i < data.char.string.length() && (data.char.string[_i] == "\t" || data.char.string[_i] == " "):
		_i += 1
	if _i < data.char.string.length() && data.char.string[_i] == "*":
		return _i + 1 < data.char.string.length() && data.char.string[_i + 1] == " "
	return false

static func draw_portrait(data: IUserData) -> void:
	var _target := ""
	var _x := 30
	var _y := 30
	#print(data.env._c)
	#print(data.env._e)
	match data.env._c:
		1: _target = "spr_face_susie_alt/spr_face_susie_alt_%d" % clamp(data.env._e, 0, 99)
		2:
			_target = "spr_face_r_nohat/spr_face_r_nohat_%d" % data.env._e
			_x -= 15
			_y -= 10
		3:
			_target = "spr_face_n_matome/spr_face_n_matome_%d" % data.env._e
			_x -= 10
			_y -= 10
		4:
			match data.env._e:
				0, 1, 2, 6, 7, 9:
					_target = "spr_face_t%d/spr_face_t%d_0" % [data.env._e, data.env._e]
				_:
					_target = "spr_face_t%d" % data.env._e
			_x += 10
			var _t: Texture2D = data.global_env.toribody_texture
			if _t != null:
				data.draw_texture_rect(_t, Rect2(_x - (7 * 2), _y + (29 * 2), _t.get_width() * 2, _t.get_height() * 2), false)
		5:
			_target = "spr_face_l0/spr_face_l0_%d" % data.env._e
			_x -= 10
			_y -= 10
		6:
			_target = "spr_face_sans%d" % data.env._e
			_x += 10
			_y += 5
		9:
			_target = "spr_face_undyne/spr_face_undyne_%d" % data.env._e
			_x -= 10
		10:
			match data.env._e:
				0, 1, 2, 3, 4, 5, 6:
					_target = "spr_face_asgore%d/spr_face_asgore%d_0" % [data.env._e, data.env._e]
				_:
					_target = "spr_face_asgore%d" % data.env._e
			_x -= 3
			_y -= 5
		11:
			_target = "spr_alphysface/spr_alphysface_%d" % data.env._e
			_x -= 5
		12:
			_target = "spr_face_berdly_dark/spr_face_berdly_dark_%d" % data.env._e
			_x -= 10
		13:
			_target = "spr_face_catti/spr_face_catti_%d" % data.env._e
			_x -= 7
			_y += 7
		14:
			_target = "spr_face_c%d" % data.env._e
			_x -= 10
		15:
			_target = "spr_face_jock%d" % data.env._e
			_x -= 10
		16:
			_target = "spr_face_rudy/spr_face_rudy_%d" % data.env._e
			_x -= 7
			_y -= 17
		17:
			_target = "spr_face_catty/spr_face_catty_%d" % data.env._e
			_x -= 5
		18:
			_target = "spr_face_bratty/spr_face_bratty_%d" % data.env._e
			_x -= 5
			_y += 2
		19:
			_target = "spr_face_rurus/spr_face_rurus_%d" % data.env._e
			_x += 5
		20:
			_target = "spr_face_burgerpants/spr_face_burgerpants_%d" % data.env._e
			_x -= 5
			_y -= 5
		21:
			_target = "spr_face_king/spr_face_king_%d" % data.env._e
			_x += 5
			_y -= 5
		22:
			_target = "spr_face_queen/spr_face_queen_%d" % data.env._e
			_x += 5
			_y += 5
		23:
			_target = "spr_face_carol/spr_face_carol_%d" % data.env._e
			_x -= 10
			_y -= 10

	#print(_target)
	if data.global_env.face_path != _target:
		data.global_env.face_path = _target
		data.global_env.face_texture = data.load_texture("Assets/%s.png" % _target)
	if data.global_env.face_texture != null:
		var _t: Texture2D = data.global_env.face_texture
		data.draw_texture_rect(_t, Rect2(_x, _y, _t.get_width() * 2, _t.get_height() * 2), false)

# This function will be called for each glyph (character)
# in the string, this allows you full control of how
# it gets drawn.
static func draw_glyph(data: IUserData) -> void:
	# Los TAB no tienen glyph propio en la fuente (se dibujan con el glyph de
	# espacio, ver más abajo), así que antes se colaban en la condición de
	# "no hay glyph para este char" y la función retornaba de inmediato: el
	# TAB nunca llegaba a dibujarse ni a avanzar la posición X, quedando
	# invisible en la previsualización. Se los excluye explícitamente de este
	# corte temprano para que sigan el mismo camino que el resto de caracteres.
	if data.char.is_ignore || (!data.font.glyphs.has(data.char.char) && data.char.char != "\t" && !data.char.is_newline):
		return
	if not data.char.is_escaped:
		if data.env.skip > 0:
			data.env.skip -= 1
			return
		if data.char.string.length() - data.char.index >= 3:
			if data.char.string.substr(data.char.index, 3) == "/%%":
				data.env.skip = 2
				return
		if data.char.string.length() - data.char.index >= 2:
			if data.char.string.substr(data.char.index, 2) == "/%" || \
				(data.char.char == "^" && data.char.string.substr(data.char.index + 1, 1).is_valid_int()) || \
				data.char.string.substr(data.char.index, 2) == "%%":
				data.env.skip = 1
				return
			if data.char.char == "\\":
				data.env.skip = 2
				data.global_env.portrait_target = data.char.string.substr(data.char.index + 1, 2)
				if data.global_env.has("portrait_target") && str(data.global_env.portrait_target).length() >= 2:
					match str(data.global_env.portrait_target)[0]:
						"E":
							var charset: String = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
							data.env._e = charset.find(str(data.global_env.portrait_target)[1])
							if data.env._e == -1:
								data.env.skip = 1
							else:
								data.set_box_portrait(true)
						"F":
							data.env._c = "0SRNTLs!!UAaBk!JrcvubKQC".find(str(data.global_env.portrait_target)[1])
							if data.env._c == -1:
								data.env.skip = 1
							else:
								data.set_box_portrait(true)
						"T":
							match str(data.global_env.portrait_target)[1]:
								"0": data.env._f = 5
								"1": data.env._f = 2
								"A": data.env._f = 18
								"a": data.env._f = 20
								"N": data.env._f = 12
								"n": data.env._f = 23
								"B": data.env._f = 13
								"S": data.env._f = 10
								"R": data.env._f = 31
								"L": data.env._f = 32
								"X": data.env._f = 40
								"r": data.env._f = 55
								"T": data.env._f = 7
								"J": data.env._f = 35
								"K": data.env._f = 33
								"q": data.env._f = 62
								"Q": data.env._f = 58
								"s": data.env._f = 14
								"U": data.env._f = 17
								"p": data.env._f = 67
								_: data.env.skip = 0
						"c":
							match str(data.global_env.portrait_target)[1]:
								"R": data.glyph.color = Color.RED
								"B": data.glyph.color = Color.BLUE
								"Y": data.glyph.color = Color.YELLOW
								"G": data.glyph.color = Color.LIME
								"W": data.glyph.color = Color.WHITE
								"X": data.glyph.color = Color.BLACK
								"P": data.glyph.color = Color.PURPLE
								"M": data.glyph.color = Color.DARK_RED
								"S": data.glyph.color = Color.hex(0xff80ffff)
								"V": data.glyph.color = Color.hex(0x80ff80ff)
								"0": data.glyph.color = Handle.layer_colors[data.glyph.current_layer] # Fix #2: reset = color de la capa
								"I": data.glyph.color = Color.hex(0x81c0ffff)
								"O": data.glyph.color = Color.hex(0xffa040ff)
								"A": data.glyph.color = Color.hex(0x00aeffff)
								_: data.env.skip = 0
						# \V[x] es un modificador de voz/variante introducido en textos recientes.
						# No afecta la vista previa, pero debe consumirse completo para que
						# ni la barra ni su parámetro se dibujen como texto normal.
						"V":
							pass
						"S", "s", "C", "M", "I":
							if !str(data.global_env.portrait_target)[1].is_valid_int():
								data.env.skip = 0
						"m":
							if !str(data.global_env.portrait_target)[1].is_valid_int():
								data.env.skip = 0
							else:
								# "\mN" identifica al personaje que habla. Su línea
								# entera se pinta del color de ese personaje, pero
								# SÓLO si el bullet que sigue trae el formato normal
								# "* Texto" (con espacio tras el "*"). Si el autor
								# se olvidó del espacio ("*Texto"), la línea se deja
								# en blanco/color por defecto, tal como se pidió.
								var _mood_n: int = int(str(data.global_env.portrait_target)[1])
								if _bullet_has_space_after_asterisk(data, data.char.index + 3):
									data.glyph.color = _mood_color(_mood_n)
						_:
							data.env.skip = 0
				if data.env.skip != 0:
					return
		if (data.char.string.length() - data.char.index == 1 || data.char.index == 0) && data.char.char == "/":
			return
		if data.char.string.length() - data.char.index == 1 && data.char.char == "%":
			return
	var _act_as_newline := data.char.is_newline
	var scale := data.glyph.vscale * data.font.scale * 2.0
	match data.env._f:
		1, 2, 3, 5, 7, 8, 10, 11, 12, 13, 15, 17, 18, 19, 20, 21, 40, 41, 55, 60, 61, 63, 64, 666, 667, 999:
			data.set_current_font(DELTARUNE_FONTS.find("fnt_main"))
			data.env._sx = 8
			data.env._sy = 18
		4, 45, 46, 47, 48, 59, 77:
			data.set_current_font(DELTARUNE_FONTS.find("fnt_mainbig"))
			data.env._sx = 16
			data.env._sy = 28
		6, 30, 31, 32, 33, 34, 35, 36, 42, 51, 52, 56, 57, 58, 62, 65, 66, 67, 78:
			data.set_current_font(DELTARUNE_FONTS.find("fnt_mainbig"))
			data.env._sx = 16
			data.env._sy = 36
		37:
			data.set_current_font(DELTARUNE_FONTS.find("fnt_mainbig"))
			data.env._sx = 18
			data.env._sy = 36
		14:
			data.set_current_font(DELTARUNE_FONTS.find("fnt_comicsans"))
			data.env._sx = 8
			data.env._sy = 18
		22, 23:
			data.set_current_font(DELTARUNE_FONTS.find("fnt_tinynoelle"))
			data.env._sx = 6
			data.env._sy = 18
		50, 53, 54, 69, 70, 71, 72, 74, 75, 76:
			data.set_current_font(DELTARUNE_FONTS.find("fnt_dotumche"))
			data.env._sx = 9
			data.env._sy = 20
		_:
			match DELTARUNE_FONTS[data.get_current_font()]:
				"fnt_main":
					data.env._sx = 8
					data.env._sy = 18
				"fnt_mainbig":
					data.env._sx = 16
					data.env._sy = 36
				"fnt_comicsans":
					data.env._sx = 8
					data.env._sy = 18
				"fnt_tinynoelle":
					data.env._sx = 6
					data.env._sy = 18
				"fnt_dotumche":
					data.env._sx = 9
					data.env._sy = 20
	data.font = data.get_font(data.get_current_font())
	if data.char.index > data.env.checked_index:
		if data.env.checked_index == -1:
			data.env.checked_index = 0
		var _i := 0
		var _fs := ""
		var _newline_chars: Array = []
		if Handle.style_metadata.has("NewLines"):
			_newline_chars = Handle.style_metadata.NewLines as Array

		# Un TAB es whitespace real para el cálculo de salto. Tratarlo como
		# parte de una palabra haría que el ancho de la siguiente palabra se
		# midiera de forma inconsistente respecto al dibujo.
		while data.char.index + _i < data.char.string.length() && (data.char.string[data.char.index + _i] == " " || data.char.string[data.char.index + _i] == "\t" || data.char.string[data.char.index + _i] == "&"):
			_fs += data.char.string[data.char.index + _i]
			_i += 1

		while data.char.index + _i < data.char.string.length() && (data.char.string[data.char.index + _i] != " " && data.char.string[data.char.index + _i] != "\t" && data.char.string[data.char.index + _i] != "&"):
			var _c := data.char.string[data.char.index + _i]

			# Si el carácter es un salto de línea del estilo (#, \n, etc.),
			# no debe contar para el ancho visible de la línea.
			if _newline_chars.has(_c):
				break

			match _c:
				"\\":
					_i += 3
					continue
				"^":
					_i += 2
					continue
				"/":
					if data.char.index + _i == data.char.string.length() - 1 || data.char.index + _i == 0:
						_i += 1
						continue
					if (data.char.index + _i == data.char.string.length() - 2 && data.char.string[data.char.index + _i + 1] == "%") || \
						(data.char.index + _i == data.char.string.length() - 3 && data.char.string[data.char.index + _i + 1] == "%" && data.char.string[data.char.index + _i + 2] == "%"):
						_i += 2
						continue
				"%":
					if (data.char.index + _i == data.char.string.length() - 2 && data.char.string[data.char.index + _i + 1] == "%") || \
						data.char.index + _i == data.char.string.length() - 1:
						_i += 2
						continue

			_fs += _c
			_i += 1

		data.env.checked_index = data.char.index + _i
		var _cpos := data.char.position_offset.x
		#print(_fs)
		
		for _char in _fs:
			if !_newline_chars.has(_char) and (data.font.glyphs.has(_char) || _char == "\t"):
				var glyph: IGlyph = data.font.glyphs[" " if _char == "\t" else _char]
				_cpos += ((data.env._sx if data.env._sx != -1 else glyph.shift) + glyph.offset) * scale * (TAB_WIDTH_IN_SPACE_CELLS if _char == "\t" else 1.0)

		# Margen derecho que deja el juego en píxeles. 15 con retrato,
		# 20 sin retrato. El valor de 20 está deducido empíricamente de
		# Box1/Box2 (Overworld, Battle): con la fórmula correcta
		# `box_width - dialogue_offset.x - extra_margin`, un extra_margin
		# de 20 px reproduce exactamente dónde corta línea el juego.
		# Antes este valor era 40, lo que daba el margen correcto SÓLO
		# cuando dialogue_offset.x también era 20 (caso Box1/Box2: 40-20=20).
		# Para cajas con offset distinto, daba márgenes incorrectos:
		# negativo (desborde) en Box3-6, demasiado grande en otras.
		var extra_margin: int = 15 if data.get_box_portrait() else 20
		# El ancho disponible para texto es box_width - text_start_x.
		# Cuando hay retrato, text_start_x = portrait_offset.x. Cuando NO hay
		# retrato, text_start_x = dialogue_offset.x (no 0.0): antes se usaba
		# 0.0 y eso ignoraba el offset izquierdo del cuadro, así que en cajas
		# con dialogue_offset.x grande (Box3 "Shop Talk" con 60, Box4 "Shop
		# Speech" con 40, Box5 "Shop Select" con 56, Box6 "Shop Description"
		# con 26) el wrap se calculaba demasiado a la derecha y el texto se
		# salía de la caja.
		var _text_start_x: float = float(data.box.portrait_offset.x if data.get_box_portrait() else data.box.dialogue_offset.x)
		if _cpos + extra_margin > data.box.texture.get_width() - _text_start_x && !data.env.first_drawn_char:
			_act_as_newline = true
	if _act_as_newline:
		#data.env.started_asterisk = false
		data.env.last_newline = true
		if data.env.started_asterisk:
			# Tanto un "&" escrito por el autor como un salto automático
			# usan únicamente la base visual del prefijo "* ": dos celdas
			# (una por el asterisco y otra por su espacio). Así, no importa si
			# la línea se parte de forma explícita o por falta de ancho: ambas
			# empiezan en la misma columna y NO heredan los TAB previos al bullet.
			# Los TAB/espacios escritos DESPUÉS de "&" siguen siendo whitespace
			# real y se suman a esta base.
			if !data.char.is_newline || data.char.char == "&":
				var _space_glyph: IGlyph = data.font.glyphs[" "]
				var _space_cell_width: float = ((data.env._sx if data.env._sx != -1 else _space_glyph.shift) + _space_glyph.offset) * scale
				data.char.position_offset.x = ASTERISK_PREFIX_WIDTH_CELLS * _space_cell_width
			else:
				# Sangría objetivo: la columna donde empieza el TEXTO del bullet
				# (justo después de "* "), no la columna del "*" en sí.
				# data.env es un Dictionary, así que leer una clave siempre
				# devuelve Variant para el analizador estático, aunque en tiempo
				# de ejecución el valor guardado sea float (ver prepare_draw y
				# las asignaciones de asterisk_indent_x más abajo).
				@warning_ignore("unsafe_call_argument")
				var _stored_indent_x: float = float(data.env.asterisk_indent_x)
				var _space_glyph: IGlyph = data.font.glyphs[" "]
				var _tab_cell_width: float = ((data.env._sx if data.env._sx != -1 else _space_glyph.shift) + _space_glyph.offset) * scale * TAB_WIDTH_IN_SPACE_CELLS
				# _stored_indent_x es la posición justo ANTES del "*" (sólo los TAB
				# de sangría que lo preceden, o -1 si no traía ninguno). Sumamos el
				# ancho del prefijo del bullet (2 celdas si es "* ", o 1 celda si
				# el autor no dejó espacio tras el "*") para que la sangría
				# objetivo caiga exactamente sobre el texto del bullet.
				var _leading_tabs_x: float = maxf(0.0, _stored_indent_x)
				@warning_ignore("unsafe_call_argument")
				var _prefix_width_cells: float = float(data.env.asterisk_prefix_width_cells)
				var _target_indent_x: float = _leading_tabs_x + _prefix_width_cells * _tab_cell_width
				# Esta rama queda sólo para los separadores explícitos #/\n,
				# que conservan su ajuste histórico de TAB.
				var _explicit_tabs := 0
				if data.char.is_newline:
					var _look_i := data.char.index + 1
					while _look_i < data.char.string.length() && data.char.string[_look_i] == "\t":
						_explicit_tabs += 1
						_look_i += 1
				data.char.position_offset.x = maxf(0.0, _target_indent_x - float(_explicit_tabs) * _tab_cell_width)
		else:
			data.char.position_offset.x = 0
		if data.env._sy == -1:
			var size: int = data.font.glyphs["A"].rect.size.y
			data.char.position_offset.y += (size + (size % 2) + (data.font.size % 2)) * scale
		else:
			data.char.position_offset.y += data.env._sy * scale
	if !data.char.is_newline:
		if data.font.glyphs.has(data.char.char) || data.char.char == "\t":
			var glyph: IGlyph = data.font.glyphs[" " if data.char.char == "\t" else data.char.char]
			data.char.glyph.position.x = data.char.start_position.x + data.char.position_offset.x + (glyph.offset * scale)
			data.char.glyph.position.y = data.char.start_position.y + data.char.position_offset.y
			data.char.glyph.size.x = glyph.rect.size.x * scale * (TAB_WIDTH_IN_SPACE_CELLS if data.char.char == "\t" else 1.0)
			data.char.glyph.size.y = glyph.rect.size.y * scale
			data.draw_glyph()
			if data.char.char == "*" && _is_line_leading_char(data):
				data.env.started_asterisk = true
				# La posición previa al bullet ya incluye los TAB de la cadena
				# (por ejemplo, "\t\t* Texto"). Guardarla hace que los wraps
				# automáticos respeten la misma unidad de alineación que usa el TXT.
				if data.char.position_offset.x > 0.0:
					data.env.asterisk_indent_x = data.char.position_offset.x
				else:
					# Sin TAB explícito, dejamos que el bloque de fallback aplique
					# las celdas TAB tradicionales.
					data.env.asterisk_indent_x = -1.0
				# El ancho del prefijo del bullet no siempre es "* " (asterisco +
				# espacio, 2 celdas): a veces el autor no deja espacio tras el
				# "*" (p. ej. "*Who's..."), y ahí el texto empieza justo 1 celda
				# después del "*", no 2. Lo detectamos mirando el carácter que
				# sigue al "*" en la cadena fuente.
				if data.char.index + 1 < data.char.string.length() && data.char.string[data.char.index + 1] == " ":
					data.env.asterisk_prefix_width_cells = ASTERISK_PREFIX_WIDTH_CELLS
				else:
					data.env.asterisk_prefix_width_cells = ASTERISK_PREFIX_WIDTH_CELLS - 1.0
			data.char.position_offset.x += ((data.env._sx if data.env._sx != -1 else glyph.shift) + glyph.offset) * scale * (TAB_WIDTH_IN_SPACE_CELLS if data.char.char == "\t" else 1.0)
			data.env.last_newline = false
			data.env.first_drawn_char = false
