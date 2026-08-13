namespace XInfo.Gateway.Data.Sql;

/// <summary>
/// The only way this service touches XInfo's SQL Server, and it speaks exclusively in stored
/// procedures.
///
/// No ad-hoc SQL anywhere. That is not a style preference: this is someone else's database.
/// A query written here is a query their DBA never reviewed, cannot tune, and will break
/// without warning the next time they change a table. Confining every call to a named
/// procedure means the whole surface we depend on is visible to the people who own the
/// schema, and they can restructure underneath it freely.
/// </summary>
public interface ISqlExecutor
{
    Task<IReadOnlyList<T>> QueryAsync<T>(
        string procedure, object? parameters = null, CancellationToken ct = default);

    Task<T?> QuerySingleOrDefaultAsync<T>(
        string procedure, object? parameters = null, CancellationToken ct = default);

    Task<int> ExecuteAsync(
        string procedure, object? parameters = null, CancellationToken ct = default);

    /// <summary>A procedure returning several result sets — a header and its children in one trip.</summary>
    Task<T> QueryMultipleAsync<T>(
        string procedure,
        Func<IMultiResult, Task<T>> read,
        object? parameters = null,
        CancellationToken ct = default);
}

public interface IMultiResult
{
    Task<IReadOnlyList<T>> ReadAsync<T>();
    Task<T?> ReadSingleOrDefaultAsync<T>();
}

/// <summary>
/// A rule the procedure enforced, raised with <c>THROW 50000+</c> — a rejected expense, an
/// unknown customer, a stale opportunity update. Distinct from a fault: these carry a message
/// worth relaying and must not be retried.
/// </summary>
public sealed class XInfoRuleException(int errorNumber, string message) : Exception(message)
{
    public int ErrorNumber { get; } = errorNumber;
}

/// <summary>
/// XInfo could not be reached or failed in a way worth retrying. The outbox holds the message
/// and tries again rather than dropping it.
/// </summary>
public sealed class XInfoUnavailableException(string message, Exception? inner = null)
    : Exception(message, inner);
