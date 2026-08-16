namespace XInfo.Gateway.Data.Sql;

/// <summary>
/// Every stored procedure the gateway calls — the contract with the XInfo DBA.
///
/// This is not documentation that drifts. A test walks this list and the T-SQL under
/// <c>db/xinfo-mssql/</c> and fails the build when they disagree, so a procedure renamed on
/// either side is caught here rather than in an environment.
///
/// Naming: <c>xm.MobileGateway_[Subject]_[Verb]</c>. The <c>xm</c> schema keeps everything
/// XMobile depends on in one place inside XInfo's database, so their team can see the whole
/// surface at a glance and grant rights to exactly it; the <c>MobileGateway_</c> prefix makes
/// every one of these procedures instantly recognizable (and greppable) once it's ported into
/// XInfo's live database alongside their own procedures.
/// </summary>
public static class XInfoSprocs
{
    // ---------------------------------------------------------------- pull: master data
    public const string CustomersGetChanged = "xm.MobileGateway_Customers_GetChanged";
    public const string SitesGetChanged = "xm.MobileGateway_Sites_GetChanged";
    public const string ContactsGetChanged = "xm.MobileGateway_Contacts_GetChanged";
    public const string AssignmentsGetChanged = "xm.MobileGateway_Assignments_GetChanged";
    public const string UsersGetChanged = "xm.MobileGateway_Users_GetChanged";
    public const string OrgUnitsGetChanged = "xm.MobileGateway_OrgUnits_GetChanged";

    /// <summary>Targeted refresh for the ids a webhook told us about.</summary>
    public const string CustomersGetByIds = "xm.MobileGateway_Customers_GetByIds";

    // ---------------------------------------------------------------- pull: transactions
    public const string SalesHistoryGetChanged = "xm.MobileGateway_SalesHistory_GetChanged";
    public const string OpportunitiesGetChanged = "xm.MobileGateway_Opportunities_GetChanged";
    public const string ExpenseStatusGetChanged = "xm.MobileGateway_ExpenseStatus_GetChanged";

    // ---------------------------------------------------------------- pull: reference
    public const string ReferenceGetItems = "xm.MobileGateway_Reference_GetItems";
    public const string RatesGetCurrent = "xm.MobileGateway_Rates_GetCurrent";

    // ---------------------------------------------------------------- push: field-created records
    public const string CustomerPropose = "xm.MobileGateway_Customer_Propose";
    public const string SiteAdd = "xm.MobileGateway_Site_Add";
    public const string ContactAdd = "xm.MobileGateway_Contact_Add";
    public const string SiteCaptureGeo = "xm.MobileGateway_Site_CaptureGeo";

    // ---------------------------------------------------------------- push: field activity
    public const string OpportunityUpsert = "xm.MobileGateway_Opportunity_Upsert";
    public const string VisitPush = "xm.MobileGateway_Visit_Push";
    public const string TourPush = "xm.MobileGateway_Tour_Push";
    public const string ExpensePush = "xm.MobileGateway_Expense_Push";
    public const string ExpenseReceiptPush = "xm.MobileGateway_ExpenseReceipt_Push";
    public const string JourneySummaryPush = "xm.MobileGateway_JourneySummary_Push";

    // ---------------------------------------------------------------- reconciliation & health
    public const string ReconciliationGetSummary = "xm.MobileGateway_Reconciliation_GetSummary";
    public const string HealthCheck = "xm.MobileGateway_Health_Check";

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
