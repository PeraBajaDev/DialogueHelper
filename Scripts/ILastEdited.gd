extends RefCounted
class_name ILastEdited

var timestamp := -1
var author := ""

func _init(json: Variant = null, local_timestamp: Variant = null, author_name: Variant = null) -> void:
	if json is Dictionary:
		var json_data: Dictionary = json
		if json_data.has(&"Timestamp"):
			timestamp = json_data.Timestamp as int
		if json_data.has(&"Author"):
			author = str(json_data.Author)
	elif json is String:
		var data := str(json).split(&",")
		author = data[0].uri_decode()
		timestamp = int(data[1])
	elif local_timestamp is int && author_name is String:
		timestamp = local_timestamp
		author = author_name

func _to_string() -> String:
	return "%s,%s" % [author.uri_encode(), str(int(timestamp))]
