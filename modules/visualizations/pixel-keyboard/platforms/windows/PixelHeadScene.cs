using System;
using Miucs.Keyboard;
namespace Miucs.Visualizations;

/// <summary>Typing-driven portrait; audio cannot reset it. Only fresh physical presses arm motion.</summary>
public sealed class PixelHeadScene
{
    public double Frequency { get; private set; }
    public double Amplitude { get; private set; }
    public double Phase { get; private set; }
    public double Angle => Amplitude * Math.Sin(Phase) * Math.PI / 15;
    private Guid? session;
    private long cursor;
    private double? sampleTime;
    private double sinceInput = 100, sincePress = 100, rate;
    private bool armed;
    public void Reset()
    {
        Frequency = Amplitude = Phase = rate = 0; session = null; cursor = 0;
        sampleTime = null; sinceInput = sincePress = 100; armed = false;
    }
    public void Update(KeyboardInput? input, double seconds)
    {
        double dt = double.IsFinite(seconds) ? Math.Max(0, seconds) : 0;
        sinceInput += dt; sincePress += dt; bool freshPress = false;
        if (input is not null)
        {
            if (session != input.SessionId) { Reset(); session = input.SessionId; }
            if (input.State != KeyboardState.Running || input.DroppedEventCount > 0 || !double.IsFinite(input.SampledAt) ||
                (sampleTime.HasValue && input.SampledAt < sampleTime.Value))
            { Reset(); session = input.SessionId; cursor = input.Sequence; return; }
            if (!sampleTime.HasValue || input.SampledAt > sampleTime.Value)
            {
                sinceInput = 0; sampleTime = input.SampledAt;
                rate = double.IsFinite(input.PressesPerSecond) ? Math.Clamp(input.PressesPerSecond, 0, 6) : 0;
            }
            foreach (var ev in input.Events)
            {
                double age = input.SampledAt - ev.ReceivedAt;
                if (ev.Sequence > cursor && ev.Sequence <= input.Sequence && ev.Kind == KeyboardEventKind.Pressed &&
                    double.IsFinite(age) && age >= 0 && age <= .25)
                { freshPress = true; armed = true; sincePress = age; }
            }
            cursor = Math.Max(cursor, input.Sequence);
        }
        bool active = armed && sinceInput <= .25 && rate > 0 && sincePress <= Math.Max(.45, Math.Min(1.25, 1.5 / Math.Max(rate, 1)));
        double step = freshPress ? Math.Min(dt, 1d / 30) : dt;
        double targetFrequency = .4 * rate;
        if (active)
        {
            if (Amplitude == 0) Frequency = targetFrequency;
            Frequency += (targetFrequency - Frequency) * (1 - Math.Exp(-step / .18));
        }
        Amplitude += ((active ? 1d : 0d) - Amplitude) * (1 - Math.Exp(-step / (active ? .12 : .18)));
        if (!active && Amplitude < .002) { Amplitude = Frequency = Phase = 0; armed = false; }
        else Phase = (Phase + 2 * Math.PI * Frequency * step) % (2 * Math.PI);
    }
}
