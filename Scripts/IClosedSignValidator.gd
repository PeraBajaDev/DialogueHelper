extends RefCounted
class_name IClosedSignValidator

#No soy un bot bipbup
# Realmente era necesario hacer todo con IA.
# Es un chingo de comentarios y
# la estructura del código no tiene mucho sentido XD
# Me llamo pera, por cierto.

## Esto define si el texto tiene los signos de
## apertura y cierrre
static func _has_been_closed_correctly(text: String, open_symbol: String, close_symbol: String) -> bool:
	var stack: Array = []
	for user_char in text:
		if user_char == open_symbol:
			stack.push_back(user_char)
		elif user_char == close_symbol and len(stack) == 0:
			return false
		elif user_char == close_symbol:
			stack.pop_back()
	return len(stack) == 0

class ValidCloseSign extends RefCounted:
	var ok: bool = false
	var missing: = ""
	var has_any_sign: bool

	func to_label_text() -> String:
		if ok:
			return "✓ Signos OK"
		var parts := ""
		if not missing.is_empty():
			parts = "Falta cerrar: " + missing
		return "⚠ " + "  ·  " + parts

static func validate_string(string: IStringContainer) -> ValidCloseSign:
	var valid_close_sign := ValidCloseSign.new()

	if string == null:
		return valid_close_sign

	if not _has_been_closed_correctly(string.content, "¿" ,"?"):
		valid_close_sign.missing = "¿ ?"
	elif not _has_been_closed_correctly(string.content, "¡" ,"!"):
		valid_close_sign.missing = "¡ !"
	elif not _has_been_closed_correctly(string.content, "(" ,")"):
		valid_close_sign.missing = "( )"
	else:
		valid_close_sign.ok = true
	for c in "¿?¡!()":
		valid_close_sign.has_any_sign = string.content.contains(c)
		if valid_close_sign.has_any_sign: break
	return valid_close_sign
