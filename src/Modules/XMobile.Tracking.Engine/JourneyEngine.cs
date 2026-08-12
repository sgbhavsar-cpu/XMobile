using XMobile.Tracking.Engine.Detection;
using XMobile.Tracking.Engine.Geo;
using XMobile.Tracking.Engine.Models;

namespace XMobile.Tracking.Engine;

/// <summary>
/// Infers a rep's journey from whatever evidence the devices managed to produce.
///
/// The governing assumption (docs/03 §1): the phone cannot be relied on for a continuous,
/// timely stream — iOS suspends background location, Android OEMs kill services, and BYOD
/// devices cannot be configured centrally. It can be relied on to emit *some* evidence around
/// every significant transition, eventually. So the device detects opportunistically and this
/// engine decides, with the ability to revise when late evidence arrives.
/// </summary>
public sealed class JourneyEngine : IJourneyEngine
{
    public JourneyResult Infer(JourneyInput input)
    {
        var config = input.Config;

        // Order on the skew-corrected clock, with the id as a deterministic tie-break: two
        // fixes can share a timestamp, and a stable order is what makes replay reproducible.
        var orderedPings = input.Pings
            .Where(p => p.Point.IsValid)
            .OrderBy(p => p.EffectiveAt)
            .ThenBy(p => p.Id)
            .ToList();

        var decisionPings = orderedPings.Where(p => p.IsDecisionGrade(config)).ToList();

        var anomalies = new AnomalyDetector(config).Detect(input, orderedPings);

        var resolver = new PresenceResolver(config);
        var runs = resolver.BuildRuns(decisionPings, input.Home, input.Sites, input.Tour);

        var candidates = BuildCandidates(input, runs, decisionPings);
        candidates = ApplyAnchors(input, candidates);

        var (events, endState) = RunStateMachine(input, candidates, decisionPings);
        var segments = BuildSegments(input, events, runs, decisionPings, endState);

        return new JourneyResult
        {
            Events = events,
            Segments = segments,
            Anomalies = anomalies,
            EndState = endState
        };
    }

    // ------------------------------------------------------------------ candidates

    private static List<JourneyEvent> BuildCandidates(
        JourneyInput input, List<PresenceRun> runs, List<Ping> decisionPings)
    {
        var config = input.Config;
        var candidates = new List<JourneyEvent>();

        candidates.AddRange(FromPresenceRuns(input, runs));
        candidates.AddRange(FromGeofenceEventsWithoutRuns(input, runs));
        candidates.AddRange(FromStaysWithoutRuns(input, runs));
        candidates.AddRange(FromOvernightStops(input, runs, decisionPings));

        var backEstimated = BackEstimateDeparture(input, decisionPings, candidates);
        if (backEstimated is not null) candidates.Add(backEstimated);

        return candidates
            .Where(c => c.Confidence >= config.ReviewConfidenceFloor)
            .OrderBy(c => c.OccurredAt)
            .ThenBy(c => (int)c.Type)
            .ThenBy(c => c.PlaceId)
            .ToList();
    }

