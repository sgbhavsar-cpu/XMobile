using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;
using XMobile.Identity.Domain;
using XMobile.Persistence;
using XMobile.Persistence.Enums;
using XMobile.Shared;
using XMobile.Tracking.Domain;
using XMobile.Tracking.Infrastructure;

namespace XMobile.Tracking.Endpoints;

public static class TrackingEndpoints
{
    // Matches InferenceRunner.DefaultLocalOffset — no per-user timezone resolution this pass.
    private static readonly TimeSpan LocalOffset = TimeSpan.FromHours(5.5);

    // Npgsql only accepts UTC-offset DateTimeOffset values for timestamptz columns/parameters
    // ("Cannot write DateTimeOffset with Offset=X..."). Every client-supplied timestamp on this
    // module's DTOs is a plain DateTimeOffset (a device may report its own local offset), so each
    // one is normalized at the point it's written or used in a query — ToUniversalTime() keeps the
    // same instant, just re-expressed with Offset=0.

    public static IEndpointRouteBuilder MapTrackingEndpoints(this IEndpointRouteBuilder app)
    {
        var tracking = app.MapGroup("/v1/tracking").WithTags("Tracking").RequireAuthorization();

        tracking.MapPost("/batch", BatchAsync);

        tracking.MapPost("/session", StartSessionAsync);
        tracking.MapPost("/session/{id:guid}/end", EndSessionAsync);
        tracking.MapPost("/session/{id:guid}/pause", PauseSessionAsync);
        tracking.MapPost("/session/{id:guid}/resume", ResumeSessionAsync);

        tracking.MapGet("/journey", GetJourneyAsync);
        tracking.MapPost("/events/{id:guid}/override", OverrideEventAsync);
        tracking.MapPost("/events/{id:guid}/confirm", ConfirmEventAsync);
        tracking.MapPost("/heading-home", HeadingHomeAsync);

        tracking.MapGet("/geofences", GetGeofencesAsync);

        return app;
    }

    // ---------------------------------------------------------------- batch

