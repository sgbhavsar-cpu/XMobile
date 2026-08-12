using XMobile.Tracking.Engine.Geo;
using XMobile.Tracking.Engine.Models;

namespace XMobile.Tracking.Engine.Detection;

/// <summary>
/// Finds gaps and tamper signals. Everything here produces a flag for a human, never a block:
/// on a BYOD fleet with no MDM, false positives are certain, and refusing a rep in the field
/// costs a selling day.
/// </summary>
public sealed class AnomalyDetector(EngineConfig config)
{
    public List<Anomaly> Detect(JourneyInput input, IReadOnlyList<Ping> orderedPings)
    {
        var anomalies = new List<Anomaly>();

        anomalies.AddRange(DetectMockLocation(input, orderedPings));
        anomalies.AddRange(DetectTeleports(input, orderedPings));
        anomalies.AddRange(DetectClockSkew(input, orderedPings));
        anomalies.AddRange(DetectGaps(input, orderedPings));
        anomalies.AddRange(DetectLongPauses(input));

        return anomalies
            .OrderBy(a => a.WindowStart)
            .ThenBy(a => a.Type, StringComparer.Ordinal)
            .ToList();
    }

    private IEnumerable<Anomaly> DetectMockLocation(JourneyInput input, IReadOnlyList<Ping> pings)
    {
        var mocked = pings.Where(p => p.IsMock).ToList();
        if (mocked.Count == 0) yield break;

        yield return new Anomaly
        {
            Type = AnomalyTypes.MockLocation,
            Severity = AnomalySeverity.Critical,
            WindowStart = mocked[0].EffectiveAt,
            WindowEnd = mocked[^1].EffectiveAt,
            LocalDate = LocalDateOf(mocked[0].EffectiveAt, input.LocalOffset),
            Details = new Dictionary<string, object>
            {
                ["ping_count"] = mocked.Count,
                ["first_at"] = mocked[0].EffectiveAt,
                ["last_at"] = mocked[^1].EffectiveAt
            }
        };
    }

    private IEnumerable<Anomaly> DetectTeleports(JourneyInput input, IReadOnlyList<Ping> pings)
    {
        for (var i = 1; i < pings.Count; i++)
        {
            var previous = pings[i - 1];
            var current = pings[i];

            var kmph = GeoMath.ImpliedSpeedKmph(
                previous.Point, previous.EffectiveAt, current.Point, current.EffectiveAt);

            if (kmph < config.AirPlausibleSpeedKmph) continue;

            var elapsed = current.EffectiveAt - previous.EffectiveAt;

            // A fast jump across a long gap is probably a flight, not a teleport. Only flag
            // the physically impossible, or the fast jump with no gap to explain it.
            var isImpossible = kmph >= config.TeleportSpeedKmph;
            var isUnexplained = elapsed < config.GapThreshold;

            if (!isImpossible && !isUnexplained) continue;

            yield return new Anomaly
            {
                Type = AnomalyTypes.Teleport,
                Severity = isImpossible ? AnomalySeverity.Critical : AnomalySeverity.Medium,
                WindowStart = previous.EffectiveAt,
                WindowEnd = current.EffectiveAt,
                LocalDate = LocalDateOf(current.EffectiveAt, input.LocalOffset),
                Details = new Dictionary<string, object>
                {
                    ["implied_kmph"] = Math.Round(kmph),
                    ["distance_m"] = Math.Round(GeoMath.DistanceM(previous.Point, current.Point)),
                    ["elapsed_s"] = Math.Round(elapsed.TotalSeconds)
                }
            };
        }
    }

    private IEnumerable<Anomaly> DetectClockSkew(JourneyInput input, IReadOnlyList<Ping> pings)
    {
        var skewed = pings
            .Where(p => p.CorrectedAt is not null
                        && (p.CorrectedAt.Value - p.RecordedAt).Duration() > config.ClockSkewTolerance)
            .ToList();

        if (skewed.Count == 0) yield break;

        var worst = skewed.Max(p => (p.CorrectedAt!.Value - p.RecordedAt).Duration());

        yield return new Anomaly
        {
            Type = AnomalyTypes.ClockSkew,
            Severity = AnomalySeverity.Medium,
            WindowStart = skewed[0].EffectiveAt,
            WindowEnd = skewed[^1].EffectiveAt,
            LocalDate = LocalDateOf(skewed[0].EffectiveAt, input.LocalOffset),
            Details = new Dictionary<string, object>
            {
                ["max_skew_s"] = Math.Round(worst.TotalSeconds),
                ["ping_count"] = skewed.Count
            }
        };
    }