    private static IEnumerable<JourneyEvent> FromPresenceRuns(JourneyInput input, List<PresenceRun> runs)
    {
        var config = input.Config;

        for (var i = 0; i < runs.Count; i++)
        {
            var run = runs[i];
            if (run.Place is null) continue;

            var isHome = run.Place.Kind == PlaceKind.Home;
            var requiredDwell = isHome ? config.HomeArrivalDwell : config.MinDwellForArrival;

            var geofenceEnter = FindGeofenceEvent(input, run.Place.Id, GeofenceTransition.Enter,
                run.StartedAt, config.GapThreshold);
            var corroboratingStay = FindStay(input, run.Place, run.StartedAt, config);

            // Dwell can be satisfied by duration, or by an OS-level corroboration when the
            // platform gave us too few fixes to measure it ourselves.
            var dwellSatisfied = run.Duration >= requiredDwell
                                 || corroboratingStay is not null
                                 || geofenceEnter?.Transition == GeofenceTransition.Dwell;

            if (!dwellSatisfied) continue;

            var (method, confidence) = ScoreArrival(run, geofenceEnter, corroboratingStay, config);

            var evidence = new Dictionary<string, object>
            {
                ["run_pings"] = run.Pings.Count,
                ["dwell_s"] = Math.Round(run.Duration.TotalSeconds),
                ["geofence_event"] = geofenceEnter is not null,
                ["stay_corroborated"] = corroboratingStay is not null,
                ["geo_source"] = run.Place.GeoSource.ToString()
            };

            // Arrival time is the FIRST fix inside the fence — not the geofence callback, which
            // on iOS can be twenty minutes late and would systematically overstate arrival.
            yield return new JourneyEvent
            {
                Type = isHome ? JourneyEventType.ArriveHome : JourneyEventType.ArriveCustomer,
                OccurredAt = run.StartedAt,
                LocalDate = AnomalyDetector.LocalDateOf(run.StartedAt, input.LocalOffset),
                Point = run.Pings[0].Point,
                PlaceKind = run.Place.Kind,
                PlaceId = run.Place.Id,
                CustomerId = run.Place.CustomerId,
                Method = method,
                Confidence = confidence,
                Status = StatusFor(confidence, config),
                Evidence = evidence
            };

            // A departure only exists if there is evidence of leaving. The last run in the
            // window is still in progress as far as we know.
            if (i >= runs.Count - 1) continue;

            var departureConfidence = ScoreDeparture(input, run, runs[i + 1], config);
            if (departureConfidence < config.ReviewConfidenceFloor) continue;

            yield return new JourneyEvent
            {
                Type = isHome ? JourneyEventType.DepartHome : JourneyEventType.DepartCustomer,
                OccurredAt = run.EndedAt,          // last fix still inside the fence
                LocalDate = AnomalyDetector.LocalDateOf(run.EndedAt, input.LocalOffset),
                Point = run.Pings[^1].Point,
                PlaceKind = run.Place.Kind,
                PlaceId = run.Place.Id,
                CustomerId = run.Place.CustomerId,
                Method = FindGeofenceEvent(input, run.Place.Id, GeofenceTransition.Exit,
                             run.EndedAt, config.GapThreshold) is not null
                    ? DetectionMethod.Geofence
                    : DetectionMethod.PingCluster,
                Confidence = departureConfidence,
                Status = StatusFor(departureConfidence, config),
                Evidence = new Dictionary<string, object>
                {
                    ["displacement_m"] = Math.Round(DisplacementAfter(runs[i + 1], run.EndedAt, config)),
                    ["next_run_place"] = runs[i + 1].Place?.Name ?? "transit"
                }
            };
        }
    }

    private static (DetectionMethod Method, double Confidence) ScoreArrival(
        PresenceRun run, GeofenceEvent? geofenceEnter, StayDetection? stay, EngineConfig config)
    {
        double confidence;
        DetectionMethod method;

        if (geofenceEnter is not null)
        {
            method = DetectionMethod.Geofence;
            confidence = 0.90;
        }
        else if (run.Pings.Count >= 3)
        {
            method = DetectionMethod.PingCluster;
            confidence = 0.80;
        }
        else if (stay is not null)
        {
            method = DetectionMethod.IosVisit;
            confidence = 0.70;
        }
        else
        {
            method = DetectionMethod.Dwell;
            confidence = 0.60;
        }

        if (stay is not null && method != DetectionMethod.IosVisit) confidence += 0.05;

        // A merely geocoded coordinate is a guess; arrivals there stay detectable but must not
        // be trusted enough to auto-confirm a visit record.
        if (run.Place is { IsTrustedLocation: false }) confidence -= config.UntrustedLocationPenalty;

        return (method, Math.Clamp(confidence, 0, 1));
    }

    private static double ScoreDeparture(
        JourneyInput input, PresenceRun run, PresenceRun next, EngineConfig config)
    {
        var exitEvent = FindGeofenceEvent(input, run.Place!.Id, GeofenceTransition.Exit,
            run.EndedAt, config.GapThreshold);

        var displacement = DisplacementAfter(next, run.EndedAt, config);
        var displacementConfirmed = displacement >= config.DepartDisplacementM;

        var confidence = (exitEvent, displacementConfirmed) switch
        {
            (not null, true) => 0.95,
            (not null, false) => 0.75,
            (null, true) => 0.80,
            _ => 0.50
        };

        // Arriving somewhere else is itself proof of having left.
        if (next.Place is not null) confidence = Math.Max(confidence, 0.85);

        if (!run.Place.IsTrustedLocation) confidence -= config.UntrustedLocationPenalty;

        return Math.Clamp(confidence, 0, 1);
    }

