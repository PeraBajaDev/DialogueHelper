extends RefCounted
class_name IBox

var name := ""
var texture: Texture2D = null

var scale := 1.0
var supports_portrait := false

var dialogue_offset := Vector2.ZERO
var portrait_offset := Vector2.ZERO

func _init(json: Variant = null) -> void:
	if json is Dictionary:
		var json_data: Dictionary = json
		if json_data.has(&"Name"):
			name = str(json_data.Name)
		if json_data.has(&"Texture"):
			var path := Handle.style_get_path("Boxes/%s" % json_data.Texture)
			if FileAccess.file_exists(path):
				texture = load(path) if OS.has_feature(&"editor") else ImageTexture.create_from_image(Image.load_from_file(path))
		if json_data.has(&"Scale"):
			scale = json_data.Scale as float
		if json_data.has(&"SupportsPortrait"):
			supports_portrait = json_data.SupportsPortrait as bool
		if json_data.has(&"DialogueOffset"):
			var array: Array[int] = []
			array.assign(json_data.DialogueOffset as Array)
			dialogue_offset = Vector2i(array[0], array[1])
		if json_data.has(&"PortraitOffset"):
			var array: Array[int] = []
			array.assign(json_data.PortraitOffset as Array)
			portrait_offset = Vector2i(array[0], array[1])
