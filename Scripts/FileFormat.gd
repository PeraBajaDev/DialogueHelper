extends RefCounted
class_name FileFormat

static func parse_line(line: String) -> IFormatEntry:
	var index := 0
	var last_entry := 0
	var got_name := false
	var name := ""
	var format_entry := IFormatEntry.new()

	for user_char: String in line:
		if user_char == &":" && !got_name: # Entry Start
			name = line.substr(last_entry, index - last_entry)
			got_name = true
			last_entry = index + 1
		elif user_char == &";" || index == line.length() - 1: # Entry End
			# Bug fix: cuando estamos en el último char de la línea y NO es ";",
			# ese char forma parte del valor (o del kind). Antes, en el branch
			# `if !got_name` no se incluía y `int(substr(0, 0))` = 0 en lugar
			# del valor real. P.ej. una línea de un solo char "9" devolvía
			# kind=0 en vez de kind=9.
			# Solución: calcular `end` una vez (ajustado si hace falta) y
			# usarlo en ambos branches del if/else.
			var end := index
			if index == line.length() - 1 && user_char != &";":
				end += 1
			if !got_name:
				format_entry.kind = int(line.substr(last_entry, end - last_entry))
				last_entry = index + 1
			else:
				# proteger "+" antes de decodificar (compatibilidad hacia atrás
				# con archivos guardados antes de que se escapara `+` al guardar)
				var raw := line.substr(last_entry, end - last_entry)
				raw = raw.replace("+", "%2B")
				format_entry.data[name] = raw.uri_decode()
				last_entry = index + 1
				got_name = false
		index += 1
	# Compatibilidad/robustez: un campo con valor vacío al final de línea
	# (`NeedsReview:`) deja `got_name` activo y, sin esta pasada final, se
	# pierde al cargar. Los campos vacíos en medio (`Key:;Next:...`) ya se
	# procesan en el branch del `;`; esto cubre sólo el último campo.
	if got_name:
		format_entry.data[name] = ""
	return format_entry

static func parse_file(data: String) -> Array:
	var array := []
	for line in data.replace(&"\r", &"").split(&"\n"):
		# Las líneas vacías (p.ej. el \n final que algunos exportadores
		# escriben tras el marcador 8;) se saltan silenciosamente. No son
		# entradas malformadas: simplemente no son nada.
		if line.is_empty():
			continue
		array.append(parse_line(line))
	return array