    private static double DisplacementAfter(PresenceRun next, DateTimeOffset from, EngineConfig config)
    {
        var origin = next.Pings.Count > 0 ? next.Pings[0].Point : default;

        var within = next.Pings
            .Where(p => p.EffectiveAt - from <= config.DepartDisplacementWindow)
            .ToList();

        return within.Count == 0 ? 0 : within.Max(p => GeoMath.DistanceM(origin, p.Point));
    }

    /// <summary>
    /// iOS frequently reports a region crossing while suppressing the fixes around it. Without
    /// this the arrival simply would not exist on half the fleet.
    /// </summary>
    private static IEnumerable<JourneyEvent> FromGeofenceEventsWithoutRuns(
        JourneyInput input, List<PresenceRun> runs)
    {
        var config = input.Config;

        foreach (var evt in input.GeofenceEvents.Where(e => e.Transition != GeofenceTransition.Exit))
        {
            if (evt.IsMock) continue;

            var covered = runs.Any(r => r.Place?.Id == evt.PlaceId
                                        && evt.OccurredAt >= r.StartedAt.AddMinutes(-15)
                                        && evt.OccurredAt <= r.EndedAt.AddMinutes(15));
            if (covered) continue;

            var place = FindPlace(input, evt.PlaceId);
            if (place is null) continue;

            var stay = FindStay(input, place, evt.OccurredAt, config);
            var confidence = stay is not null ? 0.75 : 0.65;
            if (!place.IsTrustedLocation) confidence -= config.UntrustedLocationPenalty;

            yield return new JourneyEvent
            {
                Type = place.Kind == PlaceKind.Home
                    ? JourneyEventType.ArriveHome
                    : JourneyEventType.ArriveCustomer,
                OccurredAt = evt.OccurredAt,
                LocalDate = AnomalyDetector.LocalDateOf(evt.OccurredAt, input.LocalOffset),
                Point = evt.Point ?? place.Point,
                PlaceKind = place.Kind,
                PlaceId = place.Id,
                CustomerId = place.CustomerId,
                Method = DetectionMethod.Geofence,
                Confidence = Math.Clamp(confidence, 0, 1),
                Status = StatusFor(confidence, config),
                Evidence = new Dictionary<string, object>
                {
                    ["source"] = "geofence-without-fixes",
                    ["stay_corroborated"] = stay is not null
                }
            };
        }
    }

    private static IEnumerable<JourneyEvent> FromStaysWithoutRuns(
        JourneyInput input, List<PresenceRun> runs)
    {
        var config = input.Config;

        foreach (var stay in input.Stays)
        {
            var place = MatchPlace(input, stay.Point);
            if (place is null) continue;

            var covered = runs.Any(r => r.Place?.Id == place.Id
                                        && stay.ArrivedAt >= r.StartedAt.AddMinutes(-15)
                                        && stay.ArrivedAt <= r.EndedAt.AddMinutes(15));
            if (covered) continue;

            var alreadyFromGeofence = input.GeofenceEvents.Any(
                e => e.PlaceId == place.Id
                     && (e.OccurredAt - stay.ArrivedAt).Duration() < TimeSpan.FromMinutes(20));
            if (alreadyFromGeofence) continue;

            var confidence = 0.65;
            if (!place.IsTrustedLocation) confidence -= config.UntrustedLocationPenalty;

            yield return new JourneyEvent
            {
                Type = place.Kind == PlaceKind.Home
                    ? JourneyEventType.ArriveHome
                    : JourneyEventType.ArriveCustomer,
                OccurredAt = stay.ArrivedAt,
                LocalDate = AnomalyDetector.LocalDateOf(stay.ArrivedAt, input.LocalOffset),
                Point = stay.Point,
                PlaceKind = place.Kind,
                PlaceId = place.Id,
                CustomerId = place.CustomerId,
                Method = DetectionMethod.IosVisit,
                Confidence = Math.Clamp(confidence, 0, 1),
                Status = StatusFor(confidence, config),
                Evidence = new Dictionary<string, object> { ["source"] = stay.Source }
            };
        }
    }

