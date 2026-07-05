extends RefCounted
class_name IFormatEntry

var kind := -1
var data := {}
var disable_uri := []

func _to_string() -> String:
	var _str := ""
	for key: Variant in data.keys():
		var value := str(data[key])
		if !_str.is_empty():
			_str += ";"
		if !disable_uri.has(key):
			# Bug fix: antes esta lista NO incluía "+". Como String.uri_decode()
			# en Godot interpreta "+" como espacio (legado de form-urlencoded),
			# un valor con "+" literal se cargaba como espacio. El parser tenía
			# un workaround (`raw.replace("+", "%2B")` antes de uri_decode), pero
			# la asimetría era frágil. Ahora escapamos "+" también aquí.
			# El workaround del parser se mantiene a propósito por compatibilidad
			# hacia atrás: archivos guardados con la versión vieja contienen "+"
			# literales y deben seguir cargándose correctamente.
			for ad: Array in [
				[&"%", &"%25"],
				[&";", &"%3B"],
				[&":", &"%3A"],
				[&"\n", &"%0A"],
				[&"\r", &"%0D"],
				[&"+", &"%2B"],
			]:
				value = value.replace(str(ad[0]), str(ad[1]))
		_str += "%s:%s" % [key, value]
	return "%s;%s" % [kind, _str]
