using System.Data;
using Backend.Models;
using Dapper;
using Microsoft.Data.SqlClient;

namespace Backend.Services;

public sealed class SkipPrintingService(
    StationSequenceOptions station, IDatabaseService database, IPrintingService printer,
    ILogger<SkipPrintingService> logger) : BackgroundService
{
    public static string ConfigKey(string stationId) => $"Skip_Printer:{stationId}";

    public static bool IsNormalPrinter(Dictionary<string, string> config, string name) =>
        name.Equals(config.GetValueOrDefault("Printer_Name", "Microsoft Print to PDF"), StringComparison.OrdinalIgnoreCase);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!station.Enabled) return;

        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(3));
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            try
            {
                var name = await database.GetConfigValueAsync(ConfigKey(station.Id));
                if (string.IsNullOrWhiteSpace(name)) continue;

                var config = await database.GetConfigsAsync();
                if (IsNormalPrinter(config, name) ||
                    !printer.GetInstalledPrinters().Contains(name, StringComparer.OrdinalIgnoreCase))
                    continue;

                using var conn = new SqlConnection(DatabaseService.GetCurrentConnectionString());
                var job = await conn.QuerySingleOrDefaultAsync<SkipPrintJob>(new CommandDefinition(
                    "dbo.SP_DoorImpresionSalteo", new { Station = station.Id, Action = "TOMAR", Printer = name },
                    commandType: CommandType.StoredProcedure, cancellationToken: stoppingToken));
                if (job is null) continue;
                await SendAsync(conn, job, name);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { return; }
            catch (SqlException exception) when (exception.Number == 2812)
            {
                // A station may be upgraded before the optional Salteo printing migration.
            }
            catch (Exception exception)
            {
                logger.LogWarning(exception, "No se pudo procesar la cola de etiquetas de Salteo de {Station}.", station.Id);
            }
        }
    }

    private async Task SendAsync(SqlConnection conn, SkipPrintJob job, string name)
    {
        string? error = null;
        try
        {
            var order = await database.GetOrderProductionByIdAsync(job.OrderId)
                ?? throw new InvalidOperationException("No se encontró la orden del panel salteado.");
            var result = await printer.PrintKanbanAsync(new Validacion
            {
                ID_OrdenProduccion = order.ID_OrdenProduccion, ID_OrdenCliente = order.ID_OrdenCliente,
                Orden = order.Orden, Secuencia = order.Secuencia, SD = order.SD, Referencia = order.Referencia,
                Mano = order.Mano, Posicion = order.Posicion, Puesto = station.Id,
                Operador = "SALTEO", ResultadoGeneral = "SALTEADO"
            }, new Dictionary<string, string>
            {
                ["Printer_Mode"] = "Spooler",
                ["Printer_Name"] = name,
                ["Printer_Simulator_Enabled"] = "false",
                ["Print_Copies"] = "1"
            });
            if (!result.Success) error = result.ErrorMessage ?? "Windows rechazó el trabajo de impresión.";
        }
        catch (Exception exception)
        {
            error = exception.Message;
        }

        if (error is not null)
            logger.LogWarning("Etiqueta de Salteo {Job} en {Station}: {Failure}", job.Id, station.Id, error);

        // Do not automatically re-send if SQL fails after Windows accepted the print job.
        await conn.ExecuteAsync("dbo.SP_DoorImpresionSalteo", new
        {
            Station = station.Id, Action = error is null ? "ENVIADA" : "ERROR", Id = job.Id,
            Error = error is { Length: > 1000 } ? error[..1000] : error
        }, commandType: CommandType.StoredProcedure);
    }

    private sealed record SkipPrintJob(int Id, int OrderId);
}