    private static async Task<IResult> BatchAsync(
        TrackingBatchRequest request, XMobileDbContext db, ICurrentUser currentUser, IClock clock,
        InferenceRunner inferenceRunner, CancellationToken ct)
    {
        var pings = request.Pings ?? [];
        var geofenceEvents = request.GeofenceEvents ?? [];
        var stays = request.Stays ?? [];

        if (pings.Count > 1000)
        {
            throw new DomainValidationException("A batch may contain at most 1000 pings");
        }

        var acceptedPings = 0;
        var duplicatePings = 0;
        if (pings.Count > 0)
        {
            foreach (var month in pings
                         .Select(p => p.RecordedAt.ToUniversalTime())
                         .Select(t => new DateOnly(t.Year, t.Month, 1))
                         .Distinct())
            {
                // DateOnly maps directly to Postgres "date" — a DateTime parameter here would
                // default to Npgsql's timestamptz binding and demand a UTC Kind unnecessarily.
                await db.Database.ExecuteSqlInterpolatedAsync(
                    $"SELECT tracking.fn_ensure_ping_partition({month})", ct);
            }

            var ids = pings.Select(p => p.Id).ToList();
            var existingIds = (await db.Set<LocationPing>()
                    .Where(p => p.UserId == currentUser.UserId && ids.Contains(p.Id))
                    .Select(p => p.Id)
                    .ToListAsync(ct))
                .ToHashSet();

            foreach (var p in pings)
            {
                if (!existingIds.Add(p.Id))
                {
                    duplicatePings++;
                    continue;
                }

                db.Add(new LocationPing
                {
                    Id = p.Id,
                    UserId = currentUser.UserId,
                    DeviceId = request.DeviceId,
                    SessionId = request.SessionId,
                    RecordedAt = p.RecordedAt.ToUniversalTime(),
                    ReceivedAt = clock.UtcNow,
                    Geog = p.Point.ToNtsPoint(),
                    AccuracyM = (float?)p.AccuracyM,
                    AltitudeM = (float?)p.AltitudeM,
                    SpeedMps = (float?)p.SpeedMps,
                    SpeedAccuracy = (float?)p.SpeedAccuracy,
                    HeadingDeg = (float?)p.HeadingDeg,
                    ActivityType = p.ActivityType,
                    ActivityConf = (short?)p.ActivityConfidence,
                    IsMoving = p.IsMoving,
                    BatteryPct = (short?)p.BatteryPct,
                    IsCharging = p.IsCharging,
                    Provider = p.Provider,
                    IsMock = p.IsMock,
                    Source = Enum.Parse<PingSource>(p.Source),
                    Seq = p.Seq,
                    DeviceTz = p.DeviceTz,
                    TzOffsetMin = (short?)p.TzOffsetMin,
                });
                acceptedPings++;
            }
        }

        var acceptedGeofenceEvents = 0;
        if (geofenceEvents.Count > 0)
        {
            var ids = geofenceEvents.Select(e => e.Id).ToList();
            var existingIds = (await db.Set<GeofenceEvent>()
                    .Where(e => ids.Contains(e.Id)).Select(e => e.Id).ToListAsync(ct))
                .ToHashSet();

            foreach (var e in geofenceEvents.Where(e => !existingIds.Contains(e.Id)))
            {
                db.Add(new GeofenceEvent
                {
                    Id = e.Id,
                    UserId = currentUser.UserId,
                    DeviceId = request.DeviceId,
                    SessionId = request.SessionId,
                    GeofenceId = e.GeofenceId,
                    EventType = e.EventType,
                    OccurredAt = e.OccurredAt.ToUniversalTime(),
                    ReceivedAt = clock.UtcNow,
                    Geog = e.Point?.ToNtsPoint(),
                    AccuracyM = (float?)e.AccuracyM,
                    DwellSec = e.DwellSec,
                    OsConfidence = (short?)e.OsConfidence,
                    IsMock = e.IsMock,
                });
                acceptedGeofenceEvents++;
            }
        }

        var acceptedStays = 0;
        if (stays.Count > 0)
        {
            var ids = stays.Select(s => s.Id).ToList();
            var existingIds = (await db.Set<StayDetection>()
                    .Where(s => ids.Contains(s.Id)).Select(s => s.Id).ToListAsync(ct))
                .ToHashSet();

            foreach (var s in stays.Where(s => !existingIds.Contains(s.Id)))
            {
                db.Add(new StayDetection
                {
                    Id = s.Id,
                    UserId = currentUser.UserId,
                    DeviceId = request.DeviceId,
                    ArrivedAt = s.ArrivedAt.ToUniversalTime(),
                    DepartedAt = s.DepartedAt?.ToUniversalTime(),
                    Geog = s.Point.ToNtsPoint(),
                    HorizontalAccuracyM = (float?)s.AccuracyM,
                    Source = s.Source,
                });
                acceptedStays++;
            }
        }

        if (request.Heartbeat is { } hb)
        {
            db.Add(new DeviceHeartbeat
            {
                Id = Guid.NewGuid(),
                DeviceId = request.DeviceId,
                UserId = currentUser.UserId,
                ReportedAt = hb.ReportedAt.ToUniversalTime(),
                ReceivedAt = clock.UtcNow,
                BatteryPct = (short?)hb.BatteryPct,
                IsPowerSaving = hb.IsPowerSaving,
                LocationEnabled = hb.LocationEnabled,
                PermissionLevel = hb.PermissionLevel,
                ServiceRunning = hb.ServiceRunning,
                QueuedPings = hb.QueuedPings,
                QueuedMutations = hb.QueuedMutations,
                NetworkType = hb.NetworkType,
                AppVersion = hb.AppVersion,
                ClockSkewSec = hb.ClockSkewSec,
            });
        }

        await db.SaveChangesAsync(ct);

        // Inline, synchronous inference (no Redis/queue this pass — see the plan's scope decision).
        // Window = start of today's local day through now, so a batch anywhere in the day rebuilds
        // the whole day's timeline against the freshest evidence.
        if (acceptedPings + acceptedGeofenceEvents + acceptedStays > 0)
        {
            var windowFrom = StartOfLocalDay(clock.UtcNow);
            await inferenceRunner.RunAsync(currentUser.UserId, windowFrom, clock.UtcNow, "NEW_EVIDENCE", ct);
        }

        return Results.Ok(new TrackingBatchResultDto(
            acceptedPings, duplicatePings, acceptedGeofenceEvents, acceptedStays,
            NextUploadAfterSec: 60, clock.UtcNow));
    }

    // ---------------------------------------------------------------- sessions

