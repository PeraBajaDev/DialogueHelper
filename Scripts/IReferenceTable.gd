extends RefCounted
class_name IReferenceTable

# Lightweight CSV-backed reference table for translation notes.
# Expected columns (Google Sheets export):
#   Categoría/Clave, Notas, Español (desde el inglés), Español (desde el japonés)
# Extra columns are ignored.

var entries: Dictionary = {}
var source_path: String = ""
var last_error: String = ""
var header_row_index: int = -1

const FIELD_NOTES := &"notes"
const FIELD_ES_FROM_EN := &"es_from_en"
const FIELD_ES_FROM_JP := &"es_from_jp"

func clear() -> void:
	entries.clear()
	source_path = ""
	last_error = ""
	header_row_index = -1

func load_from_csv(_path: String) -> bool:
	clear()
	if not FileAccess.file_exists(_path):
		last_error = "Reference CSV does not exist:\n%s" % _path
		return false
	var _f := FileAccess.open(_path, FileAccess.READ)
	if _f == null:
		last_error = "Could not open reference CSV (error %d):\n%s" % [FileAccess.get_open_error(), _path]
		return false
	var _text := _f.get_as_text()
	_f.close()
	var _rows: Array = _parse_csv(_text)
	if last_error != "":
		# _parse_csv only fills last_error for malformed quoted data.
		return false
	if _rows.is_empty():
		last_error = "Reference CSV is empty:\n%s" % _path
		return false

	var _cols: Dictionary = _find_columns(_rows)
	var _key_col: int = _dict_int(_cols, "key")
	var _notes_col: int = _dict_int(_cols, "notes")
	var _es_from_en_col: int = _dict_int(_cols, "es_from_en")
	var _es_from_jp_col: int = _dict_int(_cols, "es_from_jp")
	if _key_col == -1:
		last_error = "Could not find a 'Categoría/Clave' column in the reference CSV."
		return false
	if _notes_col == -1 and _es_from_en_col == -1 and _es_from_jp_col == -1:
		last_error = "Reference CSV was found, but it does not contain Notes / ES from EN / ES from JP columns."
		return false

	for _i in range(header_row_index + 1, _rows.size()):
		var _row: Array = _rows[_i]
		var _key := _cell(_row, _key_col).strip_edges()
		if _key == "":
			continue
		var _notes := _cell(_row, _notes_col).strip_edges()
		var _en := _cell(_row, _es_from_en_col).strip_edges()
		var _jp := _cell(_row, _es_from_jp_col).strip_edges()
		# Category rows often have a key but no useful reference fields.
		if _notes == "" and _en == "" and _jp == "":
			continue
		entries[_key] = {
			FIELD_NOTES: _notes,
			FIELD_ES_FROM_EN: _en,
			FIELD_ES_FROM_JP: _jp,
		}

	source_path = _path
	last_error = ""
	return true

func get_reference(_clave: String) -> Dictionary:
	if _clave == "" or not entries.has(_clave):
		return {}
	return entries[_clave]

func has_reference(_clave: String) -> bool:
	return _clave != "" and entries.has(_clave)

func loaded_count() -> int:
	return entries.size()


func _dict_int(_dict: Dictionary, _key: String, _default: int = -1) -> int:
	# `_find_columns()` only stores integers, but Dictionary.get() returns Variant.
	# Use an explicit cast so Godot's static analyzer does not warn about
	# passing a Variant to int().
	return _dict.get(_key, _default) as int

func _find_columns(_rows: Array) -> Dictionary:
	var _cols := {
		"key": -1,
		"notes": -1,
		"es_from_en": -1,
		"es_from_jp": -1,
	}
	header_row_index = -1
	for _r in range(_rows.size()):
		var _row: Array = _rows[_r]
		for _c in range(_row.size()):
			var _h := str(_row[_c]).strip_edges()
			if _is_key_header(_h):
				_cols["key"] = _c
				header_row_index = _r
				break
		if header_row_index != -1:
			break
	if header_row_index == -1:
		return _cols

	var _header: Array = _rows[header_row_index]
	for _c in range(_header.size()):
		var _h := str(_header[_c]).strip_edges()
		if _is_notes_header(_h):
			_cols["notes"] = _c
		elif _is_es_from_en_header(_h):
			_cols["es_from_en"] = _c
		elif _is_es_from_jp_header(_h):
			_cols["es_from_jp"] = _c
	return _cols

func _is_key_header(_h: String) -> bool:
	return _h == "Categoría/Clave" or _h == "Categoria/Clave" or _h == "Clave" or _h.findn("clave") != -1

func _is_notes_header(_h: String) -> bool:
	return _h.findn("notas") != -1 or _h.findn("notes") != -1

func _is_es_from_en_header(_h: String) -> bool:
	return _h.findn("desde") != -1 and (_h.findn("inglés") != -1 or _h.findn("ingles") != -1 or _h.findn("english") != -1)

func _is_es_from_jp_header(_h: String) -> bool:
	return _h.findn("desde") != -1 and (_h.findn("japonés") != -1 or _h.findn("japones") != -1 or _h.findn("japanese") != -1)

func _cell(_row: Array, _idx: int) -> String:
	if _idx < 0 or _idx >= _row.size():
		return ""
	return str(_row[_idx])

# Minimal RFC4180-style parser: supports quoted cells, doubled quotes and
# newlines inside quoted cells. This matters because Google Sheets exports some
# dialogue/reference cells with embedded line breaks.
func _parse_csv(_text: String) -> Array:
	var _rows: Array = []
	var _row: Array[String] = []
	var _cell_text := ""
	var _in_quotes := false
	var _i := 0
	while _i < _text.length():
		var _ch := _text.substr(_i, 1)
		if _in_quotes:
			if _ch == "\"":
				if _i + 1 < _text.length() and _text.substr(_i + 1, 1) == "\"":
					_cell_text += "\""
					_i += 1
				else:
					_in_quotes = false
			else:
				_cell_text += _ch
		else:
			if _ch == "\"":
				_in_quotes = true
			elif _ch == ",":
				_row.append(_cell_text)
				_cell_text = ""
			elif _ch == "\n":
				_row.append(_cell_text)
				_rows.append(_row)
				_row = []
				_cell_text = ""
			elif _ch == "\r":
				_row.append(_cell_text)
				_rows.append(_row)
				_row = []
				_cell_text = ""
				if _i + 1 < _text.length() and _text.substr(_i + 1, 1) == "\n":
					_i += 1
			else:
				_cell_text += _ch
		_i += 1
	if _in_quotes:
		last_error = "Malformed reference CSV: a quoted cell was not closed."
		return []
	if _cell_text != "" or !_row.is_empty():
		_row.append(_cell_text)
		_rows.append(_row)
	return _rows
