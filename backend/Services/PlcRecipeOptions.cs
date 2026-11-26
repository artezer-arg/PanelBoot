using System.Globalization;
using System.Text.RegularExpressions;

namespace Backend.Services;

public enum PlcRecipeMatchMode { Exact, StartsWith, Contains }

public sealed record PlcRecipeRule(
    string Pattern, PlcRecipeMatchMode MatchMode, int SegmentIndex,
    string? Description = null, short? SecondHandshakeValue = null,
    string? CunaQr = null, short? RecipeValue = null);

public sealed record PlcRecipeOptions
{
    public bool Enabled { get; init; }
    public string IpAddress { get; init; } = "192.168.10.1";
    public int Port { get; init; } = 102;
    public short Rack { get; init; }
    public short Slot { get; init; } = 1;
    public int PollingIntervalMs { get; init; } = 100;
    public int TimeoutMs { get; init; } = 2000;
    public int DataBlock { get; init; } = 48;
    public int RecipeOffset { get; init; } = 2;
    public int ConfirmationOffset { get; init; } = 4;
    public int ConfirmationBit { get; init; }
    public int StateOffset { get; init; } = 6;
    public int ModelOffset { get; init; }
    public bool EnableRecipeHandshake { get; init; } = true;
    public short HandshakeReqValue { get; init; } = 20;
    public short HandshakeAckValue { get; init; } = 10;
    public short HandshakeIdleValue { get; init; } = 24;
    public bool EnableDualHandshake { get; init; }
    public bool SendConfirmation { get; init; }
    public bool ConfirmationValue { get; init; } = true;
    public string Delimiter { get; init; } = "-";
    public bool RequireConfiguredRule { get; init; } = true;
    public int? DefaultSegmentIndex { get; init; }
    public short MinimumRecipe { get; init; } = short.MinValue;
    public short MaximumRecipe { get; init; } = short.MaxValue;
    public IReadOnlyList<PlcRecipeRule> Rules { get; init; } = [];
}

public sealed record PlcRecipeExtraction(
    string Model, string Qr, string[] Segments, int? Position,
    short? Recipe, PlcRecipeRule? Rule, string? Error);

internal sealed record PlcOperation(string Status, string Message, PlcRecipeExtraction? Extraction = null,
    PlcRecipeTransfer? Transfer = null, string? Model = null);

public static partial class PlcRecipeExtractor
{
    public static PlcRecipeExtraction Extract(PlcRecipeOptions options, string model, string qr, string? sd = null)
    {
        model = NormalizeModel(model);
        qr = NormalizeQr(qr);
        if (string.IsNullOrWhiteSpace(options.Delimiter))
            return new(model, qr, [], null, null, null, "Configurá un delimitador para el QR.");

        var segments = Split(qr, options.Delimiter);
        var rules = options.Rules
            .Select(candidate => (Rule: candidate, Pattern: NormalizeModel(candidate.Pattern)))
            .Where(candidate => candidate.Pattern.Length > 0 &&
                (Matches(model, candidate.Pattern, candidate.Rule.MatchMode) ||
                 (sd is not null && Matches(NormalizeModel(sd), candidate.Pattern, candidate.Rule.MatchMode))))
            .OrderByDescending(candidate => candidate.Rule.MatchMode == PlcRecipeMatchMode.Exact)
            .ThenByDescending(candidate => candidate.Pattern.Length)
            .ThenBy(candidate => candidate.Rule.MatchMode)
            .Select(candidate => candidate.Rule)
            .ToArray();
        var cunaRules = rules.Where(candidate => candidate.CunaQr != null).ToArray();
        if (cunaRules.Length != 0)
        {
            var cuna = cunaRules.FirstOrDefault(candidate => NormalizeQr(candidate.CunaQr!) == qr);
            if (cuna?.RecipeValue is not short assigned || assigned < options.MinimumRecipe || assigned > options.MaximumRecipe)
                return new(model, qr, [], null, null, cuna, $"El QR de la cuna no tiene un valor válido asignado para «{model}».");
            return new(model, qr, [], null, assigned, cuna, null);
        }
        var rule = rules.FirstOrDefault();
        int? position = rule?.SegmentIndex ?? (options.RequireConfiguredRule ? null : options.DefaultSegmentIndex);

        if (position is null)
            return new(model, qr, segments, null, null, rule, $"El modelo «{model}» no tiene una posición configurada.");
        if (position < 1 || position > segments.Length)
            return new(model, qr, segments, position, null, rule, $"El QR no contiene la posición {position}.");
        if (!short.TryParse(segments[position.Value - 1], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out short value)
            || value < options.MinimumRecipe || value > options.MaximumRecipe)
        {
            return new(model, qr, segments, position, null, rule,
                $"La posición {position} debe contener un entero entre {options.MinimumRecipe} y {options.MaximumRecipe}.");
        }

        return new(model, qr, segments, position, value, rule, null);
    }

    public static string NormalizeModel(string model) =>
        string.Join(' ', model.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    public static string NormalizeQr(string qr) =>
        string.Concat(qr.Where(character => !char.IsWhiteSpace(character)));

    private static string[] Split(string qr, string delimiter)
    {
        // With a hyphen delimiter, a negative value after the first segment has two consecutive hyphens.
        if (delimiter == "-" && SignedHyphenList().IsMatch(qr))
            return SignedInteger().Matches(qr).Select((match, index) =>
                index > 0 ? match.Value[1..] : match.Value).ToArray();
        return qr.Split(delimiter, StringSplitOptions.None);
    }

    [GeneratedRegex(@"\A[+-]?\d+(?:-[+-]?\d+)*\z", RegexOptions.CultureInvariant)]
    private static partial Regex SignedHyphenList();

    [GeneratedRegex(@"\G(?:[+-]?\d+|-[+-]?\d+)", RegexOptions.CultureInvariant)]
    private static partial Regex SignedInteger();

    private static bool Matches(string model, string pattern, PlcRecipeMatchMode mode) => mode switch
    {
        PlcRecipeMatchMode.Exact => model.Equals(pattern, StringComparison.OrdinalIgnoreCase),
        PlcRecipeMatchMode.StartsWith => model.StartsWith(pattern, StringComparison.OrdinalIgnoreCase),
        PlcRecipeMatchMode.Contains => model.Contains(pattern, StringComparison.OrdinalIgnoreCase),
        _ => false
    };
}
