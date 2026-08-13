using Microsoft.EntityFrameworkCore;
using XMobile.Persistence;
using XMobile.Persistence.Enums;
using XMobile.Shared;
using XMobile.Visits.Domain;

namespace XMobile.Visits.Infrastructure;

/// <summary>
/// docs/04-offline-sync.md §1: an offline device holds its assigned sites' geofences locally and
/// computes `checkInDistanceM`/`isOutOfGeofence` itself before queuing the mutation — unlike
/// `POST /v1/visits/check-in`, this handler trusts those fields from the payload rather than
/// recomputing them server-side (see the plan's scope decision on push not replaying endpoint
/// side-effects).
/// </summary>
public sealed class VisitSyncHandler(XMobileDbContext db, ISiteLookup siteLookup) : ISyncEntityHandler
{
    public string Entity => "visit.visit";
    public bool IsGlobal => false;

    public async Task<object?> GetPayloadAsync(Guid id, CancellationToken ct)
    {
        var v = await db.Set<Visit>().FirstOrDefaultAsync(x => x.Id == id, ct);
        return v is null ? null : new VisitSummary(
            v.Id, v.VisitPlanId, v.TourId, v.CustomerId, null, v.SiteId, null, v.VisitTypeCode, v.LocalDate,
            v.CheckInAt, v.CheckOutAt, v.DurationMin, v.CheckInDistanceM, v.IsOutOfGeofence, v.IsUnplanned,
            v.AutoClosed, v.Status.ToString(), v.RowVersion);
    }

    public async Task<SyncApplyResult> ApplyAsync(SyncMutationContext ctx, CancellationToken ct)
    {
        if (ctx.Op == "DELETE")
        {
            return new SyncApplyResult(SyncApplyOutcome.Rejected, Reason: "Visits are voided, not deleted");
        }

        var visit = await db.Set<Visit>().FirstOrDefaultAsync(x => x.Id == ctx.EntityId, ct);

        if (visit is null)
        {
            var siteId = SyncJson.GetGuid(ctx.Data, "siteId");
            var checkInAt = SyncJson.GetDateTimeOffset(ctx.Data, "checkInAt");
            if (siteId is null || checkInAt is null)
            {
                return new SyncApplyResult(SyncApplyOutcome.Rejected, Reason: "siteId and checkInAt are required");
            }

            var site = await siteLookup.GetByIdAsync(siteId.Value, ct);
            if (site is null)
            {
                return new SyncApplyResult(SyncApplyOutcome.Rejected, Reason: "siteId does not resolve to a known site");
            }

            visit = new Visit
            {
                Id = ctx.EntityId,
                VisitPlanId = SyncJson.GetGuid(ctx.Data, "visitPlanId"),
                TourId = SyncJson.GetGuid(ctx.Data, "tourId"),
                UserId = ctx.UserId,
                CustomerId = site.CustomerId,
                SiteId = siteId.Value,
                ContactId = SyncJson.GetGuid(ctx.Data, "contactId"),
                VisitTypeCode = SyncJson.GetString(ctx.Data, "visitTypeCode") ?? "SALES_CALL",
                LocalDate = DateOnly.FromDateTime(checkInAt.Value.UtcDateTime),
                CheckInAt = checkInAt.Value,
                CheckInGeog = SyncJson.GetGeoPoint(ctx.Data, "point")?.ToNtsPoint(),
                CheckInDistanceM = (int?)SyncJson.GetDecimal(ctx.Data, "checkInDistanceM"),
                IsOutOfGeofence = SyncJson.GetBool(ctx.Data, "isOutOfGeofence") ?? false,
                OutOfFenceReasonCode = SyncJson.GetString(ctx.Data, "outOfFenceReasonCode"),
                IsUnplanned = SyncJson.GetGuid(ctx.Data, "visitPlanId") is null,
            };
            db.Add(visit);
        }
        else
        {
            if (ctx.BaseVersion is { } baseVersion)
            {
                db.Entry(visit).Property(v => v.RowVersion).OriginalValue = baseVersion;
            }

            if (SyncJson.GetDateTimeOffset(ctx.Data, "checkOutAt") is { } checkOutAt)
            {
                visit.CheckOutAt = checkOutAt;
                visit.CheckOutGeog = SyncJson.GetGeoPoint(ctx.Data, "checkOutPoint")?.ToNtsPoint() ?? visit.CheckOutGeog;
                visit.Status = VisitStatus.CHECKED_OUT;
            }
        }

        try
        {
            await db.SaveChangesAsync(ct);
            return new SyncApplyResult(SyncApplyOutcome.Applied, visit.RowVersion);
        }
        catch (DbUpdateConcurrencyException ex)
        {
            // See the identical comment in PlanningSyncHandlers.cs — a caught concurrency
            // exception must not leave the entity Modified for the ledger-recording SaveChanges
            // that follows in XMobile.Sync's push loop to trip over again.
            foreach (var entry in ex.Entries)
            {
                entry.State = EntityState.Detached;
            }

            return new SyncApplyResult(SyncApplyOutcome.Conflict, Reason: "STALE_VERSION");
        }
    }
}

