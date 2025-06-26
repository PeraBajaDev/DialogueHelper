using System.Collections.Generic;
using JetBrains.Annotations;

namespace DialogueHelper.StylesParser;

[UsedImplicitly]
public class BoxMetadata
{
    [UsedImplicitly] public required string Name;
    [UsedImplicitly] public required List<ImageMetadata> Images;
    public float Scale = 1.0f;
    public Dictionary<string, dynamic> CustomProperties = [];
    // ReSharper disable once FieldCanBeMadeReadOnly.Global
    public float[] TextOffset = [0.0f, 0.0f];
}

[UsedImplicitly]
public class ImageMetadata
{
    // ReSharper disable once UnassignedField.Global
    public required string Path;
    // ReSharper disable once FieldCanBeMadeReadOnly.Global
    public float[] Position = [0.0f, 0.0f];
    public float[] Scale = [1.0f, 1.0f];
}
