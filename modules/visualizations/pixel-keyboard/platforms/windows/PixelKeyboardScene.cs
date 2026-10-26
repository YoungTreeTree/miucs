using System;
using System.Collections.Generic;
using System.Linq;
using Miucs.Keyboard;
namespace Miucs.Visualizations;

/// <summary>Independent keyboard state: no audio reset may release or replay paw input.</summary>
public sealed class PixelKeyboardScene
{
    public sealed record Key(ushort Code, string Label, double X, double Y, double Width)
    { public double CenterX => X + Width / 2; }
    public sealed class Paw
    {
        public ushort Code; public double X, Y, Down;
        public Paw(ushort code) { Code = code; X = Positions[code].CenterX; Y = Positions[code].Y + 15; }
    }
    public static readonly IReadOnlyList<Key> Keys = BuildKeys();
    public static readonly IReadOnlyDictionary<ushort, Key> Positions = Keys.ToDictionary(k => k.Code);
    public Paw Left { get; private set; } = new(33);
    public Paw Right { get; private set; } = new(36);
    public KeyboardState State { get; private set; } = KeyboardState.Stopped;
    private Guid session;
    private long sequence;
    private double elapsed;
    private bool nextSpaceLeft = true;
    private readonly HashSet<ushort> observed = new();
    private readonly Dictionary<ushort, double> flashes = new();
    private static readonly Dictionary<ushort, KeyboardModifiers> Modifiers = new()
    { [42]=KeyboardModifiers.Shift,[54]=KeyboardModifiers.Shift,[29]=KeyboardModifiers.Control,[0x11D]=KeyboardModifiers.Control,
      [56]=KeyboardModifiers.Option,[0x138]=KeyboardModifiers.Option,[0x15B]=KeyboardModifiers.Command,[0x15C]=KeyboardModifiers.Command };
    public bool IsLit(ushort code) => observed.Contains(code) || flashes.ContainsKey(code);
    public void Reset()
    {
        session = Guid.Empty; sequence = 0; elapsed = 0; nextSpaceLeft = true;
        observed.Clear(); flashes.Clear(); Left = new(33); Right = new(36); State = KeyboardState.Stopped;
    }
    public void Update(KeyboardInput input, double dt)
    {
        dt = double.IsFinite(dt) ? Math.Max(0, dt) : 0;
        elapsed += dt;
        foreach (var key in flashes.Keys.ToArray()) if (flashes[key] <= elapsed) flashes.Remove(key);
        if (session != input.SessionId) { Reset(); session = input.SessionId; }
        State = input.State;
        if (State != KeyboardState.Running || input.DroppedEventCount > 0) { observed.Clear(); flashes.Clear(); }
        if (State == KeyboardState.Running)
        {
            foreach (var ev in input.Events.Where(e => e.Sequence > sequence && e.Sequence <= input.Sequence))
            {
                sequence = ev.Sequence;
                double age = input.SampledAt - ev.ReceivedAt;
                if (!double.IsFinite(age) || age < 0 || age > .25 || !Positions.ContainsKey(ev.KeyCode)) continue;
                if (ev.Kind == KeyboardEventKind.Pressed && observed.Add(ev.KeyCode)) Strike(ev.KeyCode);
                else if (ev.Kind == KeyboardEventKind.Released) observed.Remove(ev.KeyCode);
                else if (ev.Kind == KeyboardEventKind.ModifiersChanged)
                {
                    if (ev.KeyCode == 58) Strike(ev.KeyCode);
                    else if (ev.ModifierIsPressed == true) { observed.Add(ev.KeyCode); Strike(ev.KeyCode); }
                    else if (ev.ModifierIsPressed == false) observed.Remove(ev.KeyCode);
                }
            }
            var held = input.HeldKeys.Select(k => k.KeyCode).ToHashSet();
            observed.RemoveWhere(code => Modifiers.TryGetValue(code, out var flag)
                ? (input.Modifiers & flag) == 0 : !held.Contains(code));
        }
        else { Left.Code = 33; Right.Code = 36; }
        sequence = Math.Max(sequence, input.Sequence);
        double a = 1 - Math.Exp(-dt*38);
        foreach (var paw in new[] { Left, Right })
        {
            var key = Positions[paw.Code];
            paw.X += (key.CenterX-paw.X)*a; paw.Y += (key.Y+15-paw.Y)*a;
            paw.Down += ((IsLit(paw.Code)?1:0)-paw.Down)*a;
        }
    }
    private void Strike(ushort code)
    {
        flashes[code] = elapsed + .12;
        bool left = code == 57 ? nextSpaceLeft : Positions[code].CenterX < 400;
        if (code == 57) nextSpaceLeft = !nextSpaceLeft;
        (left ? Left : Right).Code = code;
    }
    private static IReadOnlyList<Key> BuildKeys()
    {
        (ushort Code, string Label, double Width)[][] rows = {
            new (ushort,string,double)[] {(41,"`",1),(2,"1",1),(3,"2",1),(4,"3",1),(5,"4",1),(6,"5",1),(7,"6",1),(8,"7",1),(9,"8",1),(10,"9",1),(11,"0",1),(12,"-",1),(13,"=",1),(14,"Backspace",2)},
            new (ushort,string,double)[] {(15,"Tab",1.5),(16,"Q",1),(17,"W",1),(18,"E",1),(19,"R",1),(20,"T",1),(21,"Y",1),(22,"U",1),(23,"I",1),(24,"O",1),(25,"P",1),(26,"[",1),(27,"]",1),(43,"\\",1.5)},
            new (ushort,string,double)[] {(58,"Caps",1.75),(30,"A",1),(31,"S",1),(32,"D",1),(33,"F",1),(34,"G",1),(35,"H",1),(36,"J",1),(37,"K",1),(38,"L",1),(39,";",1),(40,"'",1),(28,"Enter",2.25)},
            new (ushort,string,double)[] {(42,"Shift",2.25),(44,"Z",1),(45,"X",1),(46,"C",1),(47,"V",1),(48,"B",1),(49,"N",1),(50,"M",1),(51,",",1),(52,".",1),(53,"/",1),(54,"Shift",2.75)},
            new (ushort,string,double)[] {(29,"Ctrl",1.5),(0x15B,"Win",1.25),(56,"Alt",1.25),(57,"",7),(0x138,"Alt",1.25),(0x15C,"Win",1.25),(0x11D,"Ctrl",1.5)}
        };
        var result = new List<Key>();
        for (int row=0;row<rows.Length;row++)
        {
            double width = 720+row*10, unit = width/15, start = (800-width)/2;
            foreach (var (code,label,units) in rows[row])
            { result.Add(new(code,label,Math.Round(start+2),196+row*38,Math.Round(units*unit-4))); start += units*unit; }
        }
        return result;
    }
}