    /// <summary>
    /// A long stationary night away from home and away from any customer: a hotel. Worth
    /// detecting explicitly — it anchors the multi-day tour and drives the lodging expense prompt.
    /// </summary>
    private static IEnumerable<JourneyEvent> FromOvernightStops(
        JourneyInput input, List<PresenceRun> runs, List<Ping> decisionPings)
    {
        var config = input.Config;

        // A hotel stay sits *inside* a transit run — travel, stop, travel — so the search has to
        // be for stationary clusters within the run, not for whole runs that happen to be still.
        // Testing the run as a whole finds nothing on a real multi-day tour: its spread is the
        // width of the country.
        foreach (var run in runs.Where(r => r.Place is null))
        {
            foreach (var cluster in FindStationaryClusters(run.Pings, config))
            {
                if (!OverlapsNightWindow(cluster[0].EffectiveAt, cluster[^1].EffectiveAt, input)) continue;

                yield return OvernightEvent(input, JourneyEventType.OvernightStopStart,
                    cluster[0].EffectiveAt, cluster[0].Point, cluster.Count, estimated: false);

                yield return OvernightEvent(input, JourneyEventType.OvernightStopEnd,
                    cluster[^1].EffectiveAt, cluster[^1].Point, cluster.Count, estimated: false);
            }
        }

        // A phone that dies overnight leaves a gap rather than a stationary run. If the rep is
        // in the same place either side of it, that is still an overnight stop — just an
        // inferred one, and it must be marked as such.
        for (var i = 1; i < decisionPings.Count; i++)
        {
            var before = decisionPings[i - 1];
            var after = decisionPings[i];
            var gap = after.EffectiveAt - before.EffectiveAt;

            if (gap < config.OvernightStationary) continue;
            if (GeoMath.DistanceM(before.Point, after.Point) > config.OvernightSpreadM) continue;
            if (MatchPlace(input, before.Point) is not null) continue;
            if (!OverlapsNightWindow(before.EffectiveAt, after.EffectiveAt, input)) continue;

            yield return OvernightEvent(input, JourneyEventType.OvernightStopStart,
                before.EffectiveAt, before.Point, 0, estimated: true);

            yield return OvernightEvent(input, JourneyEventType.OvernightStopEnd,
                after.EffectiveAt, after.Point, 0, estimated: true);
        }
    }

    /// <summary>
    /// Maximal runs of consecutive fixes that stay within the overnight spread and last long
    /// enough to be a stop rather than a traffic jam.
    /// </summary>
    private static List<List<Ping>> FindStationaryClusters(List<Ping> pings, EngineConfig config)
    {
        var clusters = new List<List<Ping>>();

        var i = 0;
        while (i < pings.Count)
        {
            var anchor = pings[i].Point;
            var j = i;

            while (j + 1 < pings.Count
                   && GeoMath.DistanceM(anchor, pings[j + 1].Point) <= config.OvernightSpreadM)
            {
                j++;
            }

            if (pings[j].EffectiveAt - pings[i].EffectiveAt >= config.OvernightStationary)
            {
                clusters.Add(pings.GetRange(i, j - i + 1));
                i = j + 1;
                continue;
            }

            i++;
        }

        return clusters;
    }

    private static JourneyEvent OvernightEvent(
        JourneyInput input, JourneyEventType type, DateTimeOffset at, GeoPoint point,
        int pingCount, bool estimated) => new()
        {
            Type = type,
            OccurredAt = at,
            LocalDate = AnomalyDetector.LocalDateOf(at, input.LocalOffset),
            Point = point,
            PlaceKind = PlaceKind.Stay,
            Method = estimated ? DetectionMethod.InferredFromGap : DetectionMethod.Dwell,
            Confidence = estimated ? 0.55 : 0.80,
            Status = StatusFor(estimated ? 0.55 : 0.80, input.Config),
            IsEstimated = estimated,
            Evidence = new Dictionary<string, object>
            {
                ["ping_count"] = pingCount,
                ["inferred_from_gap"] = estimated
            }
        };

    private static bool OverlapsNightWindow(DateTimeOffset from, DateTimeOffset to, JourneyInput input)
    {
        var config = input.Config;

        // Walk the interval in hourly steps: cheap, and correct across midnight and across a
        // multi-day stop without special-casing either.
        for (var cursor = from; cursor <= to; cursor = cursor.AddHours(1))
        {
            var localTime = TimeOnly.FromDateTime(cursor.ToOffset(input.LocalOffset).DateTime);

            var inWindow = config.OvernightWindowStart <= config.OvernightWindowEnd
                ? localTime >= config.OvernightWindowStart && localTime <= config.OvernightWindowEnd
                : localTime >= config.OvernightWindowStart || localTime <= config.OvernightWindowEnd;

            if (inWindow) return true;
        }

        return false;
    }

