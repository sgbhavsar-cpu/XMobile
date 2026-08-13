using XInfo.Gateway.Contracts;
using XInfo.Gateway.Data.Repositories;
using XInfo.Gateway.Data.Sql;
using Xunit;

namespace XInfo.Gateway.Tests;

/// <summary>
/// Everything the gateway does above the SQL round trip.
///
/// What these cannot cover is stated plainly: no SQL Server is available here, so the
/// procedures themselves are unverified until the DBA's release lands. What they do cover is
/// the part that is ours — paging, cursors, idempotency, error classification, and the exact
/// procedure names and parameters the DBA is being asked to implement.
/// </summary>
public class PullTests
{
    private static XInfoCustomer Customer(string id, DateTimeOffset modified) => new(
        id, $"Customer {id}", null, null, "DEALER", "B", null, null, "E1001", "AREA_PUNE",
        null, null, null, null, true, modified);

    [Fact]
    public async Task Paging_returns_a_cursor_only_when_more_remains()
    {
        var now = DateTimeOffset.UtcNow;
        var sql = new FakeSqlExecutor().Returns(XInfoSprocs.CustomersGetChanged,
            Enumerable.Range(1, 6).Select(i => Customer($"C{i}", now.AddMinutes(i))));

        var repo = new SqlPullRepository(sql);

        // Asking for five with six available: the extra row is how "is there more?" is known
        // without a second COUNT(*) over the same range.
        var page = await repo.GetCustomersAsync(null, null, 5, default);

        Assert.Equal(5, page.Items.Count);
        Assert.True(page.HasMore);
        Assert.NotNull(page.NextCursor);
    }

    [Fact]
    public async Task Last_page_carries_no_cursor()
    {
        var now = DateTimeOffset.UtcNow;
        var sql = new FakeSqlExecutor().Returns(XInfoSprocs.CustomersGetChanged,
            Enumerable.Range(1, 3).Select(i => Customer($"C{i}", now.AddMinutes(i))));

        var page = await new SqlPullRepository(sql).GetCustomersAsync(null, null, 5, default);

        Assert.Equal(3, page.Items.Count);
        Assert.False(page.HasMore);
        Assert.Null(page.NextCursor);
    }

    [Fact]
    public async Task Requests_one_more_row_than_the_page_size()
    {
        var sql = new FakeSqlExecutor().Returns(XInfoSprocs.CustomersGetChanged, Array.Empty<XInfoCustomer>());

        await new SqlPullRepository(sql).GetCustomersAsync(null, null, 100, default);

        Assert.Equal(101, sql.ParametersFor(XInfoSprocs.CustomersGetChanged)["PageSize"]);
    }

    [Fact]
    public async Task Page_size_is_capped_so_a_typo_cannot_scan_their_table()
    {
        var sql = new FakeSqlExecutor().Returns(XInfoSprocs.CustomersGetChanged, Array.Empty<XInfoCustomer>());

        await new SqlPullRepository(sql).GetCustomersAsync(null, null, 100_000, default);

        Assert.Equal(SqlPullRepository.MaxPageSize + 1,
            sql.ParametersFor(XInfoSprocs.CustomersGetChanged)["PageSize"]);
    }

    [Fact]
    public async Task Cursor_carries_both_timestamp_and_id_to_the_procedure()
    {
        var now = DateTimeOffset.UtcNow;
        var sql = new FakeSqlExecutor().Returns(XInfoSprocs.CustomersGetChanged,
            Enumerable.Range(1, 6).Select(i => Customer($"C{i}", now)));

        var repo = new SqlPullRepository(sql);
        var first = await repo.GetCustomersAsync(null, null, 5, default);
        await repo.GetCustomersAsync(null, first.NextCursor, 5, default);

        var second = sql.Calls.Last().Parameters;

        // A bulk update in XInfo stamps hundreds of rows with the same ModifiedAt. Without
        // the id tie-break, the next page either loses the rest of that second or repeats it
        // forever.
        Assert.NotNull(second["AfterModifiedAt"]);
        Assert.Equal("C5", second["AfterId"]);
    }

    [Fact]
    public void An_unreadable_cursor_restarts_rather_than_failing()
    {
        // Duplicates are absorbed by our upsert; a stuck sync is not.
        var (modifiedAt, id) = Cursor.Parse("not-a-real-cursor");

        Assert.Null(modifiedAt);
        Assert.Null(id);
    }

