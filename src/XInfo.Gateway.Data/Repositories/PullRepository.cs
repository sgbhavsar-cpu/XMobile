using XInfo.Gateway.Contracts;
using XInfo.Gateway.Data.Sql;

namespace XInfo.Gateway.Data.Repositories;

/// <summary>Everything XInfo owns and we read.</summary>
public interface IPullRepository
{
    Task<XInfoPage<XInfoCustomer>> GetCustomersAsync(DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct);
    Task<IReadOnlyList<XInfoCustomer>> GetCustomersByIdsAsync(IReadOnlyList<string> xinfoIds, CancellationToken ct);
    Task<XInfoPage<XInfoSite>> GetSitesAsync(DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct);
    Task<XInfoPage<XInfoContact>> GetContactsAsync(DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct);
    Task<XInfoPage<XInfoAssignment>> GetAssignmentsAsync(DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct);
    Task<XInfoPage<XInfoUser>> GetUsersAsync(DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct);
    Task<XInfoPage<XInfoOrgUnit>> GetOrgUnitsAsync(DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct);
    Task<XInfoPage<XInfoSalesDocument>> GetSalesHistoryAsync(DateTimeOffset? since, string? customerXinfoId, string? cursor, int pageSize, CancellationToken ct);
    Task<XInfoPage<XInfoOpportunity>> GetOpportunitiesAsync(DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct);
    Task<XInfoPage<XInfoExpenseStatus>> GetExpenseStatusesAsync(DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct);
    Task<IReadOnlyList<XInfoReferenceItem>> GetReferenceItemsAsync(string? domain, CancellationToken ct);
    Task<IReadOnlyList<XInfoRate>> GetRatesAsync(DateTimeOffset asOf, CancellationToken ct);
}

public sealed class SqlPullRepository(ISqlExecutor sql) : IPullRepository
{
    /// <summary>
    /// Ceiling on what one call can return. XInfo is a shared system: a page size someone
    /// mistypes as 100000 must not turn into a table scan that hurts their users.
    /// </summary>
    public const int MaxPageSize = 2000;

    public Task<XInfoPage<XInfoCustomer>> GetCustomersAsync(
        DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct)
        => PageAsync<XInfoCustomer>(XInfoSprocs.CustomersGetChanged, since, cursor, pageSize,
            c => c.XinfoId, c => c.ModifiedAt, ct);

    public Task<IReadOnlyList<XInfoCustomer>> GetCustomersByIdsAsync(
        IReadOnlyList<string> xinfoIds, CancellationToken ct)
        => xinfoIds.Count == 0
            ? Task.FromResult<IReadOnlyList<XInfoCustomer>>([])
            : sql.QueryAsync<XInfoCustomer>(XInfoSprocs.CustomersGetByIds,
                new { XinfoIds = string.Join(',', xinfoIds) }, ct);

    public Task<XInfoPage<XInfoSite>> GetSitesAsync(
        DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct)
        => PageAsync<XInfoSite>(XInfoSprocs.SitesGetChanged, since, cursor, pageSize,
            s => s.XinfoId, s => s.ModifiedAt, ct);

    public Task<XInfoPage<XInfoContact>> GetContactsAsync(
        DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct)
        => PageAsync<XInfoContact>(XInfoSprocs.ContactsGetChanged, since, cursor, pageSize,
            c => c.XinfoId, c => c.ModifiedAt, ct);

    public Task<XInfoPage<XInfoAssignment>> GetAssignmentsAsync(
        DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct)
        => PageAsync<XInfoAssignment>(XInfoSprocs.AssignmentsGetChanged, since, cursor, pageSize,
            a => $"{a.CustomerXinfoId}|{a.EmployeeCode}", a => a.ModifiedAt, ct);

    public Task<XInfoPage<XInfoUser>> GetUsersAsync(
        DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct)
        => PageAsync<XInfoUser>(XInfoSprocs.UsersGetChanged, since, cursor, pageSize,
            u => u.EmployeeCode, u => u.ModifiedAt, ct);

    public Task<XInfoPage<XInfoOrgUnit>> GetOrgUnitsAsync(
        DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct)
        => PageAsync<XInfoOrgUnit>(XInfoSprocs.OrgUnitsGetChanged, since, cursor, pageSize,
            o => o.Code, o => o.ModifiedAt, ct);

    public Task<XInfoPage<XInfoSalesDocument>> GetSalesHistoryAsync(
        DateTimeOffset? since, string? customerXinfoId, string? cursor, int pageSize,
        CancellationToken ct)
        => PageAsync<XInfoSalesDocument>(XInfoSprocs.SalesHistoryGetChanged, since, cursor, pageSize,
            d => d.XinfoId, d => d.ModifiedAt, ct,
            extra: new { CustomerXinfoId = customerXinfoId });

