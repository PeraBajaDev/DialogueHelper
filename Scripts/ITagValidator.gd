extends RefCounted
class_name ITagValidator

# Validador de etiquetas para el bloque 2.
#
# La idea: al traducir un diálogo de Deltarune/Undertale, hay etiquetas que
# DEBEN preservarse exactamente (cantidad y tipo) entre original y traducción.
# Si el original tiene `\E[2]` y la traducción no, el sprite del personaje
# se rompe en el juego. Si el original termina en `%` y la traducción no,
# la caja de texto no se cierra.
#
# Otras etiquetas son "modificables": un traductor puede añadir o quitar
# pausas y saltos de línea para que el texto cuadre en la caja.
#
# Clasificación (acordada con el usuario):
#  Estrictas (cantidad debe coincidir):
#    \E[x]  emoción         \F[x]  cambio de personaje
#    \M[x]  emoción special  \m[x]  mini face
#    \f[x]  mini text        \T[x]  voz/sonido
#    \C[x]  tipo de elección \C     elección Undertale (sin parámetro)
#    \c[x]  color Deltarune
#    \R \G \Y \B \O \L \P \p \W \X  colores Undertale
#    ~[n]   marcador de control/avance
#    /      espera input     %      cierra mensaje    %%  cierra writer
#  Modificables (no se valida cantidad):
#    ^[1-9] pausa            &      newline
#
# El backtick `X escapa el siguiente carácter — `\E ya no es etiqueta de
# emoción, se renderiza literal. Hay que respetarlo al contar.

# Resultado de validar una sola string.
class TagDiff extends RefCounted:
	var ok: bool = true
	# Tags presentes en el original pero NO en la traducción ("Missing"),
	# y tags presentes en la traducción pero NO en el original ("Extra").
	# Cada lista es de tags formateados (p.ej. "\\E[2]", "%").
	var missing: PackedStringArray = PackedStringArray()
	var extra: PackedStringArray = PackedStringArray()
	# Bloque 2: true si AL MENOS UNO de original o traducción contiene
	# alguna tag estricta. Cuando es false, no hace sentido mostrar el
	# panel del validador — son strings de texto plano (saludos, nombres,
	# etc.) y la información "✓ Tags OK" sólo añadiría ruido visual.
	var has_any_tag: bool = false
	# Bug fix: además de cantidad y composición, validamos también el
	# orden de aparición. Solo se reporta cuando los conteos ya coinciden
	# (sin missing/extra) pero las secuencias difieren — si hay missing o
	# extra, arreglarlos suele arreglar también el orden, así que mostrar
	# "Wrong order" entonces sería ruido.
	var order_mismatch: bool = false

	# Mensaje de una línea pensado para el panel del editor.
	func to_label_text() -> String:
		if ok:
			return "✓ Tags OK"
		var parts: PackedStringArray = PackedStringArray()
		if not missing.is_empty():
			parts.append("Missing: " + " ".join(missing))
		if not extra.is_empty():
			parts.append("Extra: " + " ".join(extra))
		if order_mismatch:
			parts.append("Wrong order")
		return "⚠ " + "  ·  ".join(parts)

# Patrones de etiquetas estrictas. Orden importa: las más específicas
# primero (\c[x] antes de \C\b por si el regex se solapa). El regex de
# Godot 4 admite la sintaxis estándar.
#
# Nota sobre el backtick: el "tokenizer" anterior recorre la string ignorando
# los caracteres precedidos por backtick. Lo hacemos antes de aplicar regex
# para no contar `\E` (escapado) como una etiqueta.

const _STRICT_TAGS: Array = [
	# Etiquetas con un parámetro entre crackets/raw single-char tras la barra.
	# Capturamos la etiqueta completa (incluido el parámetro) para poder
	# distinguir \E[1] de \E[2] al contar.
	{ "name": "emotion",      "pattern": "\\\\E(.)" },         # \E[x]
	{ "name": "special",      "pattern": "\\\\M(.)" },         # \M[x]
	{ "name": "char_face",    "pattern": "\\\\F(.)" },         # \F[x]
	{ "name": "mini_face",    "pattern": "\\\\m(.)" },         # \m[x]
	{ "name": "mini_text",    "pattern": "\\\\f(.)" },         # \f[x]
	{ "name": "voice",        "pattern": "\\\\T(.)" },         # \T[x]
	{ "name": "voice_variant", "pattern": "\\\\V(.)" },         # \V[x]
	{ "name": "choice_type",  "pattern": "\\\\C([1-9])" },     # \C[1-9]
	{ "name": "color_dr",     "pattern": "\\\\c(.)" },         # \c[x]
	# Colores Undertale: barra invertida + letra concreta.
	{ "name": "color_ut",     "pattern": "\\\\([RGYBOLPpWX])" },
	# \C sin parámetro: la elección Undertale. Se valida sólo si no hay
	# dígito detrás (porque \C2 es choice_type, no choice_ut).
	# El lookahead negativo (?![1-9]) evita el solape.
	{ "name": "choice_ut",    "pattern": "\\\\C(?![1-9])" },
]