    private static async Task<IResult> StartSessionAsync(
        TrackingSessionStartRequest request, XMobileDbContext db, ICurrentUser currentUser, CancellationToken ct)
    {
        var session = new TrackingSession
        {
            Id = request.SessionId,
            UserId = currentUser.UserId,
            DeviceId = request.DeviceId,
            TourId = request.TourId,
            StartedAt = request.StartedAt.ToUniversalTime(),
            StartReason = request.StartReason,
            AppVersion = request.AppVersion,
            OsVersion = request.OsVersion,
        };
        db.Add(session);
        await db.SaveChangesAsync(ct);
        return Results.Created($"/v1/tracking/session/{session.Id}", ToSessionDto(session));
    }

    private static async Task<IResult> EndSessionAsync(
        Guid id, SessionEndRequest request, XMobileDbContext db, ICurrentUser currentUser, CancellationToken ct)
    {
        var session = await LoadOwnSessionAsync(db, currentUser, id, ct);
        session.EndedAt = request.EndedAt.ToUniversalTime();
        session.EndReason = request.EndReason;
        session.Status = SessionStatus.ENDED;
        await SaveOrConflictAsync(db, ct);
        return Results.Ok(ToSessionDto(session));
    }

    private static async Task<IResult> PauseSessionAsync(
        Guid id, SessionPauseRequest request, XMobileDbContext db, ICurrentUser currentUser, CancellationToken ct)
    {
        var session = await LoadOwnSessionAsync(db, currentUser, id, ct);
        session.Status = SessionStatus.PAUSED;
        db.Add(new TrackingPause
        {
            Id = request.PauseId,
            SessionId = session.Id,
            UserId = currentUser.UserId,
            PausedAt = request.PausedAt.ToUniversalTime(),
            ReasonCode = request.ReasonCode,
            ReasonText = request.ReasonText,
        });
        await SaveOrConflictAsync(db, ct);
        return Results.Ok(ToSessionDto(session));
    }

    private static async Task<IResult> ResumeSessionAsync(
        Guid id, SessionResumeRequest request, XMobileDbContext db, ICurrentUser currentUser, CancellationToken ct)
    {
        var session = await LoadOwnSessionAsync(db, currentUser, id, ct);
        var pause = await db.Set<TrackingPause>()
            .Where(p => p.SessionId == id && p.ResumedAt == null)
            .OrderByDescending(p => p.PausedAt)
            .FirstOrDefaultAsync(ct);
        if (pause is not null)
        {
            pause.ResumedAt = request.ResumedAt.ToUniversalTime();
            pause.ResumedBy = "USER";
        }

        session.Status = SessionStatus.ACTIVE;
        await SaveOrConflictAsync(db, ct);
        return Results.Ok(ToSessionDto(session));
    }

    // ---------------------------------------------------------------- journey

    private static async Task<IResult> GetJourneyAsync(
        DateTimeOffset? from, DateTimeOffset? to, bool? includePath,
        XMobileDbContext db, ICurrentUser currentUser, IClock clock, CancellationToken ct)
    {
        var effectiveTo = (to ?? clock.UtcNow).ToUniversalTime();
        var effectiveFrom = (from ?? effectiveTo.AddDays(-7)).ToUniversalTime();

        var events = await db.Set<JourneyEvent>()
            .Where(e => e.UserId == currentUser.UserId && e.OccurredAt >= effectiveFrom && e.OccurredAt <= effectiveTo
                && e.Status != EventStatus.SUPERSEDED)
            .OrderBy(e => e.OccurredAt)
            .ToListAsync(ct);
        var segments = await db.Set<JourneySegment>()
            .Where(s => s.UserId == currentUser.UserId && s.StartedAt >= effectiveFrom && s.StartedAt <= effectiveTo)
            .OrderBy(s => s.StartedAt)
            .ToListAsync(ct);
        var anomalies = await db.Set<TrackingAnomaly>()
            .Where(a => a.UserId == currentUser.UserId && a.WindowStart >= effectiveFrom && a.WindowStart <= effectiveTo)
            .OrderBy(a => a.WindowStart)
            .ToListAsync(ct);

        return Results.Ok(new JourneyTimelineDto(
            currentUser.UserId, effectiveFrom, effectiveTo,
            events.Select(ToEventDto).ToList(),
            segments.Select(s => ToSegmentDto(s, includePath == true)).ToList(),
            anomalies.Select(ToAnomalyDto).ToList(),
            BuildDailySummaries(segments)));
    }

