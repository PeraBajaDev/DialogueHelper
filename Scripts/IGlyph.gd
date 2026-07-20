extends RefCounted
class_name IGlyph


var user_char := ""
var rect := Rect2i(0, 0, 0, 0)
var shift := 0
var offset := 0

func _init(json: Variant = null) -> void:
	if json is Dictionary:
		var json_data: Dictionary = json
		if json_data.has(&"Char"):
			user_char = str(json_data.Char)
		if json_data.has(&"X"):
			rect.position.x = json_data.X as int
		if json_data.has(&"Y"):
			rect.position.y = json_data.Y as int
		if json_data.has(&"Width"):
			rect.size.x = json_data.Width as int
		if json_data.has(&"Height"):
			rect.size.y = json_data.Height as int
		if json_data.has(&"Shift"):
			shift = json_data.Shift as int
		if json_data.has(&"Offset"):
			offset = json_data.Offset as int
