using XInfo.Gateway.Contracts;
using XInfo.Gateway.Data.Sql;

namespace XInfo.Gateway.Data.Repositories;

/// <summary>Everything XMobile owns and writes into XInfo.</summary>
public interface IPushRepository
{
    Task<PushResult> ProposeCustomerAsync(PushEnvelope<ProposeCustomerCommand> message, CancellationToken ct);
    Task<PushResult> AddSiteAsync(PushEnvelope<AddSiteCommand> message, CancellationToken ct);
    Task<PushResult> AddContactAsync(PushEnvelope<AddContactCommand> message, CancellationToken ct);
    Task<PushResult> CaptureGeoAsync(PushEnvelope<CaptureGeoCommand> message, CancellationToken ct);
    Task<PushResult> UpsertOpportunityAsync(PushEnvelope<UpsertOpportunityCommand> message, CancellationToken ct);
    Task<PushResult> PushVisitAsync(PushEnvelope<VisitCompletedCommand> message, CancellationToken ct);
    Task<PushResult> PushTourAsync(PushEnvelope<TourCompletedCommand> message, CancellationToken ct);
    Task<PushResult> PushExpenseAsync(PushEnvelope<ExpenseCapturedCommand> message, CancellationToken ct);
    Task<PushResult> PushJourneySummaryAsync(PushEnvelope<JourneyDailySummaryCommand> message, CancellationToken ct);
    Task<XInfoReconciliationSummary?> GetReconciliationAsync(string entity, DateTimeOffset from, DateTimeOffset to, string? employeeCode, CancellationToken ct);
    Task<bool> HealthCheckAsync(CancellationToken ct);
}

public sealed class SqlPushRepository(ISqlExecutor sql) : IPushRepository
{
    public Task<PushResult> ProposeCustomerAsync(
        PushEnvelope<ProposeCustomerCommand> message, CancellationToken ct)
    {
        var c = message.Payload;
        return PushAsync(XInfoSprocs.CustomerPropose, message, new
        {
            XmobileCustomerId = c.XmobileCustomerId,
            c.Name,
            c.AccountType,
            c.Phone,
            c.Email,
            c.GstNumber,
            c.Note,
            SiteXmobileId = c.Site.XmobileSiteId,
            SiteName = c.Site.Name,
            c.Site.AddressLine1,
            c.Site.City,
            c.Site.State,
            c.Site.PostalCode,
            c.Site.Lat,
            c.Site.Lon,
            ContactXmobileId = c.Contact?.XmobileContactId,
            ContactName = c.Contact?.FullName,
            ContactDesignation = c.Contact?.Designation,
            ContactPhone = c.Contact?.Phone,
            ContactEmail = c.Contact?.Email
        }, ct);
    }

    public Task<PushResult> AddSiteAsync(
        PushEnvelope<AddSiteCommand> message, CancellationToken ct)
    {
        var s = message.Payload;
        return PushAsync(XInfoSprocs.SiteAdd, message, new
        {
            s.CustomerXinfoId,
            s.XmobileSiteId,
            s.Name,
            s.AddressLine1,
            s.City,
            s.State,
            s.PostalCode,
            s.Lat,
            s.Lon
        }, ct);
    }

    public Task<PushResult> AddContactAsync(
        PushEnvelope<AddContactCommand> message, CancellationToken ct)
    {
        var c = message.Payload;
        return PushAsync(XInfoSprocs.ContactAdd, message, new
        {
            c.CustomerXinfoId,
            c.XmobileContactId,
            c.FullName,
            c.Designation,
            c.Phone,
            c.Email
        }, ct);
    }

    public Task<PushResult> CaptureGeoAsync(
        PushEnvelope<CaptureGeoCommand> message, CancellationToken ct)
    {
        var g = message.Payload;
        return PushAsync(XInfoSprocs.SiteCaptureGeo, message, new
        {
            g.SiteXinfoId,
            g.XmobileSiteId,
            g.Lat,
            g.Lon,
            g.AccuracyM,
            g.CapturedAt
        }, ct);
    }

    public Task<PushResult> UpsertOpportunityAsync(
        PushEnvelope<UpsertOpportunityCommand> message, CancellationToken ct)
    {
        var o = message.Payload;

        // Only rep-owned fields go up, and RepFieldsUpdatedAt lets XInfo reject an update
        // older than what it holds. That ordering token is what makes a two-way entity safe
        // when a rep edits offline and XInfo edits meanwhile.
        return PushAsync(XInfoSprocs.OpportunityUpsert, message, new
        {
            o.XmobileOpportunityId,
            o.XinfoId,
            o.CustomerXinfoId,
            o.Title,
            o.Description,
            o.StageCode,
            o.EstimatedValue,
            o.ExpectedCloseDate,
            o.ProbabilityPct,
            o.Competitor,
            o.CloseReasonCode,
            o.ActualValue,
            o.RepFieldsUpdatedAt,
            o.VisitId
        }, ct);
    }

    public Task<PushResult> PushVisitAsync(
        PushEnvelope<VisitCompletedCommand> message, CancellationToken ct)
    {
        var v = message.Payload;
        return PushAsync(XInfoSprocs.VisitPush, message, new
        {
            v.VisitId,
            v.CustomerXinfoId,
            v.SiteXinfoId,
            v.ContactXinfoId,
            v.VisitTypeCode,
            v.CheckInAt,
            v.CheckOutAt,
            v.DurationMin,
            v.CheckInLat,
            v.CheckInLon,
            v.CheckInDistanceM,
            v.IsOutOfGeofence,
            v.OutOfFenceReasonCode,
            v.IsUnplanned,
            v.OutcomeCode,
            v.Summary,
            v.NextAction,
            v.FollowUpDate,
            v.OrderIntent,
            v.OrderValueEst,
            v.CompetitorSeen,
            v.CompetitorNotes,
            // The dynamic section travels as JSON: its shape is defined by an admin-published
            // template, so it cannot be columns without a schema change per template version.
            v.DynamicAnswersJson,
            LinkedOpportunityIds = v.LinkedOpportunityIds is null
                ? null
                : string.Join(',', v.LinkedOpportunityIds)
        }, ct);
    }

