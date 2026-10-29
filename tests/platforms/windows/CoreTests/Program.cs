using System;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 3 && args[0] == "--audio-reference") { AudioTests.ExportReference(args[1], args[2]); return 0; }
            if (args.Length == 5 && args[0] == "--tray-preview")
            { TrayIconTests.ExportPreview(args[1], int.Parse(args[2]), int.Parse(args[3]), args[4]); return 0; }
            AudioTests.Run();
            KeyboardTests.Run();
            PcmDecoderTests.Run();
            VisualizationTests.Run();
            StaffBeatTests.Run();
            ShellTests.Run();
            HoverLockTests.Run();
            PixelKeyboardTests.Run();
            TrayIconTests.Run();
            PluginInputTests.Run();
            Console.WriteLine("PASS: all Windows portable core tests");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }
}
