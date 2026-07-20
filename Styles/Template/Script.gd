extends RefCounted
# Template: GameMaker fonts

# This function will be called for each glyph (user_char)
# in the string, this allows you full control of how
# it gets drawn.
static func draw_glyph(data: IUserData) -> void:
	if data.user_char.is_ignore || (!data.font.glyphs.has(data.user_char.character) && !data.user_char.is_newline):
		return
	var scale := data.glyph.vscale * data.font.scale
	if data.user_char.is_newline:
		data.user_char.position_offset.x = 0
		var size: int = data.font.glyphs["A"].rect.size.y
		data.user_char.position_offset.y += (size + (size % 2) + (data.font.size % 2)) * (data.glyph.vscale * data.font.scale)
	else:
		var glyph: IGlyph = data.font.glyphs[data.user_char.character]
		data.user_char.glyph.position.x = data.user_char.start_position.x + data.user_char.position_offset.x + (glyph.offset * (data.glyph.vscale * data.font.scale))
		data.user_char.glyph.position.y = data.user_char.start_position.y + data.user_char.position_offset.y
		data.user_char.glyph.size.x = glyph.rect.size.x * (data.glyph.vscale * data.font.scale)
		data.user_char.glyph.size.y = glyph.rect.size.y * (data.glyph.vscale * data.font.scale)
		data.draw_glyph()
		if (glyph.shift + (glyph.shift % 2)) / max(glyph.rect.size.x, 1) >= 6:
			data.user_char.position_offset.x += ((glyph.shift - data.font.size) + glyph.offset) * (data.glyph.vscale * data.font.scale)
		else:
			data.user_char.position_offset.x += (glyph.shift + glyph.offset) * (data.glyph.vscale * data.font.scale)