    public Task<PushResult> PushTourAsync(
        PushEnvelope<TourCompletedCommand> message, CancellationToken ct)
    {
        var t = message.Payload;
        return PushAsync(XInfoSprocs.TourPush, message, new
        {
            t.TourId,
            t.Title,
            t.PlannedStartDate,
            t.PlannedEndDate,
            t.ActualStartAt,
            t.ActualEndAt,
            t.DestinationCity,
            t.VisitCount,
            t.TotalDistanceM,
            t.DistanceByModeJson,
            t.TotalExpenseAmount
        }, ct);
    }

    public async Task<PushResult> PushExpenseAsync(
        PushEnvelope<ExpenseCapturedCommand> message, CancellationToken ct)
    {
        var e = message.Payload;

        var result = await PushAsync(XInfoSprocs.ExpensePush, message, new
        {
            e.ExpenseId,
            e.TourId,
            e.VisitId,
            e.CategoryCode,
            e.ExpenseDate,
            e.Amount,
            e.Currency,
            e.PaymentMode,
            e.MerchantName,
            e.PaymentRef,
            e.Description,
            e.TravelMode,
            e.FromPlace,
            e.ToPlace,
            e.DistanceKm,
            e.DistanceSource,
            e.SuggestedAmount,
            ReceiptCount = e.Receipts.Count
        }, ct);

        if (!result.Accepted || result.WasDuplicate) return result;

        // Receipts follow the expense rather than travelling inside it: a base64 image in the
        // same call would make the parameter large enough to hurt, and a failure would lose
        // the expense along with the picture.
        foreach (var receipt in e.Receipts)
        {
            await sql.ExecuteAsync(XInfoSprocs.ExpenseReceiptPush, new
            {
                e.ExpenseId,
                XinfoExpenseId = result.XinfoId,
                receipt.AttachmentId,
                receipt.FileName,
                receipt.MimeType,
                receipt.SizeBytes,
                receipt.Url,
                receipt.ContentBase64
            }, ct);
        }

        return result;
    }

    public Task<PushResult> PushJourneySummaryAsync(
        PushEnvelope<JourneyDailySummaryCommand> message, CancellationToken ct)
    {
        var j = message.Payload;
        return PushAsync(XInfoSprocs.JourneySummaryPush, message, new
        {
            j.LocalDate,
            j.TourId,
            j.FirstDepartureAt,
            j.LastArrivalAt,
            j.TotalDistanceM,
            j.EstimatedDistanceM,
            j.DistanceByModeJson,
            j.TravelTimeS,
            j.CustomerTimeS,
            j.VisitsPlanned,
            j.VisitsCompleted,
            j.AnomalyCount,
            j.TrackingCoveragePct,
            j.AttendanceStatus
        }, ct);
    }

    public Task<XInfoReconciliationSummary?> GetReconciliationAsync(
        string entity, DateTimeOffset from, DateTimeOffset to, string? employeeCode,
        CancellationToken ct)
        => sql.QueryMultipleAsync(XInfoSprocs.ReconciliationGetSummary, async result =>
        {
            var header = await result.ReadSingleOrDefaultAsync<ReconciliationRow>();
            if (header is null) return null;

            var refs = await result.ReadAsync<string>();

            return new XInfoReconciliationSummary(
                entity, from, to, employeeCode,
                header.RecordCount, header.TotalAmount, refs);
        }, new
        {
            Entity = entity,
            FromDate = from,
            ToDate = to,
            EmployeeCode = employeeCode
        }, ct);

    public async Task<bool> HealthCheckAsync(CancellationToken ct)
    {
        var value = await sql.QuerySingleOrDefaultAsync<int>(XInfoSprocs.HealthCheck, null, ct);
        return value == 1;
    }

    /// <summary>
    /// Every push carries the same envelope. XInfo stores the idempotency key and returns the
    /// original outcome when it sees one twice, which is what makes the outbox safe to retry:
    /// a duplicated delivery must never create a second expense.
    /// </summary>
    private async Task<PushResult> PushAsync<T>(
        string procedure, PushEnvelope<T> message, object payload, CancellationToken ct)
    {
        var parameters = new DynamicParametersBuilder()
            .Add("MessageId", message.MessageId)
            .Add("IdempotencyKey", message.IdempotencyKey)
            .Add("OccurredAt", message.OccurredAt)
            .Add("EmployeeCode", message.EmployeeCode)
            .Merge(payload)
            .Build();

        var row = await sql.QuerySingleOrDefaultAsync<PushResultRow>(procedure, parameters, ct);

        return row is null
            // A push procedure that returns nothing is a contract breach, not a success: we
            // would have no XInfo id to reconcile against later.
            ? throw new XInfoUnavailableException(
                $"{procedure} returned no result row; expected XinfoId and WasDuplicate")
            : new PushResult(row.Accepted, row.XinfoId, row.WasDuplicate, row.Message);
    }

    internal sealed record PushResultRow(
        bool Accepted, string? XinfoId, bool WasDuplicate, string? Message);

    internal sealed record ReconciliationRow(int RecordCount, decimal? TotalAmount);
}
