using System.Buffers.Binary;
using System.Diagnostics;
using System.Net.Sockets;
using S7.Net;

namespace Backend.Services;

public sealed record PlcRecipeTransfer(short Recipe, short VerifiedRecipe, short? State, bool? Confirmation);
public sealed record PlcRecipeStatus(short State, short Model);

public sealed class PlcRecipeTransport
{
    private readonly SemaphoreSlim _connectionGate = new(1);

    public async Task<double> TestTcpAsync(PlcRecipeOptions options, CancellationToken cancellationToken)
    {
        using var timeout = StartTimeout(options, cancellationToken);
        await _connectionGate.WaitAsync(timeout.Token);
        try
        {
            using var client = new TcpClient();
            var elapsed = Stopwatch.StartNew();
            await client.ConnectAsync(options.IpAddress, options.Port, timeout.Token);
            return elapsed.Elapsed.TotalMilliseconds;
        }
        finally { _connectionGate.Release(); }
    }

    public Task<PlcRecipeStatus> ReadStatusAsync(PlcRecipeOptions options, CancellationToken cancellationToken) =>
        WithPlcAsync(options, async (plc, token) =>
            new PlcRecipeStatus(
                await ReadWordAsync(plc, options, options.StateOffset, token),
                await ReadWordAsync(plc, options, options.ModelOffset, token)), cancellationToken);

    public Task<PlcRecipeTransfer> SendAsync(
        PlcRecipeOptions options, short recipe, short? secondValue, bool sendConfirmation,
        CancellationToken cancellationToken) =>
        WithPlcAsync(options, async (plc, token) =>
        {
            short? state = null;
            if (options.EnableRecipeHandshake)
            {
                state = await HandshakeAsync(plc, options, recipe, token);
                if (options.EnableDualHandshake && secondValue is short second)
                    state = await HandshakeAsync(plc, options, second, token);
            }
            else
            {
                await WriteWordAsync(plc, options, recipe, token);
            }

            var verified = await ReadWordAsync(plc, options, options.RecipeOffset, token);
            if (!options.EnableRecipeHandshake && verified != recipe)
                throw new InvalidOperationException($"El PLC devolvió {verified} en la lectura de verificación. Se esperaba {recipe}.");

            bool? confirmation = null;
            if (sendConfirmation)
            {
                await plc.WriteBitAsync(DataType.DataBlock, options.DataBlock, options.ConfirmationOffset,
                    options.ConfirmationBit, options.ConfirmationValue, token);
                var bytes = await plc.ReadBytesAsync(DataType.DataBlock, options.DataBlock, options.ConfirmationOffset, 1, token);
                confirmation = (bytes[0] & (1 << options.ConfirmationBit)) != 0;
                if (confirmation != options.ConfirmationValue)
                    throw new InvalidOperationException("El PLC no conservó el valor del bit de confirmación.");
            }

            return new PlcRecipeTransfer(recipe, verified, state, confirmation);
        }, cancellationToken);

    private async Task<T> WithPlcAsync<T>(
        PlcRecipeOptions options, Func<Plc, CancellationToken, Task<T>> action,
        CancellationToken cancellationToken)
    {
        using var timeout = StartTimeout(options, cancellationToken);
        await _connectionGate.WaitAsync(timeout.Token);
        try
        {
            using var plc = new Plc(CpuType.S71500, options.IpAddress, options.Port, options.Rack, options.Slot);
            await plc.OpenAsync(timeout.Token);
            return await action(plc, timeout.Token);
        }
        finally { _connectionGate.Release(); }
    }

    private static CancellationTokenSource StartTimeout(PlcRecipeOptions options, CancellationToken cancellationToken)
    {
        if (!options.Enabled)
            throw new InvalidOperationException("PLC deshabilitado.");
        var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(options.TimeoutMs);
        return timeout;
    }

    private static async Task<short> HandshakeAsync(
        Plc plc, PlcRecipeOptions options, short recipe, CancellationToken cancellationToken)
    {
        short state;
        do
        {
            state = await ReadWordAsync(plc, options, options.StateOffset, cancellationToken);
            if (state != options.HandshakeReqValue)
                await Task.Delay(options.PollingIntervalMs, cancellationToken);
        } while (state != options.HandshakeReqValue);

        // The word remains available to the PLC. Avoid another write after the PLC has already read it.
        await WriteWordAsync(plc, options, recipe, cancellationToken);
        do
        {
            state = await ReadWordAsync(plc, options, options.StateOffset, cancellationToken);
            if (state != options.HandshakeAckValue)
                await Task.Delay(options.PollingIntervalMs, cancellationToken);
        } while (state != options.HandshakeAckValue);
        return state;
    }

    private static async Task<short> ReadWordAsync(
        Plc plc, PlcRecipeOptions options, int offset, CancellationToken cancellationToken)
    {
        var bytes = await plc.ReadBytesAsync(DataType.DataBlock, options.DataBlock, offset, 2, cancellationToken);
        return BinaryPrimitives.ReadInt16BigEndian(bytes);
    }

    private static Task WriteWordAsync(
        Plc plc, PlcRecipeOptions options, short recipe, CancellationToken cancellationToken)
    {
        byte[] bytes = new byte[2];
        BinaryPrimitives.WriteInt16BigEndian(bytes, recipe);
        return plc.WriteBytesAsync(DataType.DataBlock, options.DataBlock, options.RecipeOffset, bytes, cancellationToken);
    }
}
