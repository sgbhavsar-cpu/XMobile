using Microsoft.EntityFrameworkCore;
using XMobile.Identity.Domain;
using XMobile.Persistence;
using XMobile.Persistence.Enums;
using XMobile.Planning.Domain;
using XMobile.Shared;

namespace XMobile.Planning.Infrastructure;

/// <summary>
/// Each handler catches only <see cref="DbUpdateConcurrencyException"/> locally (the one failure
/// mode specific to *this* entity's optimistic-concurrency check) — a foreign-key violation or
/// anything else propagates to XMobile.Sync's push loop, which maps it to DEFERRED/Rejected
/// uniformly for every entity rather than every handler re-implementing that mapping.
/// </summary>
public sealed class TourSyncHandler(XMobileDbContext db, IClock clock) : ISyncEntityHandler
{
    public string Entity => "planning.tour";
    public bool IsGlobal => false;

    public async Task<object?> GetPayloadAsync(Guid id, CancellationToken ct)
    {
        var t = await db.Set<Tour>().FirstOrDefaultAsync(x => x.Id == id, ct);
        return t is null ? null : new
        {
            id = t.Id, userId = t.UserId, title = t.Title, purpose = t.Purpose,
            plannedStartDate = t.PlannedStartDate, plannedEndDate = t.PlannedEndDate,
            actualStartAt = t.ActualStartAt, actualEndAt = t.ActualEndAt, status = t.Status.ToString(),
            destinationCity = t.DestinationCity, totalDistanceM = t.TotalDistanceM,
            totalVisits = t.TotalVisits, totalExpenseAmount = t.TotalExpenseAmount, rowVersion = t.RowVersion,
        };
    }

    public async Task<SyncApplyResult> ApplyAsync(SyncMutationContext ctx, CancellationToken ct)
    {
        if (ctx.Op == "DELETE")
        {
            return new SyncApplyResult(SyncApplyOutcome.Rejected, Reason: "Tours are cancelled, not deleted");
        }

        var tour = await db.Set<Tour>().FirstOrDefaultAsync(x => x.Id == ctx.EntityId, ct);
        if (tour is null)
        {
            var home = await db.Set<UserHomeLocation>()
                .FirstOrDefaultAsync(h => h.UserId == ctx.UserId && h.EffectiveTo == null, ct);
            if (home is null)
            {
                return new SyncApplyResult(SyncApplyOutcome.Rejected, Reason: "No home location set for this user");
            }

            tour = new Tour
            {
                Id = ctx.EntityId,
                UserId = ctx.UserId,
                HomeLocationId = home.Id,
                Title = SyncJson.GetString(ctx.Data, "title") ?? "Untitled tour",
                PlannedStartDate = SyncJson.GetDateOnly(ctx.Data, "plannedStartDate")
                    ?? DateOnly.FromDateTime(clock.UtcNow.UtcDateTime),
                PlannedEndDate = SyncJson.GetDateOnly(ctx.Data, "plannedEndDate")
                    ?? DateOnly.FromDateTime(clock.UtcNow.UtcDateTime),
                Status = TourStatus.PLANNED,
                CreatedBy = ctx.UserId,
            };
            db.Add(tour);
        }
        else if (ctx.BaseVersion is { } baseVersion)
        {
            db.Entry(tour).Property(t => t.RowVersion).OriginalValue = baseVersion;
        }

        if (SyncJson.GetString(ctx.Data, "title") is { } title)
        {
            tour.Title = title;
        }

        tour.Purpose = SyncJson.GetString(ctx.Data, "purpose") ?? tour.Purpose;
        tour.DestinationCity = SyncJson.GetString(ctx.Data, "destinationCity") ?? tour.DestinationCity;
        if (SyncJson.GetDateOnly(ctx.Data, "plannedStartDate") is { } start)
        {
            tour.PlannedStartDate = start;
        }

        if (SyncJson.GetDateOnly(ctx.Data, "plannedEndDate") is { } end)
        {
            tour.PlannedEndDate = end;
        }

        try
        {
            await db.SaveChangesAsync(ct);
            return new SyncApplyResult(SyncApplyOutcome.Applied, tour.RowVersion);
        }
        catch (DbUpdateConcurrencyException ex)
        {
            // Left in the ChangeTracker as Modified otherwise — XMobile.Sync's push loop does a
            // second SaveChanges right after this (recording the conflict/ledger rows), which
            // would try to re-save this same stale write and fail again, uncaught this time.
            foreach (var entry in ex.Entries)
            {
                entry.State = EntityState.Detached;
            }

            return new SyncApplyResult(SyncApplyOutcome.Conflict, Reason: "STALE_VERSION");
        }
    }
}