    /// <summary>
    /// When the first evidence of the day is already far from home, the departure happened
    /// during a blind spot. Estimating it beats leaving the day with no start — but the
    /// estimate is flagged so nobody mistakes it for an observation.
    /// </summary>
    private static JourneyEvent? BackEstimateDeparture(
        JourneyInput input, List<Ping> decisionPings, List<JourneyEvent> existing)
    {
        if (input.EntryState != JourneyState.AtHome) return null;
        if (decisionPings.Count == 0) return null;
        if (existing.Any(e => e.Type == JourneyEventType.DepartHome)) return null;

        var first = decisionPings[0];
        var distanceFromHome = GeoMath.DistanceM(first.Point, input.Home.Point);
        if (distanceFromHome <= input.Home.RadiusM) return null;

        // Assume 45 km/h door to door: slower than a highway, faster than a city crawl.
        const double assumedKmph = 45.0;
        var travelHours = distanceFromHome / 1000.0 / assumedKmph;
        var estimatedAt = first.EffectiveAt.AddHours(-travelHours);

        if (estimatedAt < input.WindowFrom) estimatedAt = input.WindowFrom;

        return new JourneyEvent
        {
            Type = JourneyEventType.DepartHome,
            OccurredAt = estimatedAt,
            LocalDate = AnomalyDetector.LocalDateOf(estimatedAt, input.LocalOffset),
            Point = input.Home.Point,
            PlaceKind = PlaceKind.Home,
            PlaceId = input.Home.Id,
            Method = DetectionMethod.InferredFromGap,
            Confidence = 0.60,
            Status = EventStatus.NeedsReview,
            IsEstimated = true,
            Evidence = new Dictionary<string, object>
            {
                ["distance_from_home_m"] = Math.Round(distanceFromHome),
                ["assumed_kmph"] = assumedKmph,
                ["first_evidence_at"] = first.EffectiveAt
            }
        };
    }

    // ------------------------------------------------------------------ anchors

    /// <summary>
    /// Manual corrections and confirmed events are fixed points. A rebuild reproduces the
    /// journey around them; it never overwrites them.
    /// </summary>
    private static List<JourneyEvent> ApplyAnchors(JourneyInput input, List<JourneyEvent> candidates)
    {
        if (input.Anchors.Count == 0) return candidates;

        var config = input.Config;
        var kept = candidates
            .Where(c => !input.Anchors.Any(a =>
                a.Type == c.Type
                && a.PlaceId == c.PlaceId
                && (a.OccurredAt - c.OccurredAt).Duration() <= config.AnchorSuppressionWindow))
            .ToList();

        kept.AddRange(input.Anchors.Select(a => a with
        {
            IsAnchor = true,
            Confidence = 1.0,
            Status = EventStatus.Confirmed
        }));

        return kept
            .OrderBy(c => c.OccurredAt)
            .ThenBy(c => (int)c.Type)
            .ThenBy(c => c.PlaceId)
            .ToList();
    }

    // ------------------------------------------------------------------ state machine

