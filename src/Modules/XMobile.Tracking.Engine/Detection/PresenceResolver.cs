using XMobile.Tracking.Engine.Geo;
using XMobile.Tracking.Engine.Models;

namespace XMobile.Tracking.Engine.Detection;

/// <summary>A contiguous stretch of time the rep was at one place (or in transit, when Place is null).</summary>
public sealed record PresenceRun
{
    public Place? Place { get; init; }
    public required DateTimeOffset StartedAt { get; init; }
    public required DateTimeOffset EndedAt { get; init; }
    public required List<Ping> Pings { get; init; }

    public TimeSpan Duration => EndedAt - StartedAt;
    public bool IsTransit => Place is null;
}

/// <summary>
/// Turns a stream of fixes into presence runs — the backbone every arrival and departure
/// rule reads from.
/// </summary>
public sealed class PresenceResolver(EngineConfig config)
{
    /// <summary>
    /// Which place, if any, contains this fix. Ties are broken toward sites on today's plan:
    /// in a dense market two geofences genuinely overlap, and the planned one is the better bet.
    /// </summary>
    public Place? ResolvePlace(GeoPoint point, Place home, IReadOnlyList<Place> sites, TourContext? tour)
    {
        if (GeoMath.DistanceM(point, home.Point) <= home.RadiusM) return home;

        Place? best = null;
        var bestDistance = double.MaxValue;
        var bestIsPlanned = false;

        foreach (var site in sites)
        {
            var distance = GeoMath.DistanceM(point, site.Point);
            if (distance > site.RadiusM) continue;

            var isPlanned = tour?.AllPlannedSiteIds.Contains(site.Id) ?? false;

            // A planned site beats an unplanned one even if slightly further away;
            // otherwise nearer wins.
            var wins = best is null
                       || (isPlanned && !bestIsPlanned)
                       || (isPlanned == bestIsPlanned && distance < bestDistance);

            if (!wins) continue;

            best = site;
            bestDistance = distance;
            bestIsPlanned = isPlanned;
        }

        return best;
    }

    /// <summary>
    /// Collapses fixes into runs, then absorbs single-fix flickers into their neighbours.
    /// Without that hysteresis one stray fix at the edge of a fence produces a phantom
    /// departure-and-return pair, and the timeline fills with noise nobody trusts.
    /// </summary>
    public List<PresenceRun> BuildRuns(
        IReadOnlyList<Ping> decisionGradePings, Place home, IReadOnlyList<Place> sites, TourContext? tour)
    {
        var runs = new List<PresenceRun>();
        if (decisionGradePings.Count == 0) return runs;

        var currentPlace = ResolvePlace(decisionGradePings[0].Point, home, sites, tour);
        var currentPings = new List<Ping> { decisionGradePings[0] };

        for (var i = 1; i < decisionGradePings.Count; i++)
        {
            var ping = decisionGradePings[i];
            var place = ResolvePlace(ping.Point, home, sites, tour);

            if (SamePlace(place, currentPlace))
            {
                currentPings.Add(ping);
                continue;
            }

            runs.Add(MakeRun(currentPlace, currentPings));
            currentPlace = place;
            currentPings = [ping];
        }

        runs.Add(MakeRun(currentPlace, currentPings));

        return AbsorbFlickers(runs);
    }

    private static PresenceRun MakeRun(Place? place, List<Ping> pings) => new()
    {
        Place = place,
        StartedAt = pings[0].EffectiveAt,
        EndedAt = pings[^1].EffectiveAt,
        Pings = pings
    };

    private List<PresenceRun> AbsorbFlickers(List<PresenceRun> runs)
    {
        if (runs.Count < 3) return runs;

        var result = new List<PresenceRun>(runs.Count);

        for (var i = 0; i < runs.Count; i++)
        {
            var run = runs[i];

            var isFlicker = i > 0
                            && i < runs.Count - 1
                            && run.Pings.Count == 1
                            && run.Duration < config.MinDwellForArrival
                            && SamePlace(runs[i - 1].Place, runs[i + 1].Place);

            if (!isFlicker) { result.Add(run); continue; }

            // Merge the flicker and the following run into the previous one.
            var previous = result[^1];
            var next = runs[i + 1];

            result[^1] = previous with
            {
                EndedAt = next.EndedAt,
                Pings = [.. previous.Pings, .. run.Pings, .. next.Pings]
            };

            i++;   // the following run has been consumed
        }

        return result;
    }

    private static bool SamePlace(Place? a, Place? b) => a?.Id == b?.Id;
}
