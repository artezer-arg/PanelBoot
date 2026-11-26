using System;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using Backend.Services;

namespace Backend.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class SequenceController : ControllerBase
    {
        private readonly IDatabaseService _dbService;
        private readonly IArduinoService _arduinoService;
        private readonly StationSequenceOptions _station;
        private readonly PlcRecipeSettings _plcSettings;

        public SequenceController(IDatabaseService dbService, IArduinoService arduinoService,
            StationSequenceOptions station, PlcRecipeSettings plcSettings)
        {
            _dbService = dbService;
            _arduinoService = arduinoService;
            _station = station;
            _plcSettings = plcSettings;
        }

        [HttpGet("next")]
        public async Task<IActionResult> GetNext([FromQuery] string puesto, CancellationToken cancellationToken)
        {
            if (_station.Enabled)
            {
                puesto = _station.Id;
            }
            else if (string.IsNullOrEmpty(puesto))
            {
                return BadRequest("El puesto es requerido.");
            }

            try
            {
                int? panelAssignment = null;
                if (_station.Enabled)
                {
                    try
                    {
                        panelAssignment = await _dbService.GetPanelAssignmentAsync(puesto, cancellationToken);
                    }
                    catch (SqlException error) when (error.Number == 2812)
                    {
                        // The display also works with databases that have not installed panel assignments.
                    }
                }
                var nextPanel = await _dbService.GetNextPanelAsync(puesto);
                if (nextPanel == null)
                {
                    _ = _arduinoService.SendClearAsync();
                    return NotFound(new { message = $"SIN PANELES PENDIENTES PARA EL PUESTO {puesto.ToUpper()}", PanelAssignment = panelAssignment });
                }

                // Disparar las luces Pick-to-Light para este panel de forma no bloqueante
                _ = _arduinoService.TriggerPanelLightsAsync(nextPanel.Referencia, nextPanel.ID_OrdenProduccion);

                // Check equivalence mapping dynamically to see if ornament is required
                var equiv = await _dbService.GetEquivalenceAsync(nextPanel.Referencia);
                bool requiereOrnamento = equiv?.RequiereOrnamento ?? true; // Default to true if not configured
                bool autoPrintNoOrnament = !requiereOrnamento && NoOrnamentPrinting.IsAutomatic(
                    await _dbService.GetConfigValueAsync(NoOrnamentPrinting.ConfigKey));

                var latestValidation = await _dbService.GetLatestApprovedValidationByOrderAsync(nextPanel.ID_OrdenProduccion);
                bool plcEnabled = _plcSettings.Snapshot().Options.Enabled;
                if ((_station.Enabled || plcEnabled) && latestValidation?.EstadoImpresion != "COMPLETO")
                {
                    latestValidation = null;
                }

                return Ok(new {
                    nextPanel.Referencia,
                    nextPanel.ID_OrdenProduccion,
                    nextPanel.ID_OrdenCliente,
                    nextPanel.Orden,
                    nextPanel.Secuencia,
                    nextPanel.SD,
                    nextPanel.Expr1,
                    nextPanel.Puesto,
                    nextPanel.FechaSecuencia,
                    nextPanel.Mano,
                    nextPanel.Posicion,
                    PanelAssignment = panelAssignment,
                    RequiereOrnamento = requiereOrnamento,
                    AutoPrintNoOrnament = autoPrintNoOrnament,
                    YaValidado = latestValidation != null,
                    CierrePendiente = (_station.Enabled || plcEnabled) && latestValidation is { FechaAvancePuntero: null },
                    CunaPendiente = plcEnabled && latestValidation is { FechaAvancePuntero: null },
                    UltimaValidacion = latestValidation
                });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { message = "Error de conexión con la base de datos.", detail = ex.Message });
            }
        }

        [HttpPost("complete")]
        public async Task<IActionResult> Complete([FromBody] CompleteRequest request)
        {
            if (_station.Enabled || _plcSettings.Snapshot().Options.Enabled)
            {
                return BadRequest(new { message = "La estación debe cerrar mediante su validación impresa." });
            }
            if (request == null) return BadRequest("Datos inválidos.");

            try
            {
                await _dbService.CompletePanelProcessAsync(
                    request.ID_OrdenProduccion, 
                    request.ID_OrdenCliente, 
                    request.Puesto, 
                    request.Orden
                );
                return Ok(new { success = true, message = "Secuencia avanzada correctamente." });
            }
            catch (SqlException ex) when (ex.Number == 50001 || ex.Number == 50002)
            {
                return BadRequest(new { success = false, message = ex.Message });
            }
            catch (Exception ex)
            {
                return StatusCode(500, new { success = false, message = "Error al completar la secuencia.", detail = ex.Message });
            }
        }
    }

    public class CompleteRequest
    {
        public int ID_OrdenProduccion { get; set; }
        public int ID_OrdenCliente { get; set; }
        public string Puesto { get; set; } = string.Empty;
        public int Orden { get; set; }
    }
}