    private static (List<JourneyEvent> Events, JourneyState EndState) RunStateMachine(
        JourneyInput input, List<JourneyEvent> candidates, List<Ping> decisionPings)
    {
        var config = input.Config;
        var scorer = new ReturnLegScorer(config);

        var state = input.EntryState;
        var currentPlaceId = state == JourneyState.AtHome ? input.Home.Id : (Guid?)null;
        var accepted = new List<JourneyEvent>();

        for (var i = 0; i < candidates.Count; i++)
        {
            var candidate = candidates[i];

            switch (candidate.Type)
            {
                case JourneyEventType.ArriveHome:
                    if (state == JourneyState.AtHome && currentPlaceId == candidate.PlaceId) continue;

                    // Getting home is proof that the preceding leg was the journey home.
                    PromoteProvisionalReturn(accepted, config);

                    accepted.Add(candidate);
                    state = JourneyState.AtHome;
                    currentPlaceId = candidate.PlaceId;
                    break;

                case JourneyEventType.DepartHome:
                    // Departing a place we were never at is noise, unless we genuinely do not
                    // know where the rep was.
                    if (state is not (JourneyState.AtHome or JourneyState.Unknown)) continue;
                    accepted.Add(candidate);
                    state = JourneyState.OutboundTransit;
                    currentPlaceId = null;
                    break;

                case JourneyEventType.ArriveCustomer:
                    if (state == JourneyState.AtCustomer && currentPlaceId == candidate.PlaceId) continue;

                    // Arriving at a customer retroactively disproves a provisional return leg.
                    DemoteProvisionalReturn(accepted);

                    accepted.Add(candidate);
                    state = JourneyState.AtCustomer;
                    currentPlaceId = candidate.PlaceId;
                    break;

                case JourneyEventType.DepartCustomer:
                    if (state != JourneyState.AtCustomer || currentPlaceId != candidate.PlaceId) continue;
                    accepted.Add(candidate);
                    state = JourneyState.InterTransit;
                    currentPlaceId = null;

                    var returnEvent = EvaluateReturn(input, scorer, candidates, decisionPings, i, candidate);
                    if (returnEvent is not null)
                    {
                        accepted.Add(returnEvent);
                        state = JourneyState.ReturnTransit;
                    }
                    break;

                case JourneyEventType.OvernightStopStart:
                    if (state is JourneyState.AtHome or JourneyState.AtCustomer) continue;
                    accepted.Add(candidate);
                    state = JourneyState.OvernightStop;
                    break;

                case JourneyEventType.OvernightStopEnd:
                    if (state != JourneyState.OvernightStop) continue;
                    accepted.Add(candidate);

                    // Resume whichever leg we were on; the following arrival will correct it.
                    state = accepted.Any(e => e.Type == JourneyEventType.StartReturn)
                        ? JourneyState.ReturnTransit
                        : JourneyState.OutboundTransit;

                    // On a multi-day tour the return leg usually starts by checking out of a
                    // hotel, not by leaving a customer — so the return test has to run here too,
                    // or a homeward journey that began after an overnight is never detected.
                    if (state != JourneyState.ReturnTransit)
                    {
                        var afterOvernight = EvaluateReturn(
                            input, scorer, candidates, decisionPings, i, candidate);

                        if (afterOvernight is not null)
                        {
                            accepted.Add(afterOvernight);
                            state = JourneyState.ReturnTransit;
                        }
                    }
                    break;

                case JourneyEventType.StartReturn:
                    if (state == JourneyState.ReturnTransit) continue;
                    accepted.Add(candidate);
                    state = JourneyState.ReturnTransit;
                    break;

                default:
                    accepted.Add(candidate);
                    break;
            }
        }

        var endState = ApplyPauseAtWindowEnd(input, state);

        return (accepted.OrderBy(e => e.OccurredAt).ThenBy(e => (int)e.Type).ToList(), endState);
    }

    /// <summary>
    /// "Heading home" and "heading to the next customer" look identical for the first few
    /// kilometres. Below the confidence bar the event is still recorded, but provisionally, and
    /// a later customer arrival withdraws it.
    /// </summary>
    private static JourneyEvent? EvaluateReturn(
        JourneyInput input,
        ReturnLegScorer scorer,
        List<JourneyEvent> candidates,
        List<Ping> decisionPings,
        int departureIndex,
        JourneyEvent departure)
    {
        var config = input.Config;

        var nextArrival = candidates
            .Skip(departureIndex + 1)
            .FirstOrDefault(c => c.Type is JourneyEventType.ArriveCustomer or JourneyEventType.ArriveHome);

        var until = nextArrival?.OccurredAt ?? input.WindowTo;

        var transitPings = decisionPings
            .Where(p => p.EffectiveAt > departure.OccurredAt && p.EffectiveAt <= until)
            .ToList();

        if (transitPings.Count == 0) return null;

        var remainingSites = input.Sites
            .Where(s => input.Tour?.RemainingPlannedSiteIds.Contains(s.Id) ?? false)
            .Where(s => s.Id != departure.PlaceId)
            .ToList();

        var score = scorer.Evaluate(transitPings, input.Home, remainingSites, input.Tour, departure.LocalDate);

        if (score.Value < config.ReviewConfidenceFloor) return null;

        var isProvisional = score.Value < config.AutoConfirmConfidence;

        return new JourneyEvent
        {
            Type = JourneyEventType.StartReturn,
            OccurredAt = departure.OccurredAt,
            LocalDate = departure.LocalDate,
            Point = departure.Point,
            Method = DetectionMethod.Activity,
            Confidence = score.Value,
            Status = isProvisional ? EventStatus.NeedsReview : EventStatus.Detected,
            Evidence = score.Evidence
        };
    }