# Etiquetas estrictas que NO empiezan por barra (símbolos sueltos).
# Las contamos por separado porque la regex es muy distinta y no llevan
# parámetro.
const _STRICT_SYMBOLS: Array = [
	{ "name": "close_writer", "literal": "%%" },  # comprobado ANTES que %
	{ "name": "close_msg",    "literal": "%"  },
	{ "name": "wait_input",   "literal": "/"  },
]

# Marcadores estrictos sin barra. Se guardan con su valor completo para
# distinguir ~1 de ~2 (o cualquier número de varios dígitos).
const _STRICT_INLINE_PATTERNS: Array[String] = [
	"~[0-9]+",
]

# --- Caché de RegEx compiladas ---------------------------------------------
# Optimización: antes _count_tags() compilaba las ~10 expresiones de
# _STRICT_TAGS (y _extract_tag_sequence() una combinada más) en CADA llamada.
# Como validate_string() se invoca una vez por string al pintar la lista del
# selector —y esa lista se reconstruye entera al usar el menú de búsqueda—,
# eso suponía recompilar decenas de regex por cada cambio de string, y se
# notaba como un pequeño tirón en la interfaz. Los patrones son constantes, así
# que los compilamos una sola vez (de forma perezosa) y reutilizamos los
# objetos durante toda la sesión. validate_string() solo se llama desde el hilo
# principal, de modo que compartir estas instancias no plantea problemas de
# concurrencia.
static var _strict_regexes_cache: Array[RegEx] = []
static var _sequence_regex_cache: RegEx = null

# Devuelve las RegEx de _STRICT_TAGS ya compiladas, en orden. Los patrones que
# (hipotéticamente) no compilaran se omiten, igual que hacía el `continue` del
# código original; _count_tags solo usa el match completo, no el nombre ni el
# índice del tag, así que omitir uno no descoloca nada.
static func _get_strict_regexes() -> Array[RegEx]:
	if _strict_regexes_cache.is_empty():
		for entry: Dictionary in _STRICT_TAGS:
			var re := RegEx.new()
			# El valor del Dictionary es Variant; casteamos a String para
			# silenciar UNSAFE_CALL_ARGUMENT (compile() requiere String).
			var err: int = re.compile(str(entry["pattern"]))
			if err == OK:
				_strict_regexes_cache.append(re)
	return _strict_regexes_cache

# Devuelve la RegEx combinada de _extract_tag_sequence ya compilada.
# Orden de las alternativas (importa, se evalúan de izquierda a derecha):
#   %% > %                       (cierre de writer antes que de mensaje)
#   \C[1-9] > \C                 (choice_type antes que choice_ut suelta)
#   \[EMFmfTVc].                  (tags con un parámetro arbitrario)
#   \[RGYBOLPpWX]                 (colores Undertale, sin parámetro)
#   ~[0-9]+                       (marcador de control/avance)
#   /                             (espera input)
static func _get_sequence_regex() -> RegEx:
	if _sequence_regex_cache == null:
		_sequence_regex_cache = RegEx.new()
		_sequence_regex_cache.compile("%%|\\\\C[1-9]|\\\\C|\\\\[EMFmfTVc].|\\\\[RGYBOLPpWX]|~[0-9]+|%|/")
	return _sequence_regex_cache

# Quita los caracteres escapados con backtick. "ABC`Xdef" → "ABCdef".
# El backtick fuera de "`X" se mantiene tal cual (caso raro pero posible).
static func _strip_backtick_escapes(value: String) -> String:
	var result: String = ""
	var i: int = 0
	while i < value.length():
		var user_char: String = value[i]
		if user_char == "`" and i + 1 < value.length():
			# Saltamos backtick + el carácter siguiente (queda fuera).
			i += 2
		else:
			result += user_char
			i += 1
	return result

