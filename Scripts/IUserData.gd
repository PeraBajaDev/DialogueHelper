extends RefCounted
class_name IUserData

var env: Dictionary = {}
var global_env: Dictionary = {}
var font := IFont.new()
var glyph := IUserGlyph.new()

var user_char := IUserChar.new()
var box := IBox.new()
var queue_update_secs := -1.0

var __parent: Control = null

func load_texture(path: String) -> Texture2D:
	var texture: Texture2D = null
	path = Handle.style_get_path(path)
	if FileAccess.file_exists(path):
		texture = load(path) if OS.has_feature("editor") else ImageTexture.create_from_image(Image.load_from_file(path))
	return texture

func draw_glyph() -> void:
	# La fuente no tiene un glyph propio para TAB (se dibuja con el glyph de
	# espacio, como ya hace Script.gd al calcular anchos y posiciones). Si se
	# indexa font.glyphs directamente con "\t" el Dictionary no tiene esa
	# clave y esto crashea con "Invalid access to property or key".
	var glyph_char: String = " " if user_char.character == "\t" else user_char.character
	__parent.draw_texture_rect_region(font.texture, user_char.glyph, (font.glyphs[glyph_char] as IGlyph).rect, glyph.color)
	if user_char.glyph.position.x + user_char.glyph.size.x + 20 > __parent.custom_minimum_size.x:
		__parent.custom_minimum_size.x = user_char.glyph.position.x + user_char.glyph.size.x + 20
	if user_char.glyph.position.y + user_char.glyph.size.y + 20 > __parent.custom_minimum_size.y:
		__parent.custom_minimum_size.y = user_char.glyph.position.y + user_char.glyph.size.y + 20

func draw_texture(texture: Texture2D, position: Vector2, modulate: Color = Color.WHITE) -> void:
	__parent.draw_texture(texture, position, modulate)
	if position.x + texture.get_width() + 20 > __parent.custom_minimum_size.x:
		__parent.custom_minimum_size.x = position.x + texture.get_width() + 20
	if position.y + texture.get_height() + 20 > __parent.custom_minimum_size.y:
		__parent.custom_minimum_size.y = position.y + texture.get_height() + 20

func draw_texture_rect(texture: Texture2D, rect: Rect2, tile: bool, modulate: Color = Color.WHITE, transpose := false) -> void:
	__parent.draw_texture_rect(texture, rect, tile, modulate, transpose)
	if rect.position.x + rect.size.x + 20 > __parent.custom_minimum_size.x:
		__parent.custom_minimum_size.x = rect.position.x + rect.size.x + 20
	if rect.position.y + rect.size.y + 20 > __parent.custom_minimum_size.y:
		__parent.custom_minimum_size.y = rect.position.y + rect.size.y + 20

func draw_texture_rect_region(texture: Texture2D, rect: Rect2, src_rect: Rect2, modulate: Color = Color.WHITE, transpose := false, clip_uv := true) -> void:
	__parent.draw_texture_rect_region(texture, rect, src_rect, modulate, transpose, clip_uv)
	if rect.position.x + rect.size.x + 20 > __parent.custom_minimum_size.x:
		__parent.custom_minimum_size.x = rect.position.x + rect.size.x + 20
	if rect.position.y + rect.size.y + 20 > __parent.custom_minimum_size.y:
		__parent.custom_minimum_size.y = rect.position.y + rect.size.y + 20

func set_current_box(box_id: int) -> void:
	Handle.main_node.update_box(box_id, false)

func set_current_font(font_id: int) -> void:
	Handle.main_node.update_font(font_id, false)

func set_viewing_scale(scale: float) -> void:
	Handle.main_node.current_scale_node.value = scale

func get_current_box() -> int:
	return Handle.main_node.current_box

func get_current_font() -> int:
	return Handle.main_node.current_font_id

func get_viewing_scale() -> float:
	return Handle.main_node.current_scale_node.value

func set_box_button_enabled(enabled: bool) -> void:
	Handle.main_node.current_box_node.editable = enabled

func set_font_button_enabled(enabled: bool) -> void:
	Handle.main_node.current_font_node.editable = enabled

func set_box_portrait(enabled: bool) -> void:
	Handle.main_node.box.portrait_enabled = enabled
	Handle.main_node.enable_portrait.button_pressed = enabled

func get_box_portrait() -> bool:
	return Handle.main_node.box.portrait_enabled && Handle.main_node.box.supports_portrait

func get_box_supports_portrait() -> bool:
	return Handle.main_node.box.supports_portrait

func get_box_button_enabled() -> bool:
	return Handle.main_node.current_box_node.editable

func get_font_button_enabled() -> bool:
	return Handle.main_node.current_font_node.editable

func get_font(font_index: int) -> IFont:
	return Handle.font_data[font_index]

func get_box(box_index: int) -> IBox:
	return Handle.box_data[box_index]
