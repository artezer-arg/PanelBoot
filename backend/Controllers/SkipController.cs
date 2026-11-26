using System.Data;
using Backend.Services;
using Dapper;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace Backend.Controllers;

[ApiController]
[Route("api/salteo")]
public sealed class SkipController(IDatabaseService database, IPrintingService printer, StationSequenceOptions localStation) : ControllerBase
{
    private const int PageSize = 100;

    [HttpGet("printing")]
    public async Task<IActionResult> Printing(string station, CancellationToken token)
    {
        if (!await IsSupervisorAsync()) return Unauthorized();
        if (string.IsNullOrWhiteSpace(station) || station.Length > 20) return BadRequest();
        var config = await database.GetConfigsAsync();
        var name = config.GetValueOrDefault(SkipPrintingService.ConfigKey(station), "");
        var canConfigure = localStation.Enabled && string.Equals(station, localStation.Id, StringComparison.OrdinalIgnoreCase);
        var printers = canConfigure
            ? printer.GetInstalledPrinters().Where(item => !SkipPrintingService.IsNormalPrinter(config, item)).ToArray() : [];
        using var conn = new SqlConnection(DatabaseService.GetCurrentConnectionString());
        var counts = await conn.QueryAsync<SkipPrintingCount>(new CommandDefinition(
            "dbo.SP_DoorImpresionSalteo", new { Station = station, Action = "ESTADO" },
            commandType: CommandType.StoredProcedure, cancellationToken: token));
        return Ok(new { Name = name, CanConfigure = canConfigure, Printers = printers, Counts = counts });
    }

    [HttpPost("printing")]
    public async Task<IActionResult> SavePrinting(SkipPrinterRequest request)
    {
        if (!await IsSupervisorAsync()) return Unauthorized();
        if (!localStation.Enabled || !string.Equals(request.Station, localStation.Id, StringComparison.OrdinalIgnoreCase))
            return BadRequest(new { message = "Configurá la impresora desde la PC de ese puesto." });
        string name = request.Name.Trim();
        var config = await database.GetConfigsAsync();
        if (string.IsNullOrEmpty(name) || name.Length > 256 || SkipPrintingService.IsNormalPrinter(config, name) ||
            !printer.GetInstalledPrinters().Contains(name, StringComparer.OrdinalIgnoreCase))
            return BadRequest(new { message = "Elegí una impresora de Windows distinta a la impresora normal del puesto." });
        bool updated = await database.UpdateConfigValueAsync(SkipPrintingService.ConfigKey(localStation.Id),
            name, "SUPERVISOR", "Impresora de Kanban de Salteo");
        return updated ? Ok(new { Name = name }) : Conflict(new { message = "No se pudo guardar la impresora." });
    }

    [HttpPost("printing/retry")]
    public async Task<IActionResult> RetryPrinting(SkipPrinterRetry request, CancellationToken token)
    {
        if (!await IsSupervisorAsync()) return Unauthorized();
        if (string.IsNullOrWhiteSpace(request.Station) || request.Station.Length > 20) return BadRequest();
        using var conn = new SqlConnection(DatabaseService.GetCurrentConnectionString());
        int count = await conn.QuerySingleAsync<int>(new CommandDefinition("dbo.SP_DoorImpresionSalteo",
            new { request.Station, Action = "REINTENTAR" },
            commandType: CommandType.StoredProcedure, cancellationToken: token));
        return Ok(new { Count = count });
    }

    [HttpGet("panel-assignment")]
    public Task<IActionResult> PanelAssignment(string station, CancellationToken token) =>
        GetOrSavePanelAssignment(station, null, token);

    [HttpPost("panel-assignment")]
    public Task<IActionResult> SavePanelAssignment(PanelAssignmentRequest request, CancellationToken token) =>
        GetOrSavePanelAssignment(request.Station, request.Mask, token);

    private async Task<IActionResult> GetOrSavePanelAssignment(string station, int? mask, CancellationToken token)
    {
        if (!await IsSupervisorAsync()) return Unauthorized();
        if (string.IsNullOrWhiteSpace(station) || station.Length > 20 || mask is < 0 or > 15)
            return BadRequest(new { message = "Seleccioná un puesto y tipos de panel válidos." });
        try
        {
            await using var connection = new SqlConnection(DatabaseService.GetCurrentConnectionString());
            var assigned = await connection.QuerySingleOrDefaultAsync<int?>(new CommandDefinition(
                "dbo.SP_DoorPanelesPuesto", new { Station = station, Mask = mask },
                commandType: CommandType.StoredProcedure, cancellationToken: token));
            return assigned.HasValue ? Ok(new { Mask = assigned.Value })
                : NotFound(new { message = "No se encontró el puesto." });
        }
        catch (SqlException error) when (error.Number is 50100 or 50101)
        {
            return Conflict(new { error.Message });
        }
    }