    private static void PromoteProvisionalReturn(List<JourneyEvent> accepted, EngineConfig config)
    {
        for (var i = accepted.Count - 1; i >= 0; i--)
        {
            if (accepted[i].Type != JourneyEventType.StartReturn) continue;
            if (accepted[i].Status != EventStatus.NeedsReview) return;

            var evidence = new Dictionary<string, object>(accepted[i].Evidence)
            {
                ["confirmed_by_home_arrival"] = true
            };

            accepted[i] = accepted[i] with
            {
                Status = EventStatus.Detected,
                Confidence = Math.Max(accepted[i].Confidence, config.AutoConfirmConfidence),
                Evidence = evidence
            };
            return;
        }
    }

    private static void DemoteProvisionalReturn(List<JourneyEvent> accepted)
    {
        for (var i = accepted.Count - 1; i >= 0; i--)
        {
            if (accepted[i].Type != JourneyEventType.StartReturn) continue;
            if (accepted[i].IsAnchor) return;               // the rep said so; leave it alone
            if (accepted[i].Status != EventStatus.NeedsReview) return;

            accepted.RemoveAt(i);
            return;
        }
    }

    private static JourneyState ApplyPauseAtWindowEnd(JourneyInput input, JourneyState state)
        => input.Pauses.Any(p => p.ResumedAt is null && p.PausedAt <= input.WindowTo)
            ? JourneyState.Paused
            : state;

    // ------------------------------------------------------------------ segments

    private static List<JourneySegment> BuildSegments(
        JourneyInput input,
        List<JourneyEvent> events,
        List<PresenceRun> runs,
        List<Ping> decisionPings,
        JourneyState endState)
    {
        var config = input.Config;
        var segments = new List<JourneySegment>();
        if (events.Count == 0) return segments;

        var state = input.EntryState;
        Guid? placeId = state == JourneyState.AtHome ? input.Home.Id : null;

        for (var i = 0; i < events.Count; i++)
        {
            var current = events[i];
            var next = i + 1 < events.Count ? events[i + 1] : null;

            (state, placeId) = StateAfter(current, state, placeId, input);

            var from = current.OccurredAt;
            var to = next?.OccurredAt ?? input.WindowTo;
            if (to <= from) continue;

            var segmentType = SegmentTypeFor(state);
            var pings = decisionPings.Where(p => p.EffectiveAt >= from && p.EffectiveAt <= to).ToList();

            var (distanceM, isEstimated) = MeasureDistance(pings, from, to, config, segmentType);

            var path = GeoMath.Simplify(pings.Select(p => p.Point).ToList(), config.PathSimplifyToleranceM);

            var mode = TravelMode.Unknown;
            double? modeConfidence = null;

            if (IsTravel(segmentType))
            {
                var classification = pings.Count >= 2
                    ? TravelModeClassifier.Classify(pings, distanceM, to - from, config)
                    : TravelModeClassifier.ClassifyGapJump(distanceM, to - from);

                mode = classification.Mode;
                modeConfidence = classification.Confidence;
            }

            var place = placeId is null ? null : FindPlace(input, placeId.Value);

            segments.Add(new JourneySegment
            {
                Type = segmentType,
                StartedAt = from,
                EndedAt = next is null && endState == JourneyState.Unknown ? null : to,
                LocalDate = AnomalyDetector.LocalDateOf(from, input.LocalOffset),
                PlaceKind = place?.Kind ?? (segmentType == SegmentType.OvernightStop
                    ? PlaceKind.Stay
                    : PlaceKind.None),
                PlaceId = placeId,
                CustomerId = place?.CustomerId,
                DistanceM = distanceM,
                StraightLineM = pings.Count >= 2
                    ? (long)Math.Round(GeoMath.DistanceM(pings[0].Point, pings[^1].Point))
                    : 0,
                TravelMode = mode,
                ModeConfidence = modeConfidence,
                PingCount = pings.Count,
                IsEstimated = isEstimated,
                IsProvisional = segmentType == SegmentType.ReturnTravel
                                && current.Type == JourneyEventType.StartReturn
                                && current.Status == EventStatus.NeedsReview,
                Path = path
            });
        }

        return segments;
    }

