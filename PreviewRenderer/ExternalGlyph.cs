using SixLabors.ImageSharp;

namespace DialogueHelper.PreviewRenderer;

public class ExternalGlyph
{
    public (double, double) Scale = (1.0, 1.0);
    public Color Color = Color.White;
    // ReSharper disable once FieldCanBeMadeReadOnly.Global
    // ReSharper disable once ConvertToConstant.Global
    public double Alpha = 1.0;
    public (double, double) Position = (0.0f, 0.0f);
    public (double, double) Size = (0.0, 0.0);
}