    private static async Task<IResult> OverrideEventAsync(
        Guid id, OverrideEventRequest request, XMobileDbContext db, ICurrentUser currentUser, IClock clock,
        InferenceRunner inferenceRunner, CancellationToken ct)
    {
        var evt = await db.Set<JourneyEvent>().FirstOrDefaultAsync(e => e.Id == id && e.UserId == currentUser.UserId, ct)
                  ?? throw new NotFoundException("Journey event not found");

        evt.OriginalOccurredAt ??= evt.OccurredAt;
        evt.OccurredAt = request.OccurredAt.ToUniversalTime();
        evt.OverriddenBy = currentUser.UserId;
        evt.OverriddenAt = clock.UtcNow;
        evt.OverrideReason = request.Reason;
        evt.Status = EventStatus.CONFIRMED;
        await SaveOrConflictAsync(db, ct);

        await ReinferAsync(inferenceRunner, currentUser.UserId, evt.LocalDate, ct);
        return Results.Ok(ToEventDto(evt));
    }

    private static async Task<IResult> ConfirmEventAsync(
        Guid id, XMobileDbContext db, ICurrentUser currentUser, InferenceRunner inferenceRunner, CancellationToken ct)
    {
        var evt = await db.Set<JourneyEvent>().FirstOrDefaultAsync(e => e.Id == id && e.UserId == currentUser.UserId, ct)
                  ?? throw new NotFoundException("Journey event not found");
        evt.Status = EventStatus.CONFIRMED;
        await SaveOrConflictAsync(db, ct);

        await ReinferAsync(inferenceRunner, currentUser.UserId, evt.LocalDate, ct);
        return Results.Ok(ToEventDto(evt));
    }

    private static async Task<IResult> HeadingHomeAsync(
        HeadingHomeRequest request, XMobileDbContext db, ICurrentUser currentUser, IClock clock,
        InferenceRunner inferenceRunner, CancellationToken ct)
    {
        var occurredAt = (request.OccurredAt ?? clock.UtcNow).ToUniversalTime();
        var localDate = DateOnly.FromDateTime((occurredAt + LocalOffset).DateTime);

        // Inserted straight to CONFIRMED so InferenceRunner's anchor query (status = CONFIRMED or
        // overridden) picks it up untouched — a rep saying "I'm heading home" is as authoritative
        // as a manual correction.
        db.Add(new JourneyEvent
        {
            UserId = currentUser.UserId,
            TourId = request.TourId,
            EventType = JourneyEventType.START_RETURN,
            OccurredAt = occurredAt,
            DetectedAt = clock.UtcNow,
            LocalDate = localDate,
            DetectionMethod = DetectionMethod.MANUAL,
            Confidence = 1.0m,
            Status = EventStatus.CONFIRMED,
        });
        await db.SaveChangesAsync(ct);

        await ReinferAsync(inferenceRunner, currentUser.UserId, localDate, ct);
        return Results.Ok();
    }

    // ---------------------------------------------------------------- geofences

    private static async Task<IResult> GetGeofencesAsync(
        double? lat, double? lon, int? max, XMobileDbContext db, ICurrentUser currentUser, IClock clock,
        IGeofenceLookup geofenceLookup, ITourContextLookup tourLookup, CancellationToken ct)
    {
        // Proximity ranking (lat/lon/distance sort) deferred, same as CustomerEndpoints'
        // nearLat/nearLon — home-first-then-tour-sites is the load-bearing order for Phase 1.
        _ = lat;
        _ = lon;

        var localDate = DateOnly.FromDateTime((clock.UtcNow + LocalOffset).DateTime);
        var home = await db.Set<UserHomeLocation>()
            .FirstOrDefaultAsync(h => h.UserId == currentUser.UserId && h.EffectiveTo == null, ct);

        var refs = new List<(string RefType, Guid RefId)>();
        if (home is not null)
        {
            refs.Add(("HOME", home.Id));
        }

        var tourContext = await tourLookup.GetForUserAsync(currentUser.UserId, localDate, ct);
        if (tourContext is not null)
        {
            refs.AddRange(tourContext.AllPlannedSiteIds.Select(id => ("CUSTOMER_SITE", id)));
        }

        var geofences = refs.Count == 0 ? [] : await geofenceLookup.GetByRefsAsync(refs, ct);
        var ordered = geofences.OrderByDescending(g => g.RefType == "HOME");
        var limited = max is { } m ? ordered.Take(m) : ordered;

        return Results.Ok(limited.Select(g => new GeofenceDto(g.Id, g.RefType, g.RefId, g.Name, g.Point, g.RadiusM)));
    }

    // ---------------------------------------------------------------- helpers

