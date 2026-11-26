using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Backend.Services;

public sealed class PlcRecipeSettings
{
    internal (int ValidationId, PlcOperation Operation)? ConfirmedCuna { get; set; }
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    private readonly object _sync = new();
    private readonly string _path = Path.Combine(AppContext.BaseDirectory, "plc-recipe.json");
    private PlcRecipeOptions _options = new();
    private CancellationTokenSource _changed = new();

    public PlcRecipeSettings(ILogger<PlcRecipeSettings> logger)
    {
        if (!File.Exists(_path)) return;
        try
        {
            var stored = JsonSerializer.Deserialize<PlcRecipeOptions>(File.ReadAllText(_path), JsonOptions)
                ?? throw new InvalidDataException("Configuración PLC vacía.");
            Validate(stored);
            _options = stored;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or ArgumentException)
        {
            logger.LogError(exception, "Configuración PLC inválida. Comunicación deshabilitada.");
        }
    }

    public (PlcRecipeOptions Options, CancellationToken Changed) Snapshot()
    {
        lock (_sync) return (_options, _changed.Token);
    }

    public void Save(PlcRecipeOptions options)
    {
        Validate(options);
        CancellationTokenSource previous;
        lock (_sync)
        {
            File.WriteAllText(_path + ".tmp", JsonSerializer.Serialize(options, JsonOptions));
            File.Move(_path + ".tmp", _path, overwrite: true);
            _options = options;
            previous = _changed;
            _changed = new();
        }
        previous.Cancel();
        previous.Dispose();
    }

    private static void Validate(PlcRecipeOptions x)
    {
        if (!IPAddress.TryParse(x.IpAddress, out _) || x.Port is < 1 or > 65535 ||
            x.Rack is < 0 or > 7 || x.Slot is < 0 or > 31 ||
            x.PollingIntervalMs < 10 || x.TimeoutMs < x.PollingIntervalMs ||
            x.TimeoutMs > 120000)
            throw new ArgumentException("Revisá IP, puerto, rack, slot y tiempos del PLC.");

        int[] words = [x.RecipeOffset, x.StateOffset, x.ModelOffset];
        if (x.DataBlock is < 1 or > 65535 || x.ConfirmationOffset is < 0 or > 65535 ||
            x.ConfirmationBit is < 0 or > 7 || words.Any(offset => offset is < 0 or >= 65535) ||
            words.Any(offset => words.Count(other => Math.Abs(other - offset) < 2) != 1) ||
            words.Any(offset => x.ConfirmationOffset == offset || x.ConfirmationOffset == offset + 1))
            throw new ArgumentException("Revisá las direcciones del DB. Los registros y el bit deben ocupar posiciones distintas.");

        if (x.HandshakeReqValue == x.HandshakeAckValue || x.HandshakeReqValue == x.HandshakeIdleValue ||
            x.HandshakeAckValue == x.HandshakeIdleValue)
            throw new ArgumentException("REQ, ACK e IDLE deben tener valores distintos.");

        if (string.IsNullOrWhiteSpace(x.Delimiter) || x.Delimiter.Any(char.IsWhiteSpace) ||
            x.MinimumRecipe > x.MaximumRecipe || x.DefaultSegmentIndex is < 1 ||
            x.Rules is null || x.Rules.Any(rule => rule is null || string.IsNullOrWhiteSpace(rule.Pattern) ||
                !Enum.IsDefined(rule.MatchMode) ||
                (rule.CunaQr is null && (rule.SegmentIndex < 1 || rule.RecipeValue.HasValue)) ||
                (rule.CunaQr is not null && (string.IsNullOrWhiteSpace(rule.CunaQr) ||
                    rule.RecipeValue is not short value || value < x.MinimumRecipe || value > x.MaximumRecipe))))
            throw new ArgumentException("Revisá el delimitador, el rango de recetas y las posiciones de las reglas.");

        if (x.Rules.GroupBy(rule =>
                (rule.MatchMode, PlcRecipeExtractor.NormalizeModel(rule.Pattern).ToUpperInvariant(),
                    rule.CunaQr is null ? null : PlcRecipeExtractor.NormalizeQr(rule.CunaQr)))
            .Any(group => group.Count() > 1))
            throw new ArgumentException("Hay reglas repetidas para el mismo patrón y tipo de coincidencia.");
    }
}
