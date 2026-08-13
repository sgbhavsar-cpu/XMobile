using XInfo.Gateway.Data.Sql;

namespace XInfo.Gateway.Tests;

/// <summary>
/// Stands in for XInfo's SQL Server, which is not available here — and will not be available
/// on any developer's machine either.
///
/// It does two jobs. It returns canned rows so the gateway's own logic (paging, cursors,
/// validation, error mapping) can be exercised; and it *records every call*, so the tests can
/// assert which procedure was invoked and with which parameters. That second job is the
/// important one: it is how the contract handed to the DBA stays honest without a database
/// to run against.
/// </summary>
public sealed class FakeSqlExecutor : ISqlExecutor
{
    private readonly Dictionary<string, Func<object?, object>> _handlers = [];

    public List<RecordedCall> Calls { get; } = [];

    public sealed record RecordedCall(string Procedure, IReadOnlyDictionary<string, object?> Parameters);

    /// <summary>Canned rows for a procedure.</summary>
    public FakeSqlExecutor Returns<T>(string procedure, IEnumerable<T> rows)
    {
        _handlers[procedure] = _ => rows.ToList();
        return this;
    }

    /// <summary>Canned rows that depend on the parameters, for paging tests.</summary>
    public FakeSqlExecutor Returns<T>(string procedure, Func<IReadOnlyDictionary<string, object?>, IEnumerable<T>> rows)
    {
        _handlers[procedure] = parameters => rows(Describe(parameters)).ToList();
        return this;
    }

    /// <summary>Makes a procedure fail the way XInfo would.</summary>
    public FakeSqlExecutor Throws(string procedure, Exception error)
    {
        _handlers[procedure] = _ => throw error;
        return this;
    }

    public IReadOnlyDictionary<string, object?> ParametersFor(string procedure)
        => Calls.Single(c => c.Procedure == procedure).Parameters;

    public bool WasCalled(string procedure) => Calls.Any(c => c.Procedure == procedure);

    public Task<IReadOnlyList<T>> QueryAsync<T>(
        string procedure, object? parameters = null, CancellationToken ct = default)
    {
        Record(procedure, parameters);
        var result = Invoke(procedure, parameters);
        return Task.FromResult<IReadOnlyList<T>>(result is List<T> typed ? typed : []);
    }

    public Task<T?> QuerySingleOrDefaultAsync<T>(
        string procedure, object? parameters = null, CancellationToken ct = default)
    {
        Record(procedure, parameters);
        var result = Invoke(procedure, parameters);
        return Task.FromResult(result is List<T> typed ? typed.FirstOrDefault() : default);
    }

    public Task<int> ExecuteAsync(
        string procedure, object? parameters = null, CancellationToken ct = default)
    {
        Record(procedure, parameters);
        Invoke(procedure, parameters);
        return Task.FromResult(1);
    }

    public async Task<T> QueryMultipleAsync<T>(
        string procedure,
        Func<IMultiResult, Task<T>> read,
        object? parameters = null,
        CancellationToken ct = default)
    {
        Record(procedure, parameters);
        var result = Invoke(procedure, parameters);
        return await read(new FakeMultiResult(result as System.Collections.IEnumerable));
    }

    private object? Invoke(string procedure, object? parameters)
        => _handlers.TryGetValue(procedure, out var handler) ? handler(parameters) : null;

    private void Record(string procedure, object? parameters)
        => Calls.Add(new RecordedCall(procedure, Describe(parameters)));

    /// <summary>
    /// Flattens whatever was passed — anonymous object or Dapper parameters — into a plain
    /// dictionary the assertions can read.
    /// </summary>
    private static IReadOnlyDictionary<string, object?> Describe(object? parameters)
    {
        if (parameters is null) return new Dictionary<string, object?>();

        if (parameters is Dapper.DynamicParameters dynamic)
        {
            return dynamic.ParameterNames.ToDictionary(
                name => name,
                name => dynamic.Get<object?>(name));
        }

        return parameters.GetType().GetProperties()
            .ToDictionary(p => p.Name, p => p.GetValue(parameters));
    }

    private sealed class FakeMultiResult(System.Collections.IEnumerable? rows) : IMultiResult
    {
        private readonly Queue<object> _sets = rows is null
            ? new Queue<object>()
            : new Queue<object>(rows.Cast<object>());

        public Task<IReadOnlyList<T>> ReadAsync<T>()
        {
            if (_sets.Count == 0) return Task.FromResult<IReadOnlyList<T>>([]);

            var next = _sets.Dequeue();
            return Task.FromResult<IReadOnlyList<T>>(
                next is IEnumerable<T> typed ? typed.ToList() : []);
        }

        public Task<T?> ReadSingleOrDefaultAsync<T>()
        {
            if (_sets.Count == 0) return Task.FromResult<T?>(default);

            var next = _sets.Dequeue();
            return Task.FromResult(next is IEnumerable<T> typed ? typed.FirstOrDefault() : default);
        }
    }
}
