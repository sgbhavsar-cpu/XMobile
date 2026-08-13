namespace XInfo.Gateway.Data.Sql;

/// <summary>
/// Every stored procedure the gateway calls — the contract with the XInfo DBA.
///
/// This is not documentation that drifts. A test walks this list and the T-SQL under
/// <c>db/xinfo-mssql/</c> and fails the build when they disagree, so a procedure renamed on
/// either side is caught here rather than in an environment.
///
/// Naming: <c>xm.[Subject]_[Verb]</c>. The <c>xm</c> schema keeps everything XMobile depends
/// on in one place inside XInfo's database, so their team can see the whole surface at a
/// glance and grant rights to exactly it.
/// </summary>
public static class XInfoSprocs
{
    // ---------------------------------------------------------------- pull: master data
    public const string CustomersGetChanged = "xm.Customers_GetChanged";
    public const string SitesGetChanged = "xm.Sites_GetChanged";
    public const string ContactsGetChanged = "xm.Contacts_GetChanged";
    public const string AssignmentsGetChanged = "xm.Assignments_GetChanged";
    public const string UsersGetChanged = "xm.Users_GetChanged";
    public const string OrgUnitsGetChanged = "xm.OrgUnits_GetChanged";

    /// <summary>Targeted refresh for the ids a webhook told us about.</summary>
    public const string CustomersGetByIds = "xm.Customers_GetByIds";

    // ---------------------------------------------------------------- pull: transactions
    public const string SalesHistoryGetChanged = "xm.SalesHistory_GetChanged";
    public const string OpportunitiesGetChanged = "xm.Opportunities_GetChanged";
    public const string ExpenseStatusGetChanged = "xm.ExpenseStatus_GetChanged";

    // ---------------------------------------------------------------- pull: reference
    public const string ReferenceGetItems = "xm.Reference_GetItems";
    public const string RatesGetCurrent = "xm.Rates_GetCurrent";

    // ---------------------------------------------------------------- push: field-created records
    public const string CustomerPropose = "xm.Customer_Propose";
    public const string SiteAdd = "xm.Site_Add";
    public const string ContactAdd = "xm.Contact_Add";
    public const string SiteCaptureGeo = "xm.Site_CaptureGeo";

    // ---------------------------------------------------------------- push: field activity
    public const string OpportunityUpsert = "xm.Opportunity_Upsert";
    public const string VisitPush = "xm.Visit_Push";
    public const string TourPush = "xm.Tour_Push";
    public const string ExpensePush = "xm.Expense_Push";
    public const string ExpenseReceiptPush = "xm.ExpenseReceipt_Push";
    public const string JourneySummaryPush = "xm.JourneySummary_Push";

    // ---------------------------------------------------------------- reconciliation & health
    public const string ReconciliationGetSummary = "xm.Reconciliation_GetSummary";
    public const string HealthCheck = "xm.Health_Check";

    /// <summary>
    /// Every name above. Used by the drift test, and by the readiness probe that verifies the
    /// procedures actually exist before a deployment is called healthy — a missing procedure
    /// should fail at startup, not at 6am when a rep submits an expense.
    /// </summary>
    public static IReadOnlyList<string> All { get; } = typeof(XInfoSprocs)
        .GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)
        .Where(f => f.IsLiteral && f.FieldType == typeof(string))
        .Select(f => (string)f.GetRawConstantValue()!)
        .OrderBy(name => name, StringComparer.Ordinal)
        .ToList();
}