    public Task<XInfoPage<XInfoOpportunity>> GetOpportunitiesAsync(
        DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct)
        => PageAsync<XInfoOpportunity>(XInfoSprocs.OpportunitiesGetChanged, since, cursor, pageSize,
            o => o.XinfoId, o => o.ModifiedAt, ct);

    public Task<XInfoPage<XInfoExpenseStatus>> GetExpenseStatusesAsync(
        DateTimeOffset? since, string? cursor, int pageSize, CancellationToken ct)
        => PageAsync<XInfoExpenseStatus>(XInfoSprocs.ExpenseStatusGetChanged, since, cursor, pageSize,
            s => s.ExternalRef, s => s.ModifiedAt, ct);

    public Task<IReadOnlyList<XInfoReferenceItem>> GetReferenceItemsAsync(
        string? domain, CancellationToken ct)
        => sql.QueryAsync<XInfoReferenceItem>(XInfoSprocs.ReferenceGetItems,
            new { Domain = domain }, ct);

    public Task<IReadOnlyList<XInfoRate>> GetRatesAsync(DateTimeOffset asOf, CancellationToken ct)
        => sql.QueryAsync<XInfoRate>(XInfoSprocs.RatesGetCurrent, new { AsOf = asOf }, ct);

    /// <summary>
    /// Keyset paging over (ModifiedAt, Id).
    ///
    /// The tie-break on id matters: a bulk update in XInfo stamps hundreds of rows with the
    /// same ModifiedAt, and a watermark on the timestamp alone either loses the rest of that
    /// second or replays it forever.
    /// </summary>
    private async Task<XInfoPage<T>> PageAsync<T>(
        string procedure,
        DateTimeOffset? since,
        string? cursor,
        int pageSize,
        Func<T, string> idOf,
        Func<T, DateTimeOffset> modifiedOf,
        CancellationToken ct,
        object? extra = null)
    {
        var size = Math.Clamp(pageSize <= 0 ? 500 : pageSize, 1, MaxPageSize);
        var (cursorModifiedAt, cursorId) = Cursor.Parse(cursor);

        var parameters = new DynamicParametersBuilder()
            .Add("ModifiedSince", since ?? cursorModifiedAt)
            .Add("AfterModifiedAt", cursorModifiedAt)
            .Add("AfterId", cursorId)
            // One extra row is the cheapest way to know whether another page exists without
            // a second COUNT(*) over the same range.
            .Add("PageSize", size + 1)
            .Merge(extra)
            .Build();

        var rows = await sql.QueryAsync<T>(procedure, parameters, ct);

        var hasMore = rows.Count > size;
        var items = hasMore ? rows.Take(size).ToList() : rows;

        var next = items.Count == 0 || !hasMore
            ? null
            : Cursor.Create(modifiedOf(items[^1]), idOf(items[^1]));

        return new XInfoPage<T>(items, next, hasMore, DateTimeOffset.UtcNow);
    }
}

/// <summary>Opaque keyset cursor: the last (ModifiedAt, Id) delivered.</summary>
public static class Cursor
{
    public static string Create(DateTimeOffset modifiedAt, string id)
        => Convert.ToBase64String(
            System.Text.Encoding.UTF8.GetBytes($"{modifiedAt:O}|{id}"));

    public static (DateTimeOffset? ModifiedAt, string? Id) Parse(string? cursor)
    {
        if (string.IsNullOrWhiteSpace(cursor)) return (null, null);

        try
        {
            var raw = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(cursor));
            var parts = raw.Split('|', 2);
            return parts.Length == 2 && DateTimeOffset.TryParse(parts[0], out var modifiedAt)
                ? (modifiedAt, parts[1])
                : (null, null);
        }
        catch (FormatException)
        {
            // A cursor we cannot read means start again rather than fail: the caller gets
            // duplicates, which their upsert absorbs, instead of a stuck sync.
            return (null, null);
        }
    }
}

/// <summary>Small helper so paging parameters stay readable next to per-entity extras.</summary>
internal sealed class DynamicParametersBuilder
{
    private readonly Dictionary<string, object?> _values = [];

    public DynamicParametersBuilder Add(string name, object? value)
    {
        _values[name] = value;
        return this;
    }

    public DynamicParametersBuilder Merge(object? extra)
    {
        if (extra is null) return this;

        foreach (var property in extra.GetType().GetProperties())
        {
            _values[property.Name] = property.GetValue(extra);
        }
        return this;
    }

    public object Build()
    {
        var parameters = new Dapper.DynamicParameters();
        foreach (var (name, value) in _values) parameters.Add(name, value);
        return parameters;
    }
}
