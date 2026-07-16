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

func load_from_csv(path: String) -> bool:
	clear()
	if not FileAccess.file_exists(path):
		last_error = "Reference CSV does not exist:\n%s" % path
		return false
	var csv_file := FileAccess.open(path, FileAccess.READ)
	if csv_file == null:
		last_error = "Could not open reference CSV (error %d):\n%s" % [FileAccess.get_open_error(), path]
		return false
	var text := csv_file.get_as_text()
	csv_file.close()
	var rows: Array = _parse_csv(text)
	if last_error != "":
		# _parse_csv only fills last_error for malformed quoted data.
		return false
	if rows.is_empty():
		last_error = "Reference CSV is empty:\n%s" % path
		return false

	var cols: Dictionary = _find_columns(rows)
	var key_col: int = _dict_int(cols, "key")
	var notes_col: int = _dict_int(cols, "notes")
	var es_from_en_col: int = _dict_int(cols, "es_from_en")
	var es_from_jp_col: int = _dict_int(cols, "es_from_jp")
	if key_col == -1:
		last_error = "Could not find a 'Categoría/Clave' column in the reference CSV."
		return false
	if notes_col == -1 and es_from_en_col == -1 and es_from_jp_col == -1:
		last_error = "Reference CSV was found, but it does not contain Notes / ES from EN / ES from JP columns."
		return false

	for i in range(header_row_index + 1, rows.size()):
		var row: Array = rows[i]
		var key := _cell(row, key_col).strip_edges()
		if key == "":
			continue
		var notes := _cell(row, notes_col).strip_edges()
		var en := _cell(row, es_from_en_col).strip_edges()
		var jp := _cell(row, es_from_jp_col).strip_edges()
		# Category rows often have a key but no useful reference fields.
		if notes == "" and en == "" and jp == "":
			continue
		entries[key] = {
			FIELD_NOTES: notes,
			FIELD_ES_FROM_EN: en,
			FIELD_ES_FROM_JP: jp,
		}

	source_path = path
	last_error = ""
	return true

func get_reference(key: String) -> Dictionary:
	if key == "" or not entries.has(key):
		return {}
	return entries[key]

func has_reference(key: String) -> bool:
	return key != "" and entries.has(key)

func loaded_count() -> int:
	return entries.size()


func _dict_int(dict: Dictionary, key: String, default: int = -1) -> int:
	# `_find_columns()` only stores integers, but Dictionary.get() returns Variant.
	# Use an explicit cast so Godot's static analyzer does not warn about
	# passing a Variant to int().
	return dict.get(key, default) as int

func _find_columns(rows: Array) -> Dictionary:
	var cols := {
		"key": -1,
		"notes": -1,
		"es_from_en": -1,
		"es_from_jp": -1,
	}
	header_row_index = -1
	for i in range(rows.size()):
		var row: Array = rows[i]
		for _c in range(row.size()):
			var header := str(row[_c]).strip_edges()
			if _is_key_header(header):
				cols["key"] = _c
				header_row_index = i
				break
		if header_row_index != -1:
			break
	if header_row_index == -1:
		return cols

	var _header: Array = rows[header_row_index]
	for _c in range(_header.size()):
		var header := str(_header[_c]).strip_edges()
		if _is_notes_header(header):
			cols["notes"] = _c
		elif _is_es_from_en_header(header):
			cols["es_from_en"] = _c
		elif _is_es_from_jp_header(header):
			cols["es_from_jp"] = _c
	return cols

func _is_key_header(header: String) -> bool:
	return header == "Categoría/Clave" or header == "Categoria/Clave" or header == "Clave" or header.findn("clave") != -1

func _is_notes_header(header: String) -> bool:
	return header.findn("notas") != -1 or header.findn("notes") != -1

func _is_es_from_en_header(header: String) -> bool:
	return header.findn("desde") != -1 and (header.findn("inglés") != -1 or header.findn("ingles") != -1 or header.findn("english") != -1)

func _is_es_from_jp_header(header: String) -> bool:
	return header.findn("desde") != -1 and (header.findn("japonés") != -1 or header.findn("japones") != -1 or header.findn("japanese") != -1)

func _cell(row: Array, index: int) -> String:
	if index < 0 or index >= row.size():
		return ""
	return str(row[index])

# Minimal RFC4180-style parser: supports quoted cells, doubled quotes and
# newlines inside quoted cells. This matters because Google Sheets exports some
# dialogue/reference cells with embedded line breaks.
func _parse_csv(text: String) -> Array:
	var rows: Array = []
	var row: Array[String] = []
	var cell_text := ""
	var in_quotes := false
	var i := 0
	while i < text.length():
		var character := text.substr(i, 1)
		if in_quotes:
			if character == "\"":
				if i + 1 < text.length() and text.substr(i + 1, 1) == "\"":
					cell_text += "\""
					i += 1
				else:
					in_quotes = false
			else:
				cell_text += character
		else:
			if character == "\"":
				in_quotes = true
			elif character == ",":
				row.append(cell_text)
				cell_text = ""
			elif character == "\n":
				row.append(cell_text)
				rows.append(row)
				row = []
				cell_text = ""
			elif character == "\r":
				row.append(cell_text)
				rows.append(row)
				row = []
				cell_text = ""
				if i + 1 < text.length() and text.substr(i + 1, 1) == "\n":
					i += 1
			else:
				cell_text += character
		i += 1
	if in_quotes:
		last_error = "Malformed reference CSV: a quoted cell was not closed."
		return []
	if cell_text != "" or !row.is_empty():
		row.append(cell_text)
		rows.append(row)
	return rows