# Cuenta tags estrictas en una string. Devuelve dict {tag_repr: count}.
# tag_repr es la forma "humana" para mostrar al usuario, p.ej. "\E[2]", "%", "/".
static func _count_tags(value: String) -> Dictionary:
	var clean_string: String = _strip_backtick_escapes(value)
	var counts: Dictionary = {}

	# Símbolos: %% antes que %, así contamos %% una vez y NO dos como %.
	var _symbol_pos_consumed: Array[int] = [] # Variable declarada pero no usada
	var work: String = clean_string

	# Reemplazamos los %% encontrados por marcadores invisibles para que el
	# segundo paso (contando %) no los cuente otra vez.
	var double_percentage_count: int = work.count("%%")
	if double_percentage_count > 0:
		counts["%%"] = double_percentage_count
		work = work.replace("%%", "")

	var percentaje_count: int = work.count("%")
	if percentaje_count > 0:
		counts["%"] = percentaje_count

	var slash_count: int = clean_string.count("/")
	if slash_count > 0:
		counts["/"] = slash_count

	# Marcadores inline como ~1, ~2, etc. Se conservan individualmente para
	# que el validador detecte tanto ausencias como cambios de valor.
	for pattern: String in _STRICT_INLINE_PATTERNS:
		var inline_re := RegEx.new()
		if inline_re.compile(pattern) != OK:
			continue
		for _m: RegExMatch in inline_re.search_all(clean_string):
			var full: String = _m.get_string(0)
			# Dictionary.get() devuelve Variant. Evitamos int(Variant), que el
			# analizador estricto marca como UNSAFE_CALL_ARGUMENT.
			if counts.has(full):
				var current: Variant = counts[full]
				if current is int:
					counts[full] = current + 1
				else:
					counts[full] = 1
			else:
				counts[full] = 1

	# Tags con barra invertida: usamos las regex precompiladas y cacheadas.
	for re: RegEx in _get_strict_regexes():
		var matches: Array[RegExMatch] = re.search_all(clean_string)
		for _m: RegExMatch in matches:
			var full: String = _m.get_string(0)
			# Para color_ut, choice_ut y otros sin parámetro, _full ya es la
			# representación humana ("\R", "\C"). Para los con parámetro,
			# _full incluye el parámetro ("\E[2]" → en realidad \E2 según el
			# formato del juego, pero respetamos el original).
			if not counts.has(full):
				counts[full] = 0
			counts[full] += 1
	return counts

# Extrae todas las tags estrictas en el ORDEN en que aparecen. A diferencia
# de _count_tags, que devuelve un dict y por construcción pierde el orden,
# esta función devuelve un PackedStringArray donde cada elemento es la
# representación humana de un tag tal y como aparece (p.ej. "\E[2]", "%%",
# "\R"). Se usa para detectar cambios de orden cuando los conteos coinciden.
#
# Implementación: un único regex con todas las alternativas. El motor de
# RegEx de Godot evalúa las alternativas de izquierda a derecha y matchea
# la primera, así que el orden de las alternativas en el patrón importa:
# las más específicas primero (%% antes de %, \C[1-9] antes de \C suelta).
static func _extract_tag_sequence(value: String) -> PackedStringArray:
	var clean_string: String = _strip_backtick_escapes(value)
	var result: PackedStringArray = PackedStringArray()
	# RegEx combinada precompilada (ver _get_sequence_regex). El orden de las
	# alternativas se documenta allí, junto a su compilación.
	var re: RegEx = _get_sequence_regex()
	for _m: RegExMatch in re.search_all(clean_string):
		result.append(_m.get_string(0))
	return result

# Compara original vs translation y devuelve un TagDiff.
static func validate(original: String, translation: String) -> TagDiff:
	var diff: TagDiff = TagDiff.new()
	if original == "" and translation == "":
		return diff
	var original_counts: Dictionary = _count_tags(original)
	var translation_counts: Dictionary = _count_tags(translation)

	# Bloque 2: indicador para que la UI pueda decidir si vale la pena
	# mostrar el panel del validador. True si cualquiera de los dos lados
	# tenía al menos una tag.
	diff.has_any_tag = not original_counts.is_empty() or not translation_counts.is_empty()

	# Tags presentes en el original con su conteo.
	for tag: String in original_counts.keys():
		var original_count: int = original_counts[tag]
		var translation_count: int = translation_counts.get(tag, 0)
		if translation_count < original_count:
			# Faltan (original_count - translation_count) ocurrencias.
			var times: int = original_count - translation_count
			for i in range(times):
				diff.missing.append(tag)
	# Tags presentes en la traducción que no estaban en el original (o que
	# están más veces que en el original).
	for tag: String in translation_counts.keys():
		var translation_count: int = translation_counts[tag]
		var original_count: int = original_counts.get(tag, 0)
		if translation_count > original_count:
			var times: int = translation_count - original_count
			for i in range(times):
				diff.extra.append(tag)

	# Bug fix: detección de cambio de orden. Solo válida cuando los conteos
	# ya coinciden (sin missing/extra) y hay al menos una tag — si no, el
	# usuario está aún arreglando el conteo y avisar del orden sería ruido.
	if diff.missing.is_empty() and diff.extra.is_empty() and diff.has_any_tag:
		var orig_seq: PackedStringArray = _extract_tag_sequence(original)
		var trans_seq: PackedStringArray = _extract_tag_sequence(translation)
		if orig_seq != trans_seq:
			diff.order_mismatch = true

	diff.ok = diff.missing.is_empty() and diff.extra.is_empty() and not diff.order_mismatch
	return diff

# Atajo para validar un IStringContainer entero (sólo capa 0 = content).
static func validate_string(string_container: IStringContainer) -> TagDiff:
	if string_container == null:
		return TagDiff.new()
	return validate(string_container.original_content, string_container.content)