    [Fact]
    public void Cursor_round_trips()
    {
        var when = new DateTimeOffset(2026, 8, 12, 9, 30, 0, TimeSpan.FromHours(5.5));
        var (modifiedAt, id) = Cursor.Parse(Cursor.Create(when, "XI-9001"));

        Assert.Equal(when, modifiedAt);
        Assert.Equal("XI-9001", id);
    }

    [Fact]
    public async Task Asking_for_no_ids_does_not_call_the_database()
    {
        var sql = new FakeSqlExecutor();

        var result = await new SqlPullRepository(sql).GetCustomersByIdsAsync([], default);

        Assert.Empty(result);
        Assert.Empty(sql.Calls);
    }
}

public class PushTests
{
    private static PushEnvelope<T> Envelope<T>(T payload, string key = "expense:abc:v1") =>
        new(Guid.NewGuid(), key, DateTimeOffset.UtcNow, "E1001", payload);

    private static ExpenseCapturedCommand Expense(IReadOnlyList<ExpenseReceiptRef>? receipts = null) => new(
        Guid.NewGuid(), null, null, "TRAVEL_RAIL", DateTimeOffset.UtcNow, 2450m, "INR",
        "UPI", "IRCTC", "42139910", null, "RAIL", "Pune", "Nagpur", null, null, null,
        receipts ?? []);

    private static FakeSqlExecutor Accepting(string procedure, string xinfoId = "XI-1", bool duplicate = false)
        => new FakeSqlExecutor().Returns(procedure,
            new[] { new SqlPushRepository.PushResultRow(true, xinfoId, duplicate, null) });

    [Fact]
    public async Task Every_push_carries_the_idempotency_envelope()
    {
        var sql = Accepting(XInfoSprocs.ExpensePush);

        await new SqlPushRepository(sql).PushExpenseAsync(Envelope(Expense()), default);

        var parameters = sql.ParametersFor(XInfoSprocs.ExpensePush);

        // Without these, a retried delivery creates a second expense and someone is paid
        // twice. This is the single most important property of the whole push path.
        Assert.Equal("expense:abc:v1", parameters["IdempotencyKey"]);
        Assert.NotNull(parameters["MessageId"]);
        Assert.Equal("E1001", parameters["EmployeeCode"]);
    }

    [Fact]
    public async Task A_duplicate_is_reported_rather_than_written_twice()
    {
        var sql = Accepting(XInfoSprocs.ExpensePush, "XI-77", duplicate: true);

        var result = await new SqlPushRepository(sql).PushExpenseAsync(Envelope(Expense()), default);

        Assert.True(result.WasDuplicate);
        Assert.Equal("XI-77", result.XinfoId);
    }

    [Fact]
    public async Task Receipts_follow_the_expense_and_are_skipped_on_a_duplicate()
    {
        var receipts = new[]
        {
            new ExpenseReceiptRef(Guid.NewGuid(), "upi.jpg", "image/jpeg", 1024, "https://x/1", null)
        };

        var fresh = Accepting(XInfoSprocs.ExpensePush)
            .Returns(XInfoSprocs.ExpenseReceiptPush, Array.Empty<object>());
        await new SqlPushRepository(fresh).PushExpenseAsync(Envelope(Expense(receipts)), default);
        Assert.True(fresh.WasCalled(XInfoSprocs.ExpenseReceiptPush));

        // On a replay the receipt is already there; sending it again would duplicate the file.
        var replay = Accepting(XInfoSprocs.ExpensePush, duplicate: true)
            .Returns(XInfoSprocs.ExpenseReceiptPush, Array.Empty<object>());
        await new SqlPushRepository(replay).PushExpenseAsync(Envelope(Expense(receipts)), default);
        Assert.False(replay.WasCalled(XInfoSprocs.ExpenseReceiptPush));
    }

