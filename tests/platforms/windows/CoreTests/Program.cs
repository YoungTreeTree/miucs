using System;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 3 && args[0] == "--audio-reference") { AudioTests.ExportReference(args[1], args[2]); return 0; }
            AudioTests.Run();
            KeyboardTests.Run();
            PcmDecoderTests.Run();
            VisualizationTests.Run();
            ShellTests.Run();
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
