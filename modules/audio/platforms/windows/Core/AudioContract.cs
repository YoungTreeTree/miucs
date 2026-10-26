using System;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Miucs.Audio;

/// <summary>Offline contract exchange only; the live pipeline never serializes frames.</summary>
public static class AudioContract
{
    public static JsonSerializerOptions JsonOptions { get; } = CreateOptions();
    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            WriteIndented = true
        };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return options;
    }
    public static AudioInput ReadInput(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.GetProperty("version").GetInt32() != 1) throw new JsonException("Unsupported audio contract version.");
        if (root.TryGetProperty("frame", out var frame) && frame.ValueKind != JsonValueKind.Null && frame.GetProperty("version").GetInt32() != 1)
            throw new JsonException("Unsupported frame version.");
        var input = JsonSerializer.Deserialize<AudioInput>(json, JsonOptions) ?? throw new JsonException("Missing input.");
        if (input.Frame != null && input.Frame.SessionId != input.SessionId) throw new JsonException("Frame generation mismatch.");
        return input with { Onsets = input.Onsets ?? Array.Empty<OnsetEvent>(), Beats = input.Beats ?? Array.Empty<BeatEvent>() };
    }
    public static string WriteInput(AudioInput input) => JsonSerializer.Serialize(input, JsonOptions);
}