    [Fact]
    public async Task An_opportunity_update_sends_the_ordering_token()
    {
        var updatedAt = DateTimeOffset.UtcNow.AddMinutes(-30);
        var sql = Accepting(XInfoSprocs.OpportunityUpsert);

        await new SqlPushRepository(sql).UpsertOpportunityAsync(Envelope(
            new UpsertOpportunityCommand(
                Guid.NewGuid(), "XI-OPP-1", "XI-9001", "Q4 supply", null, "NEGOTIATION",
                450000m, null, 75, null, null, null, updatedAt, null)), default);

        // This is what lets XInfo reject an edit older than what it holds — the rule that
        // makes a two-way entity safe when a rep edits offline and XInfo edits meanwhile.
        Assert.Equal(updatedAt, sql.ParametersFor(XInfoSprocs.OpportunityUpsert)["RepFieldsUpdatedAt"]);
    }

    [Fact]
    public async Task A_push_procedure_returning_nothing_is_treated_as_a_failure()
    {
        // Silence would leave us with no XInfo id to reconcile against, so it must not be
        // mistaken for success.
        var sql = new FakeSqlExecutor().Returns(
            XInfoSprocs.ExpensePush, Array.Empty<SqlPushRepository.PushResultRow>());

        await Assert.ThrowsAsync<XInfoUnavailableException>(
            () => new SqlPushRepository(sql).PushExpenseAsync(Envelope(Expense()), default));
    }

    [Fact]
    public async Task Linked_opportunities_travel_with_the_visit()
    {
        var opportunityId = Guid.NewGuid();
        var sql = Accepting(XInfoSprocs.VisitPush);

        await new SqlPushRepository(sql).PushVisitAsync(Envelope(new VisitCompletedCommand(
            Guid.NewGuid(), "XI-9001", null, null, "SALES_CALL", DateTimeOffset.UtcNow,
            DateTimeOffset.UtcNow.AddMinutes(45), 45, null, null, null, false, null, false,
            "ORDER_BOOKED", "Agreed volumes", null, null, false, null, false, null,
            """{"stock_checked":true}""", [opportunityId])), default);

        var parameters = sql.ParametersFor(XInfoSprocs.VisitPush);

        // The visit-to-deal link is what turns a visit report into pipeline analytics.
        Assert.Equal(opportunityId.ToString(), parameters["LinkedOpportunityIds"]);
        Assert.Equal("""{"stock_checked":true}""", parameters["DynamicAnswersJson"]);
    }

    [Fact]
    public async Task Reconciliation_returns_the_refs_XInfo_holds()
    {
        var sql = new FakeSqlExecutor().Returns(XInfoSprocs.ReconciliationGetSummary, new object[]
        {
            new[] { new SqlPushRepository.ReconciliationRow(12, 48500m) },
            new[] { "expense:a", "expense:b" }
        });

        var summary = await new SqlPushRepository(sql).GetReconciliationAsync(
            "expense", DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow, "E1001", default);

        Assert.NotNull(summary);
        Assert.Equal(12, summary!.RecordCount);
        Assert.Equal(48500m, summary.TotalAmount);
        Assert.Equal(2, summary.ExternalRefs.Count);
    }
}

public class ErrorClassificationTests
{
    [Fact]
    public async Task A_rule_XInfo_enforced_is_not_retryable()
    {
        // 50000+ means XInfo decided. Retrying produces the same answer, so it must surface
        // rather than sit in the outbox forever.
        var sql = new FakeSqlExecutor().Throws(
            XInfoSprocs.ExpensePush, new XInfoRuleException(50001, "Category not recognised"));

        var error = await Assert.ThrowsAsync<XInfoRuleException>(() =>
            new SqlPushRepository(sql).PushExpenseAsync(
                new PushEnvelope<ExpenseCapturedCommand>(
                    Guid.NewGuid(), "k", DateTimeOffset.UtcNow, "E1001",
                    new ExpenseCapturedCommand(Guid.NewGuid(), null, null, "NOPE",
                        DateTimeOffset.UtcNow, 10m, "INR", null, null, null, null, null, null,
                        null, null, null, null, [])),
                default));

        Assert.Equal(50001, error.ErrorNumber);
    }

    [Fact]
    public async Task An_unreachable_XInfo_is_retryable_and_says_so()
    {
        var sql = new FakeSqlExecutor().Throws(
            XInfoSprocs.CustomersGetChanged, new XInfoUnavailableException("connection reset"));

        await Assert.ThrowsAsync<XInfoUnavailableException>(
            () => new SqlPullRepository(sql).GetCustomersAsync(null, null, 10, default));
    }
}

