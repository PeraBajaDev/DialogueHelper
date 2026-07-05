extends RefCounted
class_name IGit

var url := ""
var branch := ""

func global_path(_path: String) -> String:
	return ProjectSettings.globalize_path("user://" + _path)

# Bug fix (inyección de shell):
# Antes esta función construía un string `git ... && git ...` y lo pasaba a
# `cmd.exe /c` o `/bin/sh -c`. Si la URL o el branch (o el mensaje de commit
# en un futuro) contenían comillas, `;`, `$(...)`, backticks o saltos de línea,
# eso era ejecución arbitraria de comandos en la máquina del usuario.
#
# Ahora llamamos directamente al binario `git` con los argumentos como
# `PackedStringArray`. OS.execute pasa los argumentos al proceso sin shell
# de por medio, por lo que ningún caracter especial se interpreta.
#
# Para conservar la semántica del antiguo `&&` (ejecutar el siguiente sólo si
# el anterior tuvo éxito) usamos el helper _run_git_chain.
func _run_git(_args: Array, _show_console: bool = false) -> IGitResponse:
	var _out: Array = []
	var _exit_code: int = OS.execute("git", PackedStringArray(_args), _out, false, _show_console)
	var _r := IGitResponse.new()
	_r.output = PackedStringArray(_out)
	print("Output:")
	for _line: String in _out:
		print(_line)
	print("=======")
	# Mantenemos el mismo criterio de éxito que la versión anterior: el comando
	# se considera fallido si exit != 0 o si alguna línea empieza por error/fatal.
	if _exit_code != 0:
		_r.success = false
	else:
		for _line: String in _out:
			if _line.begins_with("error:") or _line.begins_with("fatal:"):
				_r.success = false
				break
	return _r

# Ejecuta una lista de invocaciones a git en orden. Si una falla, aborta y
# devuelve el resultado fallido (con la salida acumulada hasta ese punto).
func _run_git_chain(_chain: Array, _show_console: bool = false) -> IGitResponse:
	var _accum_output: Array = []
	var _last: IGitResponse = null
	for _args: Array in _chain:
		_last = _run_git(_args, _show_console)
		for _l: String in _last.output:
			_accum_output.append(_l)
		if not _last.success:
			_last.output = PackedStringArray(_accum_output)
			return _last
	if _last == null:
		_last = IGitResponse.new()
	_last.output = PackedStringArray(_accum_output)
	return _last

func clone() -> IGitResponse:
	return _run_git([
		"-C", global_path(""),
		"clone",
		"--branch", branch,
		"--",          # blindaje: lo que viene después es URL/destino, no flags.
		url,
		global_path("repo/"),
	], true)

func pull() -> IGitResponse:
	return _run_git_chain([
		["-C", global_path("repo/"), "restore", "."],
		["-C", global_path("repo/"), "checkout", branch],
		["-C", global_path("repo/"), "pull", "-f"],
	])

func commit(_message: String) -> IGitResponse:
	return _run_git_chain([
		["-C", global_path("repo/"), "add", "."],
		# `-m` con un solo argumento posterior: git lo trata como mensaje literal
		# y no lo pasa por ningún shell. Comillas/backticks/saltos quedan inertes.
		["-C", global_path("repo/"), "commit", "-m", _message],
		["-C", global_path("repo/"), "push", "origin", branch],
	])

func set_url() -> IGitResponse:
	return _run_git([
		"-C", global_path("repo/"),
		"remote", "set-url", "origin",
		"--",
		url,
	])