    private static DateTimeOffset StartOfLocalDay(DateTimeOffset instant)
    {
        var localDate = DateOnly.FromDateTime((instant + LocalOffset).DateTime);
        // Npgsql only accepts UTC-offset DateTimeOffset values for timestamptz columns (this
        // window ends up written to tracking.inference_run) — ToUniversalTime() keeps the same
        // instant, just re-expressed with Offset=0, after building it in local wall-clock terms.
        return new DateTimeOffset(localDate.ToDateTime(TimeOnly.MinValue), LocalOffset).ToUniversalTime();
    }

    private static async Task ReinferAsync(InferenceRunner runner, Guid userId, DateOnly localDate, CancellationToken ct)
    {
        var windowFrom = new DateTimeOffset(localDate.ToDateTime(TimeOnly.MinValue), LocalOffset).ToUniversalTime();
        await runner.RunAsync(userId, windowFrom, windowFrom.AddDays(1), "OVERRIDE", ct);
    }

    private static async Task<TrackingSession> LoadOwnSessionAsync(
        XMobileDbContext db, ICurrentUser currentUser, Guid id, CancellationToken ct)
        => await db.Set<TrackingSession>().FirstOrDefaultAsync(s => s.Id == id && s.UserId == currentUser.UserId, ct)
           ?? throw new NotFoundException("Tracking session not found");

    private static async Task SaveOrConflictAsync(XMobileDbContext db, CancellationToken ct)
    {
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateConcurrencyException)
        {
            throw new StateConflictException("This was modified elsewhere; refresh and retry.");
        }
    }

    private static List<DailySummaryDto> BuildDailySummaries(List<JourneySegment> segments) => segments
        .GroupBy(s => s.LocalDate)
        .Select(g =>
        {
            var firstDeparture = g.Where(s => s.SegmentType == SegmentType.OUTBOUND_TRAVEL)
                .OrderBy(s => s.StartedAt).Select(s => (DateTimeOffset?)s.StartedAt).FirstOrDefault();
            var lastArrival = g.Where(s => s.SegmentType == SegmentType.AT_HOME)
                .OrderByDescending(s => s.StartedAt).Select(s => (DateTimeOffset?)s.StartedAt).FirstOrDefault();
            var travelTypes = new[] { SegmentType.OUTBOUND_TRAVEL, SegmentType.INTER_TRAVEL, SegmentType.RETURN_TRAVEL };

            return new DailySummaryDto(
                g.Key,
                firstDeparture,
                lastArrival,
                g.Sum(s => s.DistanceM ?? 0),
                g.Where(s => travelTypes.Contains(s.SegmentType)).Sum(s => s.DurationS ?? 0),
                g.Where(s => s.SegmentType == SegmentType.AT_CUSTOMER).Sum(s => s.DurationS ?? 0),
                g.Where(s => s.SegmentType == SegmentType.GAP).Sum(s => s.DurationS ?? 0));
        })
        .OrderBy(d => d.LocalDate)
        .ToList();

    private static JourneyEventDto ToEventDto(JourneyEvent e) => new(
        e.Id, e.EventType.ToString(), e.OccurredAt, e.LocalDate,
        e.Geog?.ToGeoPoint(), e.RefType, e.RefId, e.SiteId, e.DetectionMethod.ToString(), e.Confidence,
        e.Status.ToString(), e.IsEstimated, e.OriginalOccurredAt, e.RowVersion);

    private static JourneySegmentDto ToSegmentDto(JourneySegment s, bool includePath) => new(
        s.Id, s.SegmentType.ToString(), s.StartedAt, s.EndedAt, s.DurationS, s.LocalDate, s.RefType, s.RefId,
        s.SiteId, s.DistanceM, s.TravelMode.ToString(), s.ModeConfidence, s.IsEstimated, s.IsProvisional,
        includePath && s.Path is not null ? s.Path.Coordinates.Select(c => new GeoPoint(c.Y, c.X)).ToList() : null,
        s.RowVersion);

    private static TrackingAnomalyDto ToAnomalyDto(TrackingAnomaly a) => new(
        a.Id, a.AnomalyType, a.Severity, a.WindowStart, a.WindowEnd, a.LocalDate, a.DurationS,
        a.AcknowledgedAt, a.ResolvedAt);

    private static TrackingSessionDto ToSessionDto(TrackingSession s) => new(
        s.Id, s.Status.ToString(), s.StartedAt, s.EndedAt, s.EndReason, s.RowVersion);
}
