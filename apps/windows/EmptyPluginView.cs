using System.Windows.Media;
using Miucs.Audio;
using Miucs.Keyboard;
using Miucs.Visualizations;
namespace Miucs.Windows;

// Keep the shell and tray usable when the plugin catalog is empty or invalid.
internal sealed class EmptyPluginView : VisualizationView
{
    public override string Id => "";
    public override double BaseWidth => 400;
    public override double BaseHeight => 260;
    public override double LayoutMinWidth => 40;
    public override double LayoutMaxWidth => 1000;
    protected override void ResetInput() { }
    public override void Update(AudioInput audio, KeyboardInput keyboard, double deltaTime) { }
    protected override void RenderScene(DrawingContext dc) { }
}
