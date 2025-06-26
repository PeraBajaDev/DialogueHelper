using Avalonia.Controls;
using Avalonia.Interactivity;

namespace DialogueHelper.Views;

public partial class AboutDialogueHelper : Window
{
    public AboutDialogueHelper()
    {
        InitializeComponent();
    }

    void Close_OnClick(object? sender, RoutedEventArgs e)
    {
        Close();
    }
}
