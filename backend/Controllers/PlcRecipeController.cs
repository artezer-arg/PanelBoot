using Backend.Services;
using Microsoft.AspNetCore.Mvc;

namespace Backend.Controllers;

[ApiController]
[Route("api/plc-recipe")]
public sealed class PlcRecipeController(
    PlcRecipeSettings settings, PlcRecipeTransport transport, IDatabaseService database,
    ILogger<PlcRecipeController> logger) : ControllerBase
{
    [HttpGet("settings")]
    public async Task<IActionResult> GetSettings() =>
        await IsSupervisorAsync() ? Ok(settings.Snapshot().Options) : Unauthorized();

    [HttpPut("settings")]
    public async Task<IActionResult> SaveSettings(PlcRecipeOptions options)
    {
        if (!await IsSupervisorAsync()) return Unauthorized();
        try
        {
            settings.Save(options);
            logger.LogInformation("Configuración de recetas PLC guardada. Habilitado: {Enabled}", options.Enabled);
            return Ok(options);
        }
        catch (ArgumentException exception) { return BadRequest(new { exception.Message }); }
    }

    [HttpPost("preview")]
    public async Task<IActionResult> Preview(PlcRecipePreview request)
    {
        if (!await IsSupervisorAsync()) return Unauthorized();
        return Ok(PlcRecipeExtractor.Extract(request.Options, request.Model, request.Qr));
    }

    [HttpPost("tcp")]
    public Task<IActionResult> TestTcp(CancellationToken token) =>
        RunAsync(async (options, operationToken) =>
            new { LatencyMs = await transport.TestTcpAsync(options, operationToken) }, token);

    [HttpPost("status")]
    public Task<IActionResult> ReadStatus(CancellationToken token) =>
        RunAsync(async (options, operationToken) =>
            await transport.ReadStatusAsync(options, operationToken), token);

    [HttpPost("send")]
    public Task<IActionResult> Send(PlcRecipeTest request, CancellationToken token) =>
        RunAsync(async (options, operationToken) =>
        {
            var extracted = request.Recipe is null
                ? PlcRecipeExtractor.Extract(options, request.Model ?? "", request.Qr ?? "")
                : null;
            var recipe = request.Recipe ?? extracted?.Recipe;
            if (recipe is null || recipe < options.MinimumRecipe || recipe > options.MaximumRecipe)
                throw new ArgumentException(extracted?.Error ?? "La receta está fuera del rango configurado.");

            var result = await transport.SendAsync(options with { EnableRecipeHandshake = request.UseHandshake },
                recipe.Value, extracted?.Rule?.SecondHandshakeValue, request.SendConfirmation, operationToken);
            return new { Extraction = extracted, Transfer = result };
        }, token);

    private async Task<IActionResult> RunAsync(
        Func<PlcRecipeOptions, CancellationToken, Task<object>> action, CancellationToken token)
    {
        if (!await IsSupervisorAsync()) return Unauthorized();
        var (options, changed) = settings.Snapshot();
        if (!options.Enabled)
        {
            logger.LogInformation("Diagnóstico PLC omitido. Comunicación deshabilitada.");
            return Conflict(new { Message = "PLC deshabilitado." });
        }
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, changed);
        try { return Ok(await action(options, linked.Token)); }
        catch (ArgumentException exception)
        {
            logger.LogWarning("Prueba PLC rechazada. {Message}", exception.Message);
            return BadRequest(new { exception.Message });
        }
        catch (Exception exception)
        {
            logger.LogWarning(exception, "Falló el diagnóstico de recetas PLC.");
            string message = changed.IsCancellationRequested ? "La configuración del PLC cambió durante la operación."
                : exception is OperationCanceledException ? "Se agotó el tiempo de comunicación con el PLC."
                : exception.Message;
            return StatusCode(502, new { Message = message });
        }
    }

    private async Task<bool> IsSupervisorAsync()
    {
        var password = Request.Headers["X-Door-Supervisor"].ToString();
        if (string.IsNullOrEmpty(password)) return false;
        var configuration = await database.GetConfigsAsync();
        return password.Equals(configuration.GetValueOrDefault("Supervisor_Password", "1234"), StringComparison.Ordinal);
    }
}

public sealed record PlcRecipePreview(PlcRecipeOptions Options, string Model, string Qr);
public sealed record PlcRecipeTest(short? Recipe, string? Model, string? Qr, bool UseHandshake, bool SendConfirmation);
