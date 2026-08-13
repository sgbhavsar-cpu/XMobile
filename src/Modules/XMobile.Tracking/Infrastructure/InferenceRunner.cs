using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using NetTopologySuite.Geometries;
using XMobile.Identity.Domain;
using XMobile.Persistence;
using XMobile.Persistence.Enums;
using XMobile.Shared;
using XMobile.Tracking.Domain;
using EngineModels = XMobile.Tracking.Engine.Models;

namespace XMobile.Tracking.Infrastructure;

/// <summary>
/// The "imperative shell" (docs/08 §4): loads evidence rows out of Postgres, builds the pure
/// engine's <see cref="EngineModels.JourneyInput"/>, calls <see cref="EngineModels.IJourneyEngine.Infer"/>,
/// and persists the resulting journey — the only place in the system that calls the engine.
/// </summary>
public sealed class InferenceRunner(
    XMobileDbContext db, IClock clock, ITourContextLookup tourLookup, IGeofenceLookup geofenceLookup)
{
    // No per-user timezone resolution this pass (AppUser.DefaultTimezone is an IANA name, not an
    // offset) — every window is reasoned about in this fixed IST offset, matching the engine's own
    // JourneyInput.LocalOffset default. Revisit once a user's actual offset needs to vary.
    private static readonly TimeSpan DefaultLocalOffset = TimeSpan.FromHours(5.5);

    public async Task RunAsync(
        Guid userId, DateTimeOffset windowFrom, DateTimeOffset windowTo, string triggerReason, CancellationToken ct)
    {
        var run = new InferenceRun
        {
            Id = Guid.NewGuid(),
            UserId = userId,
            WindowFrom = windowFrom,
            WindowTo = windowTo,
            TriggerReason = triggerReason,
            StartedAt = clock.UtcNow,
            EngineVersion = EngineModels.EngineConfig.EngineVersion,
        };

        var home = await db.Set<UserHomeLocation>()
            .FirstOrDefaultAsync(h => h.UserId == userId && h.EffectiveTo == null, ct);
        if (home is null)
        {
            // The engine's JourneyInput.Home is required — without it there is nothing to infer
            // against. Record the attempt (for audit) rather than throwing into the caller, since
            // this is an expected state for a newly onboarded user, not a bug.
            run.FinishedAt = clock.UtcNow;
            run.Status = "FAILED";
            run.Error = "No home location configured for this user";
            db.Add(run);
            await db.SaveChangesAsync(ct);
            return;
        }

        var localDate = DateOnly.FromDateTime((windowFrom + DefaultLocalOffset).DateTime);
        var tourContext = await tourLookup.GetForUserAsync(userId, localDate, ct);

        var homeGeofences = await geofenceLookup.GetByRefsAsync([("HOME", home.Id)], ct);
        var homeGeofence = homeGeofences.Count > 0 ? homeGeofences[0] : null;
        var homePlace = new EngineModels.Place
        {
            Id = home.Id,
            Kind = EngineModels.PlaceKind.Home,
            Name = home.Label,
            Point = home.Geog.ToGeoPoint().ToEngine(),
            RadiusM = homeGeofence?.RadiusM ?? home.GeofenceRadiusM,
            GeoSource = home.GeoSource.ToEngine(),
        };

        var siteRefs = (tourContext?.AllPlannedSiteIds ?? (IReadOnlyList<Guid>)[])
            .Select(id => ("CUSTOMER_SITE", id)).ToList();
        var siteGeofences = siteRefs.Count == 0 ? [] : await geofenceLookup.GetByRefsAsync(siteRefs, ct);
        var sitePlaces = siteGeofences.Select(g => new EngineModels.Place
        {
            Id = g.RefId,
            Kind = EngineModels.PlaceKind.CustomerSite,
            Name = g.Name,
            Point = g.Point.ToEngine(),
            RadiusM = g.RadiusM,
            // customer.geofence doesn't carry the site's own geo_source — a geofence existing at
            // all implies the site has field-captured or better coordinates (see fn_sync_site_geofence).
            GeoSource = EngineModels.GeoSource.FieldCaptured,
        }).ToList();

        var enginePings = (await db.Set<LocationPing>()
                .Where(p => p.UserId == userId && p.RecordedAt >= windowFrom && p.RecordedAt <= windowTo)
                .ToListAsync(ct))
            .Select(p => new EngineModels.Ping
            {
                Id = p.Id,
                RecordedAt = p.RecordedAt,
                CorrectedAt = p.CorrectedAt,
                Point = p.Geog.ToGeoPoint().ToEngine(),
                AccuracyM = p.AccuracyM,
                SpeedMps = p.SpeedMps,
                HeadingDeg = p.HeadingDeg,
                Activity = p.ActivityType.ToEngineActivity(),
                ActivityConfidence = p.ActivityConf,
                IsMoving = p.IsMoving,
                BatteryPct = p.BatteryPct,
                IsMock = p.IsMock,
                Source = p.Source.ToEngine(),
                DeviceTimeZone = p.DeviceTz,
            })
            .ToList();

        var geofenceEventRows = await db.Set<GeofenceEvent>()
            .Where(e => e.UserId == userId && e.OccurredAt >= windowFrom && e.OccurredAt <= windowTo)
            .ToListAsync(ct);
        var engineGeofenceEvents = new List<EngineModels.GeofenceEvent>();
        var geofenceCache = new Dictionary<Guid, GeofenceInfo?>();
        foreach (var e in geofenceEventRows)
        {
            if (!geofenceCache.TryGetValue(e.GeofenceId, out var info))
            {
                info = await geofenceLookup.GetByIdAsync(e.GeofenceId, ct);
                geofenceCache[e.GeofenceId] = info;
            }

            if (info is null)
            {
                continue; // stale/deactivated geofence — nothing to resolve a place from
            }

            engineGeofenceEvents.Add(new EngineModels.GeofenceEvent
            {
                Id = e.Id,
                GeofenceId = e.GeofenceId,
                PlaceKind = info.RefType.ToEnginePlaceKind(),
                PlaceId = info.RefId,
                Transition = e.EventType.ToEngine(),
                OccurredAt = e.OccurredAt,
                Point = e.Geog?.ToGeoPoint().ToEngine(),
                AccuracyM = e.AccuracyM,
                DwellSeconds = e.DwellSec,
                IsMock = e.IsMock,
            });
        }

        var engineStays = (await db.Set<StayDetection>()
                .Where(s => s.UserId == userId && s.ArrivedAt >= windowFrom && s.ArrivedAt <= windowTo)
                .ToListAsync(ct))
            .Select(s => new EngineModels.StayDetection
            {
                Id = s.Id,
                ArrivedAt = s.ArrivedAt,
                DepartedAt = s.DepartedAt,
                Point = s.Geog.ToGeoPoint().ToEngine(),
                AccuracyM = s.HorizontalAccuracyM,
                Source = s.Source,
            })
            .ToList();

        var enginePauses = (await db.Set<TrackingPause>()
                .Where(p => p.UserId == userId && p.PausedAt >= windowFrom && p.PausedAt <= windowTo)
                .ToListAsync(ct))
            .Select(p => new EngineModels.PauseWindow
            {
                Id = p.Id,
                PausedAt = p.PausedAt,
                ResumedAt = p.ResumedAt,
                ReasonCode = p.ReasonCode,
                AutoResumed = p.AutoResumed,
            })
            .ToList();

        var engineHealth = (await db.Set<DeviceHeartbeat>()
                .Where(h => h.UserId == userId && h.ReportedAt >= windowFrom && h.ReportedAt <= windowTo)
                .ToListAsync(ct))
            .Select(h => new EngineModels.HealthSample
            {
                ReportedAt = h.ReportedAt,
                BatteryPct = h.BatteryPct,
                IsPowerSaving = h.IsPowerSaving,
                LocationEnabled = h.LocationEnabled,
                ServiceRunning = h.ServiceRunning,
                PermissionLevel = h.PermissionLevel,
                QueuedPings = h.QueuedPings,
            })
            .ToList();

        var anchorRows = await db.Set<JourneyEvent>()
            .Where(e => e.UserId == userId && e.OccurredAt >= windowFrom && e.OccurredAt <= windowTo
                && e.Status != EventStatus.SUPERSEDED
                && (e.Status == EventStatus.CONFIRMED || e.OverriddenBy != null))
            .ToListAsync(ct);
        var anchorIds = anchorRows.Select(a => a.Id).ToHashSet();
        var anchors = anchorRows.Select(e => new EngineModels.JourneyEvent
        {
            Type = e.EventType.ToEngine(),
            OccurredAt = e.OccurredAt,
            LocalDate = e.LocalDate,
            Point = e.Geog is null ? null : e.Geog.ToGeoPoint().ToEngine(),
            PlaceKind = e.RefType.ToEnginePlaceKind(),
            PlaceId = e.RefId,
            Method = e.DetectionMethod.ToEngine(),
            Confidence = (double)e.Confidence,
            Status = e.Status.ToEngine(),
            IsEstimated = e.IsEstimated,
            IsAnchor = true,
        }).ToList();

        var stateRow = await db.Set<UserJourneyState>().FirstOrDefaultAsync(s => s.UserId == userId, ct);
        var entryState = stateRow?.State.ToEngine() ?? EngineModels.JourneyState.Unknown;

        var engineTour = tourContext is null
            ? null
            : new EngineModels.TourContext
            {
                TourId = tourContext.TourId,
                PlannedStartDate = tourContext.PlannedStartDate,
                PlannedEndDate = tourContext.PlannedEndDate,
                RemainingPlannedSiteIds = tourContext.RemainingPlannedSiteIds,
                AllPlannedSiteIds = tourContext.AllPlannedSiteIds,
            };

        var input = new EngineModels.JourneyInput
        {
            UserId = userId,
            WindowFrom = windowFrom,
            WindowTo = windowTo,
            Pings = enginePings,
            GeofenceEvents = engineGeofenceEvents,
            Stays = engineStays,
            Pauses = enginePauses,
            HealthSamples = engineHealth,
            Anchors = anchors,
            Home = homePlace,
            Sites = sitePlaces,
            Tour = engineTour,
            EntryState = entryState,
            LocalOffset = DefaultLocalOffset,
        };

        var result = new global::XMobile.Tracking.Engine.JourneyEngine().Infer(input);

        await PersistAsync(userId, tourContext?.TourId, windowFrom, windowTo, anchorIds, result, run, ct);
    }

    private async Task PersistAsync(
        Guid userId, Guid? tourId, DateTimeOffset windowFrom, DateTimeOffset windowTo, HashSet<Guid> anchorIds,
        EngineModels.JourneyResult result, InferenceRun run, CancellationToken ct)
    {
        // Events: soft-supersede every non-anchor row already in the window (status = SUPERSEDED)
        // so the correction/audit trail survives — see db/README.md "rebuild supersedes AUTO rows".
        var existingEvents = await db.Set<JourneyEvent>()
            .Where(e => e.UserId == userId && e.OccurredAt >= windowFrom && e.OccurredAt <= windowTo
                && e.Status != EventStatus.SUPERSEDED)
            .ToListAsync(ct);
        var supersededCount = 0;
        foreach (var existing in existingEvents.Where(e => !anchorIds.Contains(e.Id)))
        {
            existing.Status = EventStatus.SUPERSEDED;
            supersededCount++;
        }

        // Anchors are echoed back into result.Events by the engine (ApplyAnchors) — they already
        // have a row (the one just marked untouched above), so only the AUTO-detected ones are new.
        var createdCount = 0;
        foreach (var e in result.Events.Where(ev => !ev.IsAnchor))
        {
            db.Add(new JourneyEvent
            {
                UserId = userId,
                TourId = tourId,
                EventType = e.Type.ToPersistence(),
                OccurredAt = e.OccurredAt,
                DetectedAt = clock.UtcNow,
                LocalDate = e.LocalDate,
                Geog = e.Point.HasValue ? e.Point.Value.ToShared().ToNtsPoint() : null,
                RefType = e.PlaceKind.ToRefType(),
                RefId = e.PlaceId,
                SiteId = e.PlaceKind == EngineModels.PlaceKind.CustomerSite ? e.PlaceId : null,
                DetectionMethod = e.Method.ToPersistence(),
                Confidence = Math.Round((decimal)e.Confidence, 2),
                Status = e.Status.ToPersistence(),
                IsEstimated = e.IsEstimated,
                Evidence = JsonSerializer.Serialize(e.Evidence),
                InferenceRunId = run.Id,
            });
            createdCount++;
        }

        run.EventsSuperseded = supersededCount;
        run.EventsCreated = createdCount;

        // Segments carry no status column (unlike journey_event) and have no anchor concept — a
        // rebuild simply replaces every segment in the window wholesale. FromEventId/ToEventId are
        // left unset: the engine's JourneySegment doesn't carry event references, and matching them
        // up after the fact is a nice-to-have cross-reference, not load-bearing (same "no
        // auto-linking" philosophy as the plan's visit-row scope decision).
        var existingSegments = await db.Set<JourneySegment>()
            .Where(s => s.UserId == userId && s.StartedAt >= windowFrom && s.StartedAt <= windowTo)
            .ToListAsync(ct);
        db.RemoveRange(existingSegments);

        foreach (var s in result.Segments)
        {
            db.Add(new JourneySegment
            {
                UserId = userId,
                TourId = tourId,
                SegmentType = s.Type.ToPersistence(),
                StartedAt = s.StartedAt,
                EndedAt = s.EndedAt,
                LocalDate = s.LocalDate,
                RefType = s.PlaceKind.ToRefType(),
                RefId = s.PlaceId,
                SiteId = s.PlaceKind == EngineModels.PlaceKind.CustomerSite ? s.PlaceId : null,
                DistanceM = s.DistanceM,
                StraightLineM = s.StraightLineM,
                TravelMode = s.TravelMode.ToPersistence(),
                ModeConfidence = s.ModeConfidence.HasValue ? Math.Round((decimal)s.ModeConfidence.Value, 2) : null,
                Path = s.Path.Count >= 2
                    ? new LineString(s.Path.Select(p => new Coordinate(p.Lon, p.Lat)).ToArray()) { SRID = 4326 }
                    : null,
                PingCount = s.PingCount,
                IsEstimated = s.IsEstimated,
                IsProvisional = s.IsProvisional,
                InferenceRunId = run.Id,
            });
        }

        run.SegmentsCreated = result.Segments.Count;

        // Anomalies are an append-only log a manager can acknowledge/resolve, not a rebuildable
        // projection — so unlike events/segments, a rerun over the same window must not spam
        // duplicates. Skip any (type, windowStart) pair already raised for this user/window.
        var existingAnomalyKeys = (await db.Set<TrackingAnomaly>()
                .Where(a => a.UserId == userId && a.WindowStart >= windowFrom && a.WindowStart <= windowTo)
                .Select(a => new { a.AnomalyType, a.WindowStart })
                .ToListAsync(ct))
            .Select(a => (a.AnomalyType, a.WindowStart))
            .ToHashSet();

        foreach (var anomaly in result.Anomalies)
        {
            if (existingAnomalyKeys.Contains((anomaly.Type, anomaly.WindowStart)))
            {
                continue;
            }

            db.Add(new TrackingAnomaly
            {
                UserId = userId,
                TourId = tourId,
                AnomalyType = anomaly.Type,
                Severity = anomaly.Severity.ToString().ToUpperInvariant(),
                WindowStart = anomaly.WindowStart,
                WindowEnd = anomaly.WindowEnd,
                LocalDate = anomaly.LocalDate,
                DurationS = anomaly.DurationSeconds,
                Details = JsonSerializer.Serialize(anomaly.Details),
                DetectedAt = clock.UtcNow,
            });
        }

        await UpsertJourneyStateAsync(userId, tourId, result, ct);

        run.FinishedAt = clock.UtcNow;
        run.Status = "SUCCESS";
        db.Add(run);

        await db.SaveChangesAsync(ct);
    }

    private async Task UpsertJourneyStateAsync(
        Guid userId, Guid? tourId, EngineModels.JourneyResult result, CancellationToken ct)
    {
        var currentSegment = result.Segments.Where(s => s.EndedAt is null).OrderByDescending(s => s.StartedAt)
            .FirstOrDefault() ?? result.Segments.OrderByDescending(s => s.StartedAt).FirstOrDefault();
        var lastPing = await db.Set<LocationPing>()
            .Where(p => p.UserId == userId).OrderByDescending(p => p.RecordedAt).FirstOrDefaultAsync(ct);

        var state = await db.Set<UserJourneyState>().FirstOrDefaultAsync(s => s.UserId == userId, ct);
        if (state is null)
        {
            state = new UserJourneyState { UserId = userId };
            db.Add(state);
        }

        state.State = result.EndState.ToPersistence();
        state.TourId = tourId;
        state.RefType = currentSegment?.PlaceKind.ToRefType();
        state.RefId = currentSegment?.PlaceId;
        state.SiteId = currentSegment?.PlaceKind == EngineModels.PlaceKind.CustomerSite ? currentSegment.PlaceId : null;
        state.Since = currentSegment?.StartedAt;
        state.LastPingAt = lastPing?.RecordedAt;
        state.LastPingGeog = lastPing?.Geog;
        state.LastEvaluatedAt = clock.UtcNow;
        // A simple recency heuristic stands in for real health scoring (device_heartbeat-driven
        // health, not yet wired here) — "has this device reported in the last two hours".
        state.TrackingActive = lastPing is not null && clock.UtcNow - lastPing.RecordedAt < TimeSpan.FromHours(2);
    }
}
