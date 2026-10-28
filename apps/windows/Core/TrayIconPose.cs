using System;

namespace Miucs.Windows;

/// <summary>Cached poses sample the shared floating cat angle; there is no separate animation clock.</summary>
public static class TrayIconPose
{
    public const int FrameCount = 25;
    public const int RestFrame = 12;
    public const double UpdateInterval = 1d / 16;
    public static int FromAngle(double radians) => double.IsFinite(radians)
        ? (int)Math.Round(Math.Clamp(radians * 180 / Math.PI, -12, 12)) + RestFrame : RestFrame;
    public static double Angle(int frame) => (Math.Clamp(frame, 0, FrameCount - 1) - RestFrame) * Math.PI / 180;
}
