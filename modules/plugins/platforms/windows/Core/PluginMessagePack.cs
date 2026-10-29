using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json.Serialization;
using Miucs.Keyboard;
namespace Miucs.Plugins;

/// Binary contract writer. Reflection metadata is cached; there is no JSON serialization in the frame path.
public static class PluginMessagePack
{
    private static readonly ConcurrentDictionary<Type, PropertyInfo[]> Properties = new();
    public static byte[] Encode(object? value)
    {
        using var stream = new MemoryStream(4096);
        void Number(ulong number, int count) { for (int i=count-1;i>=0;i--) stream.WriteByte((byte)(number>>(i*8))); }
        void Write(object? item)
        {
            if(item==null) { stream.WriteByte(0xc0); return; }
            switch(item)
            {
                case bool b: stream.WriteByte(b?(byte)0xc3:(byte)0xc2); return;
                case string text:
                    byte[] utf8=Encoding.UTF8.GetBytes(text);stream.WriteByte(0xdb);Number((ulong)utf8.Length,4);stream.Write(utf8);return;
                case Guid guid: Write(guid.ToString().ToUpperInvariant());return;
                case KeyboardModifiers modifiers: stream.WriteByte(0xcf);Number((ulong)modifiers,8);return;
                case Enum state: string name=state.ToString();Write(char.ToLowerInvariant(name[0])+name.Substring(1));return;
                case double d: stream.WriteByte(0xcb);Number((ulong)BitConverter.DoubleToInt64Bits(double.IsFinite(d)?d:0),8);return;
                case float f: Write((double)f);return;
                case byte or ushort or uint or ulong: stream.WriteByte(0xcf);Number(Convert.ToUInt64(item),8);return;
                case sbyte or short or int or long: stream.WriteByte(0xd3);Number(unchecked((ulong)Convert.ToInt64(item)),8);return;
                case IDictionary dictionary:
                    stream.WriteByte(0xdf);Number((ulong)dictionary.Count,4);foreach(DictionaryEntry entry in dictionary){Write(entry.Key);Write(entry.Value);}return;
                case IEnumerable sequence:
                    var values=new List<object?>();foreach(var v in sequence)values.Add(v);stream.WriteByte(0xdd);Number((ulong)values.Count,4);foreach(var v in values)Write(v);return;
            }
            var properties=Properties.GetOrAdd(item.GetType(),type=>Array.FindAll(type.GetProperties(),p=>p.CanRead&&p.GetIndexParameters().Length==0&&p.GetCustomAttribute<JsonIgnoreAttribute>()==null));
            stream.WriteByte(0xdf);Number((ulong)properties.Length,4);
            foreach(var property in properties)
            {
                if(property.Name=="KeyCode") { Write("key");Write(PhysicalKeys.Name((ushort)property.GetValue(item)!));continue; }
                string name=property.GetCustomAttribute<JsonPropertyNameAttribute>()?.Name ?? (property.Name=="SessionId"?"sessionID":char.ToLowerInvariant(property.Name[0])+property.Name.Substring(1));
                Write(name);Write(property.GetValue(item));
            }
        }
        Write(value);return stream.ToArray();
    }
}
