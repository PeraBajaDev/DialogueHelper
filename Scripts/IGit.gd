extends RefCounted
class_name IGit

var url := ""
var branch := ""

func global_path(path: String) -> String:
	return ProjectSettings.globalize_path("user://" + path)

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
func _run_git(args: Array, show_console: bool = false) -> IGitResponse:
	var out: Array = []
	var exit_code: int = OS.execute("git", PackedStringArray(args), out, false, show_console)
	var git_response := IGitResponse.new()
	git_response.output = PackedStringArray(out)
	print("Output:")
	for line: String in out:
		print(line)
	print("=======")
	# Mantenemos el mismo criterio de éxito que la versión anterior: el comando
	# se considera fallido si exit != 0 o si alguna línea empieza por error/fatal.
	if exit_code != 0:
		git_response.success = false
	else:
		for line: String in out:
			if line.begins_with("error:") or line.begins_with("fatal:"):
				git_response.success = false
				break
	return git_response

# Ejecuta una lista de invocaciones a git en orden. Si una falla, aborta y
# devuelve el resultado fallido (con la salida acumulada hasta ese punto).
func _run_git_chain(chain: Array, show_console: bool = false) -> IGitResponse:
	var accumulated_output: Array = []
	var last_response: IGitResponse = null
	for args: Array in chain:
		last_response = _run_git(args, show_console)
		for _l: String in last_response.output:
			accumulated_output.append(_l)
		if not last_response.success:
			last_response.output = PackedStringArray(accumulated_output)
			return last_response
	if last_response == null:
		last_response = IGitResponse.new()
	last_response.output = PackedStringArray(accumulated_output)
	return last_response

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

func commit(message: String) -> IGitResponse:
	return _run_git_chain([
		["-C", global_path("repo/"), "add", "."],
		# `-m` con un solo argumento posterior: git lo trata como mensaje literal
		# y no lo pasa por ningún shell. Comillas/backticks/saltos quedan inertes.
		["-C", global_path("repo/"), "commit", "-m", message],
		["-C", global_path("repo/"), "push", "origin", branch],
	])

func set_url() -> IGitResponse:
	return _run_git([
		"-C", global_path("repo/"),
		"remote", "set-url", "origin",
		"--",
		url,
	])