/// <summary>Tour days are generated server-side when a tour is created (docs/02 §2.1) — this
/// handler supports only updating the mutable fields of a day that already exists, matching
/// docs/04 §4's "tour, tour_day" conflict policy without also supporting client-side day
/// creation, which nothing in this system does yet.</summary>
public sealed class TourDaySyncHandler(XMobileDbContext db) : ISyncEntityHandler
{
    public string Entity => "planning.tour_day";
    public bool IsGlobal => false;

    public async Task<object?> GetPayloadAsync(Guid id, CancellationToken ct)
    {
        var d = await db.Set<TourDay>().FirstOrDefaultAsync(x => x.Id == id, ct);
        return d is null ? null : new
        {
            id = d.Id, tourId = d.TourId, planDate = d.PlanDate, daySeq = d.DaySeq,
            activityType = d.ActivityType.ToString(), fromCity = d.FromCity, toCity = d.ToCity,
            overnightCity = d.OvernightCity, notes = d.Notes, rowVersion = d.RowVersion,
        };
    }

    public async Task<SyncApplyResult> ApplyAsync(SyncMutationContext ctx, CancellationToken ct)
    {
        var day = await db.Set<TourDay>().FirstOrDefaultAsync(x => x.Id == ctx.EntityId, ct);
        if (day is null)
        {
            return new SyncApplyResult(SyncApplyOutcome.Rejected,
                Reason: "Tour days are created with their tour; there is none to update here");
        }

        if (ctx.BaseVersion is { } baseVersion)
        {
            db.Entry(day).Property(d => d.RowVersion).OriginalValue = baseVersion;
        }

        day.FromCity = SyncJson.GetString(ctx.Data, "fromCity") ?? day.FromCity;
        day.ToCity = SyncJson.GetString(ctx.Data, "toCity") ?? day.ToCity;
        day.OvernightCity = SyncJson.GetString(ctx.Data, "overnightCity") ?? day.OvernightCity;
        day.Notes = SyncJson.GetString(ctx.Data, "notes") ?? day.Notes;

        try
        {
            await db.SaveChangesAsync(ct);
            return new SyncApplyResult(SyncApplyOutcome.Applied, day.RowVersion);
        }
        catch (DbUpdateConcurrencyException ex)
        {
            // Left in the ChangeTracker as Modified otherwise — XMobile.Sync's push loop does a
            // second SaveChanges right after this (recording the conflict/ledger rows), which
            // would try to re-save this same stale write and fail again, uncaught this time.
            foreach (var entry in ex.Entries)
            {
                entry.State = EntityState.Detached;
            }

            return new SyncApplyResult(SyncApplyOutcome.Conflict, Reason: "STALE_VERSION");
        }
    }
}

/// <summary>The representative "created entirely offline" case: a rep adds a visit plan to a
/// tour day with no network, and it must be creatable purely from the pushed payload.</summary>
public sealed class VisitPlanSyncHandler(XMobileDbContext db, ISiteLookup siteLookup) : ISyncEntityHandler
{
    public string Entity => "planning.visit_plan";
    public bool IsGlobal => false;