    /// <summary>
    /// Gaps are the normal case on iOS and on battery-optimised Android, not the exception.
    /// Classifying the cause is what turns "we lost him for two hours" into an explainable fact.
    /// </summary>
    private IEnumerable<Anomaly> DetectGaps(JourneyInput input, IReadOnlyList<Ping> pings)
    {
        if (pings.Count == 0)
        {
            yield return new Anomaly
            {
                Type = AnomalyTypes.GapUnexplained,
                Severity = AnomalySeverity.High,
                WindowStart = input.WindowFrom,
                WindowEnd = input.WindowTo,
                LocalDate = LocalDateOf(input.WindowFrom, input.LocalOffset),
                Details = new Dictionary<string, object> { ["reason"] = "no-evidence-in-window" }
            };
            yield break;
        }

        for (var i = 1; i < pings.Count; i++)
        {
            var from = pings[i - 1].EffectiveAt;
            var to = pings[i].EffectiveAt;
            if (to - from < config.GapThreshold) continue;

            // A gap the rep declared is not an anomaly; it is a logged decision.
            //
            // Overlap, not containment: a rep taps pause a few minutes after the last fix and
            // resumes a few minutes before the next, so the pause almost never covers the gap's
            // exact edges. Testing the first instant of the gap reports every ordinary pause as
            // an unexplained disappearance — precisely the false accusation this design exists
            // to avoid.
            if (PausedFraction(input.Pauses, from, to) >= 0.8) continue;

            var (type, severity) = ClassifyGap(input, from, to, pings[i - 1], pings[i]);

            yield return new Anomaly
            {
                Type = type,
                Severity = severity,
                WindowStart = from,
                WindowEnd = to,
                LocalDate = LocalDateOf(from, input.LocalOffset),
                Details = new Dictionary<string, object>
                {
                    ["gap_minutes"] = Math.Round((to - from).TotalMinutes),
                    ["distance_m"] = Math.Round(GeoMath.DistanceM(pings[i - 1].Point, pings[i].Point))
                }
            };
        }
    }

    /// <summary>How much of a window the rep had explicitly paused, as a fraction of its length.</summary>
    private static double PausedFraction(
        IReadOnlyList<PauseWindow> pauses, DateTimeOffset from, DateTimeOffset to)
    {
        var window = (to - from).TotalSeconds;
        if (window <= 0) return 0;

        var covered = 0.0;

        foreach (var pause in pauses)
        {
            var start = pause.PausedAt > from ? pause.PausedAt : from;
            var end = (pause.ResumedAt ?? to) < to ? (pause.ResumedAt ?? to) : to;
            if (end > start) covered += (end - start).TotalSeconds;
        }

        return covered / window;
    }

    private (string Type, AnomalySeverity Severity) ClassifyGap(
        JourneyInput input, DateTimeOffset from, DateTimeOffset to, Ping before, Ping after)
    {
        var samples = input.HealthSamples
            .Where(h => h.ReportedAt >= from.AddMinutes(-10) && h.ReportedAt <= to.AddMinutes(10))
            .ToList();

        if (samples.Any(s => s.WasRebooted == true))
            return (AnomalyTypes.DeviceOff, AnomalySeverity.Low);

        if (samples.Any(s => s.LocationEnabled == false))
            return (AnomalyTypes.LocationOff, AnomalySeverity.High);

        if (samples.Any(s => s.PermissionLevel is "DENIED" or "WHEN_IN_USE"))
            return (AnomalyTypes.PermissionRevoked, AnomalySeverity.High);

        if (samples.Any(s => s.ServiceRunning == false))
            return (AnomalyTypes.AppKilled, AnomalySeverity.Medium);

        if (samples.Any(s => s.IsPowerSaving == true))
            return (AnomalyTypes.PowerSave, AnomalySeverity.Medium);

        // Queued pings during the gap means the data existed and could not be uploaded —
        // a connectivity problem, not a tracking failure, and it should not be reported as one.
        if (samples.Any(s => s.QueuedPings > 0))
            return (AnomalyTypes.NoSignal, AnomalySeverity.Low);

        if (before.BatteryPct is <= 15 || after.BatteryPct is <= 15)
            return (AnomalyTypes.LowBatterySampling, AnomalySeverity.Low);

        return (AnomalyTypes.GapUnexplained, AnomalySeverity.High);
    }

    private IEnumerable<Anomaly> DetectLongPauses(JourneyInput input)
    {
        foreach (var pause in input.Pauses)
        {
            var end = pause.ResumedAt ?? input.WindowTo;
            var duration = end - pause.PausedAt;
            if (duration < config.LongPauseThreshold) continue;

            yield return new Anomaly
            {
                Type = AnomalyTypes.LongPause,
                Severity = AnomalySeverity.Low,
                WindowStart = pause.PausedAt,
                WindowEnd = pause.ResumedAt,
                LocalDate = LocalDateOf(pause.PausedAt, input.LocalOffset),
                Details = new Dictionary<string, object>
                {
                    ["reason_code"] = pause.ReasonCode,
                    ["minutes"] = Math.Round(duration.TotalMinutes),
                    ["auto_resumed"] = pause.AutoResumed
                }
            };
        }
    }

    internal static DateOnly LocalDateOf(DateTimeOffset instant, TimeSpan localOffset)
        => DateOnly.FromDateTime(instant.ToOffset(localOffset).DateTime);
}