public class SprocCatalogueTests
{
    [Fact]
    public void Catalogue_is_complete_and_consistently_named()
    {
        Assert.NotEmpty(XInfoSprocs.All);
        Assert.All(XInfoSprocs.All, name => Assert.StartsWith("xm.", name, StringComparison.Ordinal));

        // Duplicates would mean two constants pointing at one procedure, which hides a
        // rename from the drift check below.
        Assert.Equal(XInfoSprocs.All.Count, XInfoSprocs.All.Distinct().Count());
    }

    [Fact]
    public void The_code_and_the_DBA_contract_declare_exactly_the_same_procedures()
    {
        // The contract is only useful if it cannot drift, so this compares the DECLARED
        // procedure names in both directions.
        //
        // A substring check is not enough and gives false confidence: renaming
        // xm.Expense_Push to xm.Expense_PushRenamed in the T-SQL still "contains" the
        // original name, so a rename — the very thing this test exists to catch — passes
        // unnoticed.
        var declared = DeclaredProcedures();
        var called = XInfoSprocs.All.ToHashSet(StringComparer.OrdinalIgnoreCase);

        var missingFromSql = called.Except(declared, StringComparer.OrdinalIgnoreCase).ToList();
        var notCalled = declared.Except(called, StringComparer.OrdinalIgnoreCase).ToList();

        Assert.True(missingFromSql.Count == 0,
            $"Called in code but not declared for the DBA: {string.Join(", ", missingFromSql)}");

        // The reverse matters too: a procedure the DBA has been asked to write that nothing
        // calls is work nobody needed, and usually means a rename landed on one side only.
        Assert.True(notCalled.Count == 0,
            $"Declared for the DBA but never called: {string.Join(", ", notCalled)}");
    }

    [Fact]
    public void Every_push_procedure_takes_an_idempotency_key()
    {
        // Idempotency is the property that stops a retried delivery paying an expense twice.
        // It has to be in the signature the DBA implements, not only in our intent.
        var tsql = File.ReadAllText(ContractPath());

        var pushProcedures = XInfoSprocs.All
            .Where(name => name.Contains("_Push", StringComparison.Ordinal)
                           || name.EndsWith("_Propose", StringComparison.Ordinal)
                           || name.EndsWith("_Upsert", StringComparison.Ordinal)
                           || name.EndsWith("_Add", StringComparison.Ordinal)
                           || name.EndsWith("_CaptureGeo", StringComparison.Ordinal))
            .Where(name => name != XInfoSprocs.ExpenseReceiptPush)   // rides the parent expense
            .ToList();

        Assert.NotEmpty(pushProcedures);

        foreach (var procedure in pushProcedures)
        {
            var body = BodyOf(tsql, procedure);
            Assert.True(body.Contains("@IdempotencyKey", StringComparison.Ordinal),
                $"{procedure} must take @IdempotencyKey so a retry cannot duplicate the record");
        }
    }

    private static HashSet<string> DeclaredProcedures()
    {
        var tsql = File.ReadAllText(ContractPath());
        return System.Text.RegularExpressions.Regex
            .Matches(tsql, @"CREATE\s+OR\s+ALTER\s+PROCEDURE\s+(xm\.[A-Za-z0-9_]+)",
                System.Text.RegularExpressions.RegexOptions.IgnoreCase)
            .Select(m => m.Groups[1].Value)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>The text of one procedure declaration, up to its AS.</summary>
    private static string BodyOf(string tsql, string procedure)
    {
        var start = tsql.IndexOf($"PROCEDURE {procedure}", StringComparison.OrdinalIgnoreCase);
        Assert.True(start >= 0, $"{procedure} is not declared in the contract");

        var end = tsql.IndexOf("\nAS\n", start, StringComparison.OrdinalIgnoreCase);
        return end < 0 ? tsql[start..] : tsql[start..end];
    }

    private static string ContractPath()
    {
        var path = Path.Combine(FindRepositoryRoot(), "db", "xinfo-mssql", "01_procedures.sql");
        Assert.True(File.Exists(path), $"Expected the DBA contract at {path}");
        return path;
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, ".git")))
        {
            directory = directory.Parent;
        }
        return directory?.FullName ?? throw new InvalidOperationException("Repository root not found");
    }
}
