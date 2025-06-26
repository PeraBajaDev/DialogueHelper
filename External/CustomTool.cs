using System;

namespace DialogueHelper.External;

public class CustomTool(string name, Action<CustomToolWindowHandler> func)
{
    public string Name = name;
    public Action<CustomToolWindowHandler> Func = func;
}
