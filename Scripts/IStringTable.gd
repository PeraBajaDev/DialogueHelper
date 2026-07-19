extends RefCounted
class_name IStringTable

var name := ""
var entry := ""
var index := -1
var data: IStringContainer = null

func _init(local_name := "", local_entry := "", local_index := -1, local_data: IStringContainer = null) -> void:
	name = local_name
	entry = local_entry
	index = local_index
	data = local_data

func to_json() -> Dictionary:
	return {
		"Name": name,
		"Entry": entry,
		"Index": index,
	}

func _to_string() -> String:
	return JSON.stringify(to_json(), "", false)
