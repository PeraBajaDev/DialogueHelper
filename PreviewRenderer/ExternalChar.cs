namespace DialogueHelper.PreviewRenderer;

public class ExternalChar
{
    public required char Char;
    public required int Index;
    public required string String;

    public (double, double) StartPosition = (0.0, 0.0);
    public (double, double) PositionOffset = (0.0, 0.0);

    public required bool IsIgnore;
    public required bool IsNewline;
}