    [HttpGet("stations")]
    public async Task<IActionResult> Stations(CancellationToken token)
    {
        if (!await IsSupervisorAsync()) return Unauthorized();
        await using var connection = new SqlConnection(DatabaseService.GetCurrentConnectionString());
        var stations = await connection.QueryAsync<SkipStation>(new CommandDefinition(
            "dbo.SP_DoorPuestosSalteo", commandType: CommandType.StoredProcedure, cancellationToken: token));
        return Ok(stations);
    }

    [HttpGet("pending")]
    public async Task<IActionResult> Pending(string station, int after = 0, string? sd = null, CancellationToken token = default)
    {
        if (!await IsSupervisorAsync()) return Unauthorized();
        await using var connection = new SqlConnection(DatabaseService.GetCurrentConnectionString());
        using var results = await connection.QueryMultipleAsync(new CommandDefinition(
            "dbo.SP_DoorPendientesSalteo", new { Station = station, After = after, Limit = PageSize + 1, SD = string.IsNullOrWhiteSpace(sd) ? null : sd.Trim() },
            commandType: CommandType.StoredProcedure, cancellationToken: token));
        var selected = await results.ReadSingleOrDefaultAsync<SkipStation>();
        var rows = (await results.ReadAsync<SkipPanel>()).ToList();
        var sdOptions = await results.ReadAsync<string>();
        if (selected is null) return NotFound(new { message = "No se encontró el puesto seleccionado." });
        var panels = rows.Take(PageSize).ToArray();
        int? nextCursor = rows.Count > PageSize ? panels[^1].OrderId : null;
        return Ok(new { Station = selected, Panels = panels, NextCursor = nextCursor, SdOptions = sdOptions });
    }

    [HttpPost("skip")]
    public async Task<IActionResult> Skip(SkipRequest request, CancellationToken token)
    {
        if (!await IsSupervisorAsync()) return Unauthorized();
        var ids = request.OrderIds?.Distinct().ToArray();
        if (string.IsNullOrWhiteSpace(request.Station) || request.Station.Length > 20 ||
            request.Mode > 2 ||
            (ids is null ? request.OrderId <= 0 : ids.Length is < 1 or > 1000 || ids.Any(id => id <= 0)) ||
            (request.Mode == 2 && !request.EntireSequence))
            return BadRequest(new { message = "Seleccioná un puesto y una orden válidos." });
        try
        {
            await using var connection = new SqlConnection(DatabaseService.GetCurrentConnectionString());
            var affected = await connection.QuerySingleAsync<int>(new CommandDefinition("dbo.SP_DoorRegistrarSalteo",
                new { request.Station, request.OrderId, request.EntireSequence, request.Mode,
                    OrderIds = ids is null ? null : new System.Xml.Linq.XElement("ids",
                        ids.Select(id => new System.Xml.Linq.XElement("id", id))).ToString() },
                commandType: CommandType.StoredProcedure, cancellationToken: token));
            return Ok(new { Affected = affected });
        }
        catch (SqlException error) when (error.Number is 50100 or 50101)
        {
            return Conflict(new { error.Message });
        }
    }

    private async Task<bool> IsSupervisorAsync()
    {
        var supplied = Request.Headers["X-Door-Supervisor"].ToString();
        if (supplied.Length == 0) return false;
        var config = await database.GetConfigsAsync();
        return supplied.Equals(config.GetValueOrDefault("Supervisor_Password", "1234"), StringComparison.Ordinal);
    }

    public sealed record SkipRequest(string Station, int OrderId, bool EntireSequence, byte Mode, int[]? OrderIds);
    public sealed record PanelAssignmentRequest(string Station, int Mask);
    public sealed record SkipPrinterRequest(string Station, string Name);
    public sealed record SkipPrinterRetry(string Station);
    private sealed record SkipPrintingCount(string Estado, int Cantidad);
    private sealed record SkipStation(string Station, string Source, int? LastValidatedOrderId, int? LastValidatedSequence);
    private sealed record SkipPanel(int OrderId, int Sequence, string? Sd, string Reference, string? Position,
        string? Hand, string ProductionDate, bool Skipped, bool Started);
}
