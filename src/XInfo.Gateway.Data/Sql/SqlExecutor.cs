using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace XInfo.Gateway.Data.Sql;

public sealed class XInfoSqlOptions
{
    public const string SectionName = "XInfoSql";

    public string ConnectionString { get; set; } = string.Empty;

    /// <summary>
    /// Deliberately short. This is a shared, someone-else's database; a gateway call that
    /// hangs holds a connection in their pool and drags their system down with ours.
    /// </summary>
    public int CommandTimeoutSeconds { get; set; } = 30;

    /// <summary>Longer budget for the pull procedures, which sweep a modified-since range.</summary>
    public int PullCommandTimeoutSeconds { get; set; } = 120;

    public int MaxRetries { get; set; } = 3;
    public int RetryBaseDelayMs { get; set; } = 200;
}

public sealed class SqlExecutor(
    IOptions<XInfoSqlOptions> options,
    ILogger<SqlExecutor> logger) : ISqlExecutor
{
    private readonly XInfoSqlOptions _options = options.Value;

    public async Task<IReadOnlyList<T>> QueryAsync<T>(
        string procedure, object? parameters = null, CancellationToken ct = default)
        => await RunAsync(procedure, async connection =>
        {
            var rows = await connection.QueryAsync<T>(Command(procedure, parameters, ct));
            return (IReadOnlyList<T>)rows.AsList();
        }, ct);

    public async Task<T?> QuerySingleOrDefaultAsync<T>(
        string procedure, object? parameters = null, CancellationToken ct = default)
        => await RunAsync(procedure,
            connection => connection.QueryFirstOrDefaultAsync<T>(Command(procedure, parameters, ct)), ct);

    public async Task<int> ExecuteAsync(
        string procedure, object? parameters = null, CancellationToken ct = default)
        => await RunAsync(procedure,
            connection => connection.ExecuteAsync(Command(procedure, parameters, ct)), ct);

    public async Task<T> QueryMultipleAsync<T>(
        string procedure,
        Func<IMultiResult, Task<T>> read,
        object? parameters = null,
        CancellationToken ct = default)
        => await RunAsync(procedure, async connection =>
        {
            await using var grid = await connection.QueryMultipleAsync(Command(procedure, parameters, ct));
            return await read(new DapperMultiResult(grid));
        }, ct);

    private CommandDefinition Command(string procedure, object? parameters, CancellationToken ct)
    {
        var timeout = procedure.Contains("_Get", StringComparison.Ordinal)
                      || procedure.Contains("_List", StringComparison.Ordinal)
            ? _options.PullCommandTimeoutSeconds
            : _options.CommandTimeoutSeconds;

        return new CommandDefinition(
            procedure, parameters, commandTimeout: timeout,
            commandType: CommandType.StoredProcedure, cancellationToken: ct);
    }

    private async Task<T> RunAsync<T>(
        string procedure, Func<SqlConnection, Task<T>> action, CancellationToken ct)
    {
        for (var attempt = 1; ; attempt++)
        {
            await using var connection = new SqlConnection(_options.ConnectionString);
            try
            {
                await connection.OpenAsync(ct);
                return await action(connection);
            }
            catch (SqlException ex) when (ex.Number >= 50000)
            {
                // A rule XInfo enforced. Retrying will produce the same answer, and the
                // message is worth showing the rep, so it goes straight up.
                logger.LogInformation("XInfo rejected {Procedure}: {Message}", procedure, ex.Message);
                throw new XInfoRuleException(ex.Number, ex.Message);
            }
            catch (SqlException ex) when (IsTransient(ex) && attempt <= _options.MaxRetries)
            {
                var delay = _options.RetryBaseDelayMs * (int)Math.Pow(2, attempt - 1);
                logger.LogWarning(ex,
                    "Transient XInfo SQL error {Number} on {Procedure}; retry {Attempt} in {Delay}ms",
                    ex.Number, procedure, attempt, delay);
                await Task.Delay(delay, ct);
            }
            catch (SqlException ex)
            {
                // Out of retries, or not retryable. Either way the caller queues and tries
                // later rather than losing the message.
                throw new XInfoUnavailableException(
                    $"XInfo SQL error {ex.Number} calling {procedure}: {ex.Message}", ex);
            }
            catch (Exception ex) when (ex is TimeoutException or InvalidOperationException)
            {
                throw new XInfoUnavailableException($"Could not reach XInfo for {procedure}", ex);
            }
        }
    }

    private static bool IsTransient(SqlException ex) => ex.Number is
        1205 or   // deadlock victim
        -2 or     // timeout
        4060 or 40197 or 40501 or 40613 or
        10928 or 10929 or 10053 or 10054 or 10060 or 233 or 64;

    private sealed class DapperMultiResult(SqlMapper.GridReader grid) : IMultiResult
    {
        public async Task<IReadOnlyList<T>> ReadAsync<T>() => (await grid.ReadAsync<T>()).AsList();

        public Task<T?> ReadSingleOrDefaultAsync<T>() => grid.ReadFirstOrDefaultAsync<T>();
    }
}
