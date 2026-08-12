using XMobile.Tracking.Engine.Geo;
using XMobile.Tracking.Engine.Models;

namespace XMobile.Tracking.Engine.Detection;

/// <summary>
/// Scores whether a transit leg is the journey home.
///
/// This is the genuinely ambiguous detection in the whole engine: for the first few
/// kilometres, "heading home" and "heading to the next customer" are indistinguishable.
/// Rather than guess, the scorer combines independent signals and lets the caller record a
/// low-scoring return as provisional, to be reclassified if the rep turns up at a customer.
/// </summary>
public sealed class ReturnLegScorer(EngineConfig config)
{
    public sealed record Score(double Value, Dictionary<string, object> Evidence)
    {
        public bool IsConfident(EngineConfig config) => Value >= config.AutoConfirmConfidence;
    }

    public Score Evaluate(
        IReadOnlyList<Ping> transitPings,
        Place home,
        IReadOnlyList<Place> remainingPlannedSites,
        TourContext? tour,
        DateOnly localDate)
    {
        var evidence = new Dictionary<string, object>();
        var score = 0.0;

        // 1. Nothing left to visit — the strongest single signal.
        if (remainingPlannedSites.Count == 0)
        {
            score += config.ReturnScoreNoRemainingVisits;
            evidence["no_remaining_visits"] = config.ReturnScoreNoRemainingVisits;
        }

        if (transitPings.Count >= config.ReturnMinConsecutiveFixes)
        {
            // 2. Distance to home closing consistently.
            var distances = transitPings.Select(p => GeoMath.DistanceM(p.Point, home.Point)).ToList();
            var first = distances[0];
            var last = distances[^1];

            var closedFraction = first > 0 ? (first - last) / first : 0;
            var monotonic = IsMostlyDecreasing(distances);

            if (closedFraction >= config.ReturnApproachFraction && monotonic)
            {
                score += config.ReturnScoreApproachingHome;
                evidence["approaching_home"] = config.ReturnScoreApproachingHome;
                evidence["closed_fraction"] = Math.Round(closedFraction, 3);
            }

            // 3. Moving away from every site still on the plan.
            if (remainingPlannedSites.Count > 0 && IsLeavingAllSites(transitPings, remainingPlannedSites))
            {
                score += config.ReturnScoreLeavingAllSites;
                evidence["leaving_all_planned_sites"] = config.ReturnScoreLeavingAllSites;
            }
        }

        // 4. Last planned day of the tour.
        if (tour is not null && localDate >= tour.PlannedEndDate)
        {
            score += config.ReturnScoreLastTourDay;
            evidence["last_tour_day"] = config.ReturnScoreLastTourDay;
        }

        var final = Math.Clamp(score, 0, 1);
        evidence["score"] = Math.Round(final, 3);

        return new Score(final, evidence);
    }

    /// <summary>
    /// Tolerates a minority of increasing steps: roads curve, and a strict monotonic test
    /// fails on perfectly ordinary journeys.
    /// </summary>
    private static bool IsMostlyDecreasing(IReadOnlyList<double> distances)
    {
        if (distances.Count < 2) return false;

        var decreasing = 0;
        for (var i = 1; i < distances.Count; i++)
            if (distances[i] < distances[i - 1]) decreasing++;

        return decreasing >= (distances.Count - 1) * 0.6;
    }

    private static bool IsLeavingAllSites(IReadOnlyList<Ping> pings, IReadOnlyList<Place> sites)
        => sites.All(site =>
        {
            var start = GeoMath.DistanceM(pings[0].Point, site.Point);
            var end = GeoMath.DistanceM(pings[^1].Point, site.Point);
            return end > start;
        });
}
