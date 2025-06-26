using System.Text;
using System.Text.Json;
using System;
using System.IO;
using System.Text.Encodings.Web;
using System.Threading;
using System.Threading.Tasks;
using UndertaleModLib.Util;
using System.Windows.Forms;
using UndertaleModLib.Models;
using static System.Windows.Forms.FileDialog;
using UndertaleModLib;
using UndertaleModLib.Decompiler;

var bjson = File.ReadAllText(FilePath + "\\..\\lang\\lang_es.json");
var jdata = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(bjson, new JsonSerializerOptions());
if (jdata.ContainsKey("date"))
    jdata.Remove("date");

foreach (var code in Data.Code)
{
    if (code.ParentEntry is null)
    {
        bool lastExists = false;
        string entry = "";

        foreach (var instruction in code.Instructions)
        {
            if (UndertaleInstruction.GetInstructionType(instruction.Kind) == UndertaleInstruction.InstructionType.PushInstruction && instruction.Type1 == UndertaleInstruction.DataType.String)
            {
                var c = ((UndertaleString)(instruction.ValueString).Resource).Content;
                if (!lastExists)
                {
                    //ScriptMessage(c);
                    if (jdata.ContainsKey(c))
                    {
                        //ScriptMessage(c);
                        lastExists = true;
                        entry = c;
                    }
                }
                else
                {
                    lastExists = false;
                    ((UndertaleString)(instruction.ValueString).Resource).Content = jdata[entry].GetString();
                }
            }
        }
    }
}

ScriptMessage("Finished!");
