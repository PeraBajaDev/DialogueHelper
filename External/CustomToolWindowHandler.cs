using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Platform.Storage;
using DialogueHelper.FileFormat;
using DialogueHelper.StylesParser;

namespace DialogueHelper.External;

public class CustomToolWindowHandler(MainWindow mainWindow, StyleParser style)
{
    readonly MainWindow _mainWindow = mainWindow;
    readonly StyleParser _style = style;

    public IStorageProvider GetStorageProvider()
    {
        return _mainWindow.StorageProvider;
    }
    
    public void Show(Window window)
    {
        window.Show(_mainWindow);
    }
    
    public async Task ShowDialog(Window window)
    {
        await window.ShowDialog(_mainWindow);
    }
    
    public async Task<T> ShowDialog<T>(Window window)
    {
        return await window.ShowDialog<T>(_mainWindow);
    }

    public string GetStylePath()
    {
        return _style.Folder;
    }

    public FileData? GetLoadedFileData()
    {
        return _mainWindow.FileData;
    }
    
    public void LoadFile(string data)
    {
        
    }
}
