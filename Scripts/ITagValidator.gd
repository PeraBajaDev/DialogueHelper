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
		var _parts: PackedStringArray = PackedStringArray()
		if not missing.is_empty():
			_parts.append("Missing: " + " ".join(missing))
		if not extra.is_empty():
			_parts.append("Extra: " + " ".join(extra))
		if order_mismatch:
			_parts.append("Wrong order")
		return "⚠ " + "  ·  ".join(_parts)

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
		for _entry: Dictionary in _STRICT_TAGS:
			var _re := RegEx.new()
			# El valor del Dictionary es Variant; casteamos a String para
			# silenciar UNSAFE_CALL_ARGUMENT (compile() requiere String).
			var _err: int = _re.compile(str(_entry["pattern"]))
			if _err == OK:
				_strict_regexes_cache.append(_re)
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
static func _strip_backtick_escapes(_s: String) -> String:
	var _out: String = ""
	var _i: int = 0
	while _i < _s.length():
		var _c: String = _s[_i]
		if _c == "`" and _i + 1 < _s.length():
			# Saltamos backtick + el carácter siguiente (queda fuera).
			_i += 2
		else:
			_out += _c
			_i += 1
	return _out

# Cuenta tags estrictas en una string. Devuelve dict {tag_repr: count}.
# tag_repr es la forma "humana" para mostrar al usuario, p.ej. "\E[2]", "%", "/".
static func _count_tags(_s: String) -> Dictionary:
	var _clean: String = _strip_backtick_escapes(_s)
	var _counts: Dictionary = {}

	# Símbolos: %% antes que %, así contamos %% una vez y NO dos como %.
	var _symbol_pos_consumed: Array[int] = []
	var _work: String = _clean

	# Reemplazamos los %% encontrados por marcadores invisibles para que el
	# segundo paso (contando %) no los cuente otra vez.
	var _pct_pct_count: int = _work.count("%%")
	if _pct_pct_count > 0:
		_counts["%%"] = _pct_pct_count
		_work = _work.replace("%%", "")

	var _pct_count: int = _work.count("%")
	if _pct_count > 0:
		_counts["%"] = _pct_count

	var _slash_count: int = _clean.count("/")
	if _slash_count > 0:
		_counts["/"] = _slash_count

	# Marcadores inline como ~1, ~2, etc. Se conservan individualmente para
	# que el validador detecte tanto ausencias como cambios de valor.
	for _pattern: String in _STRICT_INLINE_PATTERNS:
		var _inline_re := RegEx.new()
		if _inline_re.compile(_pattern) != OK:
			continue
		for _m: RegExMatch in _inline_re.search_all(_clean):
			var _full: String = _m.get_string(0)
			# Dictionary.get() devuelve Variant. Evitamos int(Variant), que el
			# analizador estricto marca como UNSAFE_CALL_ARGUMENT.
			if _counts.has(_full):
				var _current: Variant = _counts[_full]
				if _current is int:
					_counts[_full] = _current + 1
				else:
					_counts[_full] = 1
			else:
				_counts[_full] = 1

	# Tags con barra invertida: usamos las regex precompiladas y cacheadas.
	for _re: RegEx in _get_strict_regexes():
		var _matches: Array[RegExMatch] = _re.search_all(_clean)
		for _m: RegExMatch in _matches:
			var _full: String = _m.get_string(0)
			# Para color_ut, choice_ut y otros sin parámetro, _full ya es la
			# representación humana ("\R", "\C"). Para los con parámetro,
			# _full incluye el parámetro ("\E[2]" → en realidad \E2 según el
			# formato del juego, pero respetamos el original).
			if not _counts.has(_full):
				_counts[_full] = 0
			_counts[_full] += 1
	return _counts

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
static func _extract_tag_sequence(_s: String) -> PackedStringArray:
	var _clean: String = _strip_backtick_escapes(_s)
	var _result: PackedStringArray = PackedStringArray()
	# RegEx combinada precompilada (ver _get_sequence_regex). El orden de las
	# alternativas se documenta allí, junto a su compilación.
	var _re: RegEx = _get_sequence_regex()
	for _m: RegExMatch in _re.search_all(_clean):
		_result.append(_m.get_string(0))
	return _result

# Compara original vs translation y devuelve un TagDiff.
static func validate(_original: String, _translation: String) -> TagDiff:
	var _diff: TagDiff = TagDiff.new()
	if _original == "" and _translation == "":
		return _diff
	var _orig_counts: Dictionary = _count_tags(_original)
	var _trans_counts: Dictionary = _count_tags(_translation)

	# Bloque 2: indicador para que la UI pueda decidir si vale la pena
	# mostrar el panel del validador. True si cualquiera de los dos lados
	# tenía al menos una tag.
	_diff.has_any_tag = not _orig_counts.is_empty() or not _trans_counts.is_empty()

	# Tags presentes en el original con su conteo.
	for _tag: String in _orig_counts.keys():
		var _o: int = _orig_counts[_tag]
		var _t: int = _trans_counts.get(_tag, 0)
		if _t < _o:
			# Faltan (_o - _t) ocurrencias.
			var _times: int = _o - _t
			for _i in range(_times):
				_diff.missing.append(_tag)
	# Tags presentes en la traducción que no estaban en el original (o que
	# están más veces que en el original).
	for _tag: String in _trans_counts.keys():
		var _t: int = _trans_counts[_tag]
		var _o: int = _orig_counts.get(_tag, 0)
		if _t > _o:
			var _times: int = _t - _o
			for _i in range(_times):
				_diff.extra.append(_tag)

	# Bug fix: detección de cambio de orden. Solo válida cuando los conteos
	# ya coinciden (sin missing/extra) y hay al menos una tag — si no, el
	# usuario está aún arreglando el conteo y avisar del orden sería ruido.
	if _diff.missing.is_empty() and _diff.extra.is_empty() and _diff.has_any_tag:
		var _orig_seq: PackedStringArray = _extract_tag_sequence(_original)
		var _trans_seq: PackedStringArray = _extract_tag_sequence(_translation)
		if _orig_seq != _trans_seq:
			_diff.order_mismatch = true

	_diff.ok = _diff.missing.is_empty() and _diff.extra.is_empty() and not _diff.order_mismatch
	return _diff

# Atajo para validar un IStringContainer entero (sólo capa 0 = content).
static func validate_string(_stri: IStringContainer) -> TagDiff:
	if _stri == null:
		return TagDiff.new()
	return validate(_stri.original_content, _stri.content)
