extends RefCounted
class_name FileFormat

static func parse_line(_line: String) -> IFormatEntry:
	var _index := 0
	var _last_entry := 0
	var _got_name := false
	var _name := ""
	var _fe := IFormatEntry.new()

	for _char: String in _line:
		if _char == &":" && !_got_name: # Entry Start
			_name = _line.substr(_last_entry, _index - _last_entry)
			_got_name = true
			_last_entry = _index + 1
		elif _char == &";" || _index == _line.length() - 1: # Entry End
			# Bug fix: cuando estamos en el último char de la línea y NO es ";",
			# ese char forma parte del valor (o del kind). Antes, en el branch
			# `if !_got_name` no se incluía y `int(substr(0, 0))` = 0 en lugar
			# del valor real. P.ej. una línea de un solo char "9" devolvía
			# kind=0 en vez de kind=9.
			# Solución: calcular `_end` una vez (ajustado si hace falta) y
			# usarlo en ambos branches del if/else.
			var _end := _index
			if _index == _line.length() - 1 && _char != &";":
				_end += 1
			if !_got_name:
				_fe.kind = int(_line.substr(_last_entry, _end - _last_entry))
				_last_entry = _index + 1
			else:
				# proteger "+" antes de decodificar (compatibilidad hacia atrás
				# con archivos guardados antes de que se escapara `+` al guardar)
				var raw := _line.substr(_last_entry, _end - _last_entry)
				raw = raw.replace("+", "%2B")
				_fe.data[_name] = raw.uri_decode()
				_last_entry = _index + 1
				_got_name = false
		_index += 1
	# Compatibilidad/robustez: un campo con valor vacío al final de línea
	# (`NeedsReview:`) deja `_got_name` activo y, sin esta pasada final, se
	# pierde al cargar. Los campos vacíos en medio (`Key:;Next:...`) ya se
	# procesan en el branch del `;`; esto cubre sólo el último campo.
	if _got_name:
		_fe.data[_name] = ""
	return _fe

static func parse_file(_data: String) -> Array:
	var _arr := []
	for _line in _data.replace(&"\r", &"").split(&"\n"):
		# Las líneas vacías (p.ej. el \n final que algunos exportadores
		# escriben tras el marcador 8;) se saltan silenciosamente. No son
		# entradas malformadas: simplemente no son nada.
		if _line.is_empty():
			continue
		_arr.append(parse_line(_line))
	return _arr
