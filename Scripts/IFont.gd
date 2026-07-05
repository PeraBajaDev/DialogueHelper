extends RefCounted
class_name IFont

# Placeholders PUA (U+E000..) para representar chars escapados con ` (backtick).
# Un `X en el texto fuente significa "dibuja X literal, no lo interpretes como
# secuencia de control". BoxHandler mapea cada char "peligroso" a uno de estos
# code-points de uso privado; el script del estilo ve el placeholder y NO dispara
# sus ramas especiales, y luego en el draw loop se rehidrata al char original.
# Viven aquí (la clase de fuente, sin dependencias) para ser única fuente de
# verdad sin crear ciclos entre clases: tanto BoxHandler como _register_escape_aliases
# los consumen.
const ESCAPE_PLACEHOLDERS: Dictionary[String, String] = {
	"&":  "\uE000",
	"%":  "\uE001",
	"/":  "\uE002",
	"^":  "\uE003",
	"\\": "\uE004",
	"`":  "\uE005",
	"#":  "\uE006",
}
const PLACEHOLDER_TO_CHAR: Dictionary[String, String] = {
	"\uE000": "&",
	"\uE001": "%",
	"\uE002": "/",
	"\uE003": "^",
	"\uE004": "\\",
	"\uE005": "`",
	"\uE006": "#",
}

var name := ""
var glyphs := {}
var texture: Texture2D = null

var size := 0
var ascender := 0
var ascender_offset := 0
var scale := 1.0

func _init(_json: Variant = null) -> void:
	if _json is Dictionary:
		var _jd: Dictionary = _json
		if _jd.has(&"Name"):
			name = str(_jd.Name)
		if _jd.has(&"Texture"):
			var path := str(Handle.style_get_path("Fonts/%s" % _jd.Texture))
			if FileAccess.file_exists(path):
				texture = load(path) if OS.has_feature("editor") else ImageTexture.create_from_image(Image.load_from_file(path))
		if _jd.has(&"Size"):
			size = _jd.Size as int
		if _jd.has(&"Scale"):
			scale = _jd.Scale as float
		if _jd.has(&"Ascender"):
			ascender = _jd.Ascender as int
		if _jd.has(&"AscenderOffset"):
			ascender_offset = _jd.AscenderOffset as int
		if _jd.has(&"Glyphs"):
			for glyph: Dictionary in _jd.Glyphs:
				if glyph.has(&"Char"):
					glyphs[str(glyph.Char)] = IGlyph.new(glyph)
		_register_escape_aliases()

# Un `X (backtick-escape; p. ej. `%) debe RENDERIZARSE como el carácter literal X.
# Para que el script del estilo no interprete esa X como secuencia de control,
# BoxHandler la sustituye internamente por un placeholder de uso privado
# (U+E000..; también `#`, porque # es salto de línea en varios styles).
# El problema: ese placeholder NO tenía glifo en la fuente, así que
# la medición de ancho que decide el salto de línea lo contaba como 0 px y la
# línea no saltaba donde debía (el caso de "300`%": el % escapado no sumaba
# ancho y se salía del cuadro). Solución: registrar cada placeholder como ALIAS
# del glifo de su carácter literal. Así el placeholder "tiene glifo" y mide
# exactamente igual que el char real en cualquier lookup (incluida la medición
# del wrap), mientras que el dibujo sigue usando char.char ya rehidratado.
func _register_escape_aliases() -> void:
	for _orig: String in ESCAPE_PLACEHOLDERS:
		var _placeholder: String = ESCAPE_PLACEHOLDERS[_orig]
		if glyphs.has(_orig):
			glyphs[_placeholder] = glyphs[_orig]

static func get_font(_index: int) -> IFont:
	if _index >= Handle.font_data.size() || _index < 0:
		return null
	return Handle.font_data[_index]
