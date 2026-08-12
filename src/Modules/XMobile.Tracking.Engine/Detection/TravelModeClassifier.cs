using XMobile.Tracking.Engine.Geo;
using XMobile.Tracking.Engine.Models;

namespace XMobile.Tracking.Engine.Detection;

/// <summary>
/// Infers how the rep travelled, from speed distribution, path straightness and activity
/// samples. Mode matters because rail kilometres must not be reimbursed as car kilometres.
/// </summary>
public static class TravelModeClassifier
{
    public sealed record Classification(TravelMode Mode, double Confidence, string Reason);

    public static Classification Classify(
        IReadOnlyList<Ping> pings, long distanceM, TimeSpan duration, EngineConfig config)
    {
        if (pings.Count < 2 || duration <= TimeSpan.Zero)
            return new Classification(TravelMode.Unknown, 0, "insufficient-evidence");

        var speedsKmph = SpeedSamples(pings);
        if (speedsKmph.Count == 0)
            return new Classification(TravelMode.Unknown, 0, "no-speed-samples");

        var median = Percentile(speedsKmph, 0.5);
        var p95 = Percentile(speedsKmph, 0.95);
        var straightness = Straightness(pings, distanceM);
        var dominantActivity = DominantActivity(pings);

        // Air: either an implausible ground speed, or a long jump across a gap.
        if (p95 > config.AirPlausibleSpeedKmph)
            return new Classification(TravelMode.Air, 0.8, $"p95={p95:F0}kmph");

        // Rail: fast, sustained and very straight, with few genuine stops.
        if (median > 60 && straightness > 0.85)
            return new Classification(TravelMode.Rail, 0.75, $"median={median:F0}kmph straightness={straightness:F2}");

        // Long-distance rail is slower than people expect: an overnight train covering 600 km
        // in eleven hours averages 55 km/h, which speed alone cannot separate from a car.
        // Straightness can: Indian road routes run 1.2–1.3× the straight-line distance, so a
        // near-straight track over hundreds of kilometres is a railway line, not a highway.
        // Confidence stays moderate and the rep can override — this is a well-founded guess,
        // not a certainty, and mileage claims depend on it.
        if (distanceM > 200_000 && straightness > 0.90 && median > 45)
            return new Classification(TravelMode.Rail, 0.65,
                $"long-straight distance={distanceM / 1000}km straightness={straightness:F2}");

        if (dominantActivity == ActivityType.InVehicle || median > 25)
        {
            // Bus and car look alike from the phone; separating them reliably needs route data,
            // so we return Car and let the rep correct it rather than guessing confidently.
            var confidence = dominantActivity == ActivityType.InVehicle ? 0.75 : 0.6;
            return new Classification(TravelMode.Car, confidence, $"median={median:F0}kmph activity={dominantActivity}");
        }

        if (dominantActivity == ActivityType.OnBicycle || (median is > 12 and <= 25))
            return new Classification(TravelMode.TwoWheeler, 0.65, $"median={median:F0}kmph activity={dominantActivity}");

        if (dominantActivity is ActivityType.Walking or ActivityType.Running || median <= 8)
            return new Classification(TravelMode.Walk, 0.7, $"median={median:F0}kmph activity={dominantActivity}");

        return new Classification(TravelMode.Unknown, 0.3, $"median={median:F0}kmph");
    }

    /// <summary>Mode for a leg reconstructed across a gap, inferred from the jump alone.</summary>
    public static Classification ClassifyGapJump(double distanceM, TimeSpan duration)
    {
        if (duration <= TimeSpan.Zero) return new Classification(TravelMode.Unknown, 0, "zero-duration");

        var kmph = distanceM / duration.TotalSeconds * 3.6;

        return kmph switch
        {
            > 250 => new Classification(TravelMode.Air, 0.6, $"implied={kmph:F0}kmph"),
            > 70 => new Classification(TravelMode.Rail, 0.45, $"implied={kmph:F0}kmph"),
            > 20 => new Classification(TravelMode.Car, 0.4, $"implied={kmph:F0}kmph"),
            _ => new Classification(TravelMode.Unknown, 0.2, $"implied={kmph:F0}kmph")
        };
    }

    private static List<double> SpeedSamples(IReadOnlyList<Ping> pings)
    {
        var speeds = new List<double>();

        for (var i = 1; i < pings.Count; i++)
        {
            // Prefer the OS-reported speed; fall back to implied speed between fixes.
            if (pings[i].SpeedMps is { } mps and >= 0)
            {
                speeds.Add(mps * 3.6);
                continue;
            }

            var implied = GeoMath.ImpliedSpeedKmph(
                pings[i - 1].Point, pings[i - 1].EffectiveAt, pings[i].Point, pings[i].EffectiveAt);

            if (implied > 0) speeds.Add(implied);
        }

        return speeds;
    }

    /// <summary>Straight-line distance over travelled distance. Rail and air approach 1.0.</summary>
    private static double Straightness(IReadOnlyList<Ping> pings, long distanceM)
    {
        if (distanceM <= 0) return 0;
        var straight = GeoMath.DistanceM(pings[0].Point, pings[^1].Point);
        return Math.Min(1.0, straight / distanceM);
    }

    private static ActivityType DominantActivity(IReadOnlyList<Ping> pings)
    {
        var counts = pings
            .Where(p => p.Activity != ActivityType.Unknown)
            .GroupBy(p => p.Activity)
            .Select(g => (Activity: g.Key, Count: g.Count()))
            .OrderByDescending(x => x.Count)
            .ThenBy(x => x.Activity)          // deterministic tie-break
            .ToList();

        return counts.Count == 0 ? ActivityType.Unknown : counts[0].Activity;
    }

    private static double Percentile(List<double> values, double fraction)
    {
        var sorted = values.OrderBy(v => v).ToList();
        if (sorted.Count == 0) return 0;

        var index = (int)Math.Clamp(Math.Round(fraction * (sorted.Count - 1)), 0, sorted.Count - 1);
        return sorted[index];
    }
}