/// <summary>Client wins while draft; immutable once submitted (docs/04 §4) — matches
/// VisitEndpoints.SaveReportAsync's rule exactly, since that's the same invariant either path
/// must enforce. `ctx.EntityId` is the visit id: `visit_report`'s sync key is `visit_id`, not a
/// generic `id` (db/schema/05_visit_report.sql's `fn_make_syncable(..., 'visit_id')`).</summary>
public sealed class VisitReportSyncHandler(XMobileDbContext db) : ISyncEntityHandler
{
    public string Entity => "visit.visit_report";
    public bool IsGlobal => false;

    public async Task<object?> GetPayloadAsync(Guid visitId, CancellationToken ct)
    {
        var r = await db.Set<VisitReport>().FirstOrDefaultAsync(x => x.VisitId == visitId, ct);
        return r is null ? null : new
        {
            visitId = r.VisitId, outcomeCode = r.OutcomeCode, summary = r.Summary,
            discussionPoints = r.DiscussionPoints, nextAction = r.NextAction, followUpDate = r.FollowUpDate,
            orderIntent = r.OrderIntent, orderValueEst = r.OrderValueEst, competitorSeen = r.CompetitorSeen,
            customerSentiment = r.CustomerSentiment, isDraft = r.IsDraft, submittedAt = r.SubmittedAt,
            rowVersion = r.RowVersion,
        };
    }

    public async Task<SyncApplyResult> ApplyAsync(SyncMutationContext ctx, CancellationToken ct)
    {
        if (ctx.Op == "DELETE")
        {
            return new SyncApplyResult(SyncApplyOutcome.Rejected, Reason: "Reports are amended, not deleted");
        }

        var report = await db.Set<VisitReport>().FirstOrDefaultAsync(x => x.VisitId == ctx.EntityId, ct);
        var isNew = report is null;
        if (isNew)
        {
            report = new VisitReport { VisitId = ctx.EntityId, UserId = ctx.UserId };
            db.Add(report);
        }
        else if (!report!.IsDraft)
        {
            return new SyncApplyResult(
                SyncApplyOutcome.Rejected, Reason: "Report is already submitted; use /report/amend instead");
        }
        else if (ctx.BaseVersion is { } baseVersion)
        {
            db.Entry(report).Property(r => r.RowVersion).OriginalValue = baseVersion;
        }

        report!.OutcomeCode = SyncJson.GetString(ctx.Data, "outcomeCode") ?? report.OutcomeCode;
        report.Summary = SyncJson.GetString(ctx.Data, "summary") ?? report.Summary;
        report.DiscussionPoints = SyncJson.GetString(ctx.Data, "discussionPoints") ?? report.DiscussionPoints;
        report.NextAction = SyncJson.GetString(ctx.Data, "nextAction") ?? report.NextAction;
        if (SyncJson.GetDateOnly(ctx.Data, "followUpDate") is { } followUp)
        {
            report.FollowUpDate = followUp;
        }

        if (SyncJson.GetBool(ctx.Data, "submit") is true)
        {
            report.IsDraft = false;
            report.SubmittedAt = ctx.OccurredAt ?? DateTimeOffset.UtcNow;
        }

        try
        {
            await db.SaveChangesAsync(ct);
            return new SyncApplyResult(SyncApplyOutcome.Applied, report.RowVersion);
        }
        catch (DbUpdateConcurrencyException ex)
        {
            // See the identical comment in PlanningSyncHandlers.cs — a caught concurrency
            // exception must not leave the entity Modified for the ledger-recording SaveChanges
            // that follows in XMobile.Sync's push loop to trip over again.
            foreach (var entry in ex.Entries)
            {
                entry.State = EntityState.Detached;
            }

            return new SyncApplyResult(SyncApplyOutcome.Conflict, Reason: "STALE_VERSION");
        }
    }
}

/// <summary>Reference data — "Server wins" (docs/04 §4); every push against it is rejected.
/// Publishing is an admin action this increment doesn't build an endpoint for either.</summary>
public sealed class FormTemplateSyncHandler(XMobileDbContext db) : ISyncEntityHandler
{
    public string Entity => "visit.form_template";
    public bool IsGlobal => true;

    public async Task<object?> GetPayloadAsync(Guid id, CancellationToken ct)
    {
        var t = await db.Set<FormTemplate>().FirstOrDefaultAsync(x => x.Id == id, ct);
        return t is null ? null : new
        {
            id = t.Id, code = t.Code, version = t.Version, name = t.Name,
            visitTypeCode = t.VisitTypeCode, status = t.Status.ToString(), rowVersion = t.RowVersion,
        };
    }

    public Task<SyncApplyResult> ApplyAsync(SyncMutationContext ctx, CancellationToken ct)
        => Task.FromResult(new SyncApplyResult(
            SyncApplyOutcome.Rejected, Reason: "form_template is server-owned; publish it through admin tooling"));
}