    public async Task<object?> GetPayloadAsync(Guid id, CancellationToken ct)
    {
        var p = await db.Set<VisitPlan>().FirstOrDefaultAsync(x => x.Id == id, ct);
        return p is null ? null : new
        {
            id = p.Id, tourId = p.TourId, tourDayId = p.TourDayId, customerId = p.CustomerId,
            siteId = p.SiteId, visitTypeCode = p.VisitTypeCode, plannedDate = p.PlannedDate,
            seq = p.Seq, objective = p.Objective, status = p.Status.ToString(),
            isBaseline = p.IsBaseline, rowVersion = p.RowVersion,
        };
    }

    public async Task<SyncApplyResult> ApplyAsync(SyncMutationContext ctx, CancellationToken ct)
    {
        var plan = await db.Set<VisitPlan>().FirstOrDefaultAsync(x => x.Id == ctx.EntityId, ct);

        if (plan is null)
        {
            if (ctx.Op == "DELETE")
            {
                return new SyncApplyResult(SyncApplyOutcome.Applied);
            }

            var siteId = SyncJson.GetGuid(ctx.Data, "siteId");
            var visitTypeCode = SyncJson.GetString(ctx.Data, "visitTypeCode");
            var plannedDate = SyncJson.GetDateOnly(ctx.Data, "plannedDate");
            if (siteId is null || visitTypeCode is null || plannedDate is null)
            {
                return new SyncApplyResult(
                    SyncApplyOutcome.Rejected, Reason: "siteId, visitTypeCode and plannedDate are required");
            }

            var customerId = SyncJson.GetGuid(ctx.Data, "customerId")
                ?? (await siteLookup.GetByIdAsync(siteId.Value, ct))?.CustomerId;
            if (customerId is null)
            {
                return new SyncApplyResult(SyncApplyOutcome.Rejected, Reason: "siteId does not resolve to a known customer");
            }

            plan = new VisitPlan
            {
                Id = ctx.EntityId,
                TourId = SyncJson.GetGuid(ctx.Data, "tourId"),
                TourDayId = SyncJson.GetGuid(ctx.Data, "tourDayId"),
                UserId = ctx.UserId,
                CustomerId = customerId.Value,
                SiteId = siteId.Value,
                ContactId = SyncJson.GetGuid(ctx.Data, "contactId"),
                VisitTypeCode = visitTypeCode,
                PlannedDate = plannedDate.Value,
                PlannedStartTime = SyncJson.GetTimeOnly(ctx.Data, "plannedStartTime"),
                Seq = SyncJson.GetInt16(ctx.Data, "seq") ?? 1,
                Objective = SyncJson.GetString(ctx.Data, "objective"),
                CreatedBy = ctx.UserId,
            };
            db.Add(plan);
        }
        else if (ctx.Op == "DELETE")
        {
            plan.DeletedAt = ctx.OccurredAt ?? DateTimeOffset.UtcNow;
        }
        else
        {
            if (ctx.BaseVersion is { } baseVersion)
            {
                db.Entry(plan).Property(p => p.RowVersion).OriginalValue = baseVersion;
            }

            plan.Objective = SyncJson.GetString(ctx.Data, "objective") ?? plan.Objective;
            if (SyncJson.GetInt16(ctx.Data, "seq") is { } seq)
            {
                plan.Seq = seq;
            }

            if (SyncJson.GetDateOnly(ctx.Data, "plannedDate") is { } date)
            {
                plan.PlannedDate = date;
            }
        }

        try
        {
            await db.SaveChangesAsync(ct);
            return new SyncApplyResult(SyncApplyOutcome.Applied, plan.RowVersion);
        }
        catch (DbUpdateConcurrencyException ex)
        {
            // Left in the ChangeTracker as Modified otherwise — XMobile.Sync's push loop does a
            // second SaveChanges right after this (recording the conflict/ledger rows), which
            // would try to re-save this same stale write and fail again, uncaught this time.
            foreach (var entry in ex.Entries)
            {
                entry.State = EntityState.Detached;
            }

            return new SyncApplyResult(SyncApplyOutcome.Conflict, Reason: "STALE_VERSION");
        }
    }
}
