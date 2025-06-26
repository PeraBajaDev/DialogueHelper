using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using JetBrains.Annotations;

namespace DialogueHelper.StylesParser;

public class FontMetadata
{
    public readonly string Name;
    public readonly string ImagePath;
    public readonly double Scale;
    public readonly double Size;
    public readonly double Ascender;
    public readonly double AscenderOffset;
    public readonly List<GlyphMetadata> Glyphs;
    public readonly Dictionary<char, GlyphMetadata> GlyphDictionary;

    public FontMetadata(FontMetadataJson font)
    {
        Name = font.Name;
        ImagePath = font.ImagePath;
        Scale = font.Scale;
        Size = font.Size;
        Ascender = font.Ascender;
        AscenderOffset = font.AscenderOffset;
        Glyphs = [];
        foreach (var glyph in font.Glyphs)
        {
            Glyphs.Add(new()
            {
                Char = glyph.Char,
                Kerning = glyph.Kerning,
                Offset = glyph.Offset,
                Position = (glyph.Position[0], glyph.Position[1]),
                Shift = glyph.Shift,
                Size = (glyph.Size[0], glyph.Size[1]),
            });
        }
        GlyphDictionary = [];
        foreach (var glyph in Glyphs)
            GlyphDictionary.Add(glyph.Char, glyph);
    }
}

public class GlyphMetadata
{
    public required char Char;
    public required (double, double) Position;
    public required (double, double) Size;
    public required double Shift;
    public required double Offset;
    public List<KerningMetadata> Kerning = [];
}

[UsedImplicitly]
[SuppressMessage("ReSharper", "FieldCanBeMadeReadOnly.Global")]
public class FontMetadataJson
{
    [UsedImplicitly] public required string Name;
    [UsedImplicitly] public required string ImagePath;
    public double Scale = 1.0;
    public double Size = 10.0;
    public double Ascender = 10.0;
    public double AscenderOffset = 0.0;
    [UsedImplicitly] public required List<GlyphMetadataJson> Glyphs;
}

[UsedImplicitly]
public class GlyphMetadataJson
{
    [UsedImplicitly] public required char Char;
    [UsedImplicitly] public required double[] Position;
    [UsedImplicitly] public required double[] Size;
    [UsedImplicitly] public required double Shift;
    [UsedImplicitly] public required double Offset;
    [UsedImplicitly] public List<KerningMetadata> Kerning = [];
}

[UsedImplicitly]
public class KerningMetadata
{
    public required char PrecedingChar;
    public required double ShiftModifier;
}