    /// <summary>
    /// Distance from the fixes, plus a road-factored straight line across any gap inside the
    /// interval. A segment containing an estimate says so, because estimated kilometres must
    /// never be silently reimbursed.
    /// </summary>
    private static (long DistanceM, bool IsEstimated) MeasureDistance(
        List<Ping> pings, DateTimeOffset from, DateTimeOffset to, EngineConfig config, SegmentType type)
    {
        if (!IsTravel(type)) return (0, false);
        if (pings.Count < 2) return (0, true);

        double measured = 0;
        double estimated = 0;
        var hasGap = false;

        for (var i = 1; i < pings.Count; i++)
        {
            var step = GeoMath.DistanceM(pings[i - 1].Point, pings[i].Point);
            var elapsed = pings[i].EffectiveAt - pings[i - 1].EffectiveAt;

            if (elapsed >= config.GapThreshold)
            {
                hasGap = true;
                estimated += step * config.RoadDistanceFactor;
                continue;
            }

            if (step >= config.JitterThresholdM) measured += step;
        }

        return ((long)Math.Round(measured + estimated), hasGap);
    }

    private static (JourneyState State, Guid? PlaceId) StateAfter(
        JourneyEvent evt, JourneyState state, Guid? placeId, JourneyInput input) => evt.Type switch
        {
            JourneyEventType.ArriveHome => (JourneyState.AtHome, evt.PlaceId ?? input.Home.Id),
            JourneyEventType.DepartHome => (JourneyState.OutboundTransit, null),
            JourneyEventType.ArriveCustomer => (JourneyState.AtCustomer, evt.PlaceId),
            JourneyEventType.DepartCustomer => (JourneyState.InterTransit, null),
            JourneyEventType.StartReturn => (JourneyState.ReturnTransit, null),
            JourneyEventType.OvernightStopStart => (JourneyState.OvernightStop, null),
            JourneyEventType.OvernightStopEnd => (
                state == JourneyState.OvernightStop ? JourneyState.OutboundTransit : state, placeId),
            JourneyEventType.PauseStart => (JourneyState.Paused, placeId),
            _ => (state, placeId)
        };

    private static SegmentType SegmentTypeFor(JourneyState state) => state switch
    {
        JourneyState.AtHome => SegmentType.AtHome,
        JourneyState.AtCustomer => SegmentType.AtCustomer,
        JourneyState.OutboundTransit => SegmentType.OutboundTravel,
        JourneyState.InterTransit => SegmentType.InterTravel,
        JourneyState.ReturnTransit => SegmentType.ReturnTravel,
        JourneyState.OvernightStop => SegmentType.OvernightStop,
        JourneyState.Paused => SegmentType.Paused,
        _ => SegmentType.Gap
    };

    private static bool IsTravel(SegmentType type)
        => type is SegmentType.OutboundTravel or SegmentType.InterTravel or SegmentType.ReturnTravel;

    // ------------------------------------------------------------------ lookups

    private static EventStatus StatusFor(double confidence, EngineConfig config)
        => confidence >= config.AutoConfirmConfidence ? EventStatus.Detected : EventStatus.NeedsReview;

    private static Place? FindPlace(JourneyInput input, Guid placeId)
        => input.Home.Id == placeId ? input.Home : input.Sites.FirstOrDefault(s => s.Id == placeId);

    private static Place? MatchPlace(JourneyInput input, GeoPoint point)
    {
        if (GeoMath.DistanceM(point, input.Home.Point) <= input.Home.RadiusM) return input.Home;

        return input.Sites
            .Where(s => GeoMath.DistanceM(point, s.Point) <= s.RadiusM)
            .OrderBy(s => GeoMath.DistanceM(point, s.Point))
            .ThenBy(s => s.Id)
            .FirstOrDefault();
    }

    private static GeofenceEvent? FindGeofenceEvent(
        JourneyInput input, Guid placeId, GeofenceTransition transition,
        DateTimeOffset near, TimeSpan tolerance)
        => input.GeofenceEvents
            .Where(e => e.PlaceId == placeId
                        && !e.IsMock
                        && (e.Transition == transition || e.Transition == GeofenceTransition.Dwell)
                        && (e.OccurredAt - near).Duration() <= tolerance)
            .OrderBy(e => (e.OccurredAt - near).Duration())
            .ThenBy(e => e.Id)
            .FirstOrDefault();

    private static StayDetection? FindStay(
        JourneyInput input, Place place, DateTimeOffset near, EngineConfig config)
        => input.Stays
            .Where(s => GeoMath.DistanceM(s.Point, place.Point) <= place.RadiusM
                        && (s.ArrivedAt - near).Duration() <= config.GapThreshold)
            .OrderBy(s => (s.ArrivedAt - near).Duration())
            .ThenBy(s => s.Id)
            .FirstOrDefault();
}
