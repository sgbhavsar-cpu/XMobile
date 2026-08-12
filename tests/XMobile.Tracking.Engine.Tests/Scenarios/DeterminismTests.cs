using XMobile.Tracking.Engine.Geo;
using XMobile.Tracking.Engine.Models;
using XMobile.Tracking.Engine.Tests.Support;
using Xunit;

namespace XMobile.Tracking.Engine.Tests.Scenarios;

/// <summary>
/// The property the whole late-evidence design rests on: inference is a pure function, so a
/// rebuild over the same window reproduces the same journey, and evidence arriving hours late
/// simply produces a better one.
/// </summary>
public class DeterminismTests
{
    private static readonly TimeSpan Ist = TimeSpan.FromHours(5.5);
    private static DateTimeOffset At(int hour, int minute = 0) => new(2026, 8, 11, hour, minute, 0, Ist);

    private static readonly Guid SiteId = new("66666666-6666-6666-6666-666666666666");

    private static JourneyInput BuildDay(bool includeLateEvidence)
    {
        var home = Places.Home();
        var site = Places.Site(SiteId.ToString(), Places.PuneCustomer, "Main");

        var trace = new TraceBuilder()
            .StayAt(Places.PuneHome, At(7), TimeSpan.FromHours(1))
            .TravelFromTo(Places.PuneHome, Places.PuneCustomer, At(8), TimeSpan.FromMinutes(20),
                TimeSpan.FromMinutes(2));

        if (includeLateEvidence)
        {
            // The batch that was stuck in the device's queue all afternoon.
            trace.StayAt(Places.PuneCustomer, At(8, 20), TimeSpan.FromMinutes(50))
                 .TravelFromTo(Places.PuneCustomer, Places.PuneHome, At(9, 15),
                     TimeSpan.FromMinutes(20), TimeSpan.FromMinutes(2))
                 .StayAt(Places.PuneHome, At(9, 35), TimeSpan.FromHours(1));
        }

        return trace.Build(home, [site], At(6), At(12));
    }

    [Fact]
    public void SameEvidenceProducesAnIdenticalJourney()
    {
        var input = BuildDay(includeLateEvidence: true);

        var first = new JourneyEngine().Infer(input);
        var second = new JourneyEngine().Infer(input);

        Assert.Equal(
            first.Events.Select(e => (e.Type, e.OccurredAt, e.PlaceId, e.Confidence)),
            second.Events.Select(e => (e.Type, e.OccurredAt, e.PlaceId, e.Confidence)));

        Assert.Equal(
            first.Segments.Select(s => (s.Type, s.StartedAt, s.DistanceM, s.TravelMode)),
            second.Segments.Select(s => (s.Type, s.StartedAt, s.DistanceM, s.TravelMode)));

        Assert.Equal(first.EndState, second.EndState);
    }

    [Fact]
    public void ShufflingTheEvidenceOrderChangesNothing()
    {
        // Batches arrive out of order over a poor link. Ordering is the engine's job, not the
        // network's.
        var input = BuildDay(includeLateEvidence: true);
        var reversed = input with { Pings = input.Pings.Reverse().ToList() };

        var straight = new JourneyEngine().Infer(input);
        var shuffled = new JourneyEngine().Infer(reversed);

        Assert.Equal(
            straight.Events.Select(e => (e.Type, e.OccurredAt)),
            shuffled.Events.Select(e => (e.Type, e.OccurredAt)));
    }

    [Fact]
    public void LateEvidenceCompletesADayThatLookedUnfinished()
    {
        // Before the queued batch arrives the rep appears to be still travelling; afterwards the
        // same window resolves to a finished day. Both are correct given what was known.
        var partial = new JourneyEngine().Infer(BuildDay(includeLateEvidence: false));
        var complete = new JourneyEngine().Infer(BuildDay(includeLateEvidence: true));

        Assert.DoesNotContain(partial.Events, e => e.Type == JourneyEventType.ArriveCustomer);
        Assert.Contains(complete.Events, e => e.Type == JourneyEventType.ArriveCustomer);
        Assert.Contains(complete.Events, e => e.Type == JourneyEventType.ArriveHome);
        Assert.Equal(JourneyState.AtHome, complete.EndState);
    }

    [Fact]
    public void EmptyWindowIsReportedAsAGapRatherThanAnEmptyDay()
    {
        // No evidence and a quiet day look identical unless the engine says which it was.
        var home = Places.Home();
        var site = Places.Site(SiteId.ToString(), Places.PuneCustomer);

        var result = new JourneyEngine().Infer(
            new TraceBuilder().Build(home, [site], At(6), At(20)));

        Assert.Empty(result.Events);
        Assert.Contains(result.Anomalies, a => a.Type == AnomalyTypes.GapUnexplained);
    }
}

public class GeoMathTests
{
    [Fact]
    public void DistanceMatchesKnownSeparation()
    {
        // Pune → Nagpur, straight line, ≈620 km.
        var distance = GeoMath.DistanceM(Places.PuneHome, Places.NagpurYard);
        Assert.InRange(distance, 600_000, 640_000);
    }

    [Fact]
    public void JitterDoesNotAccumulateIntoFictionalTravel()
    {
        // A stationary phone reporting ±8 m noise for an hour must not report a walk.
        var points = new List<GeoPoint>();
        for (var i = 0; i < 60; i++)
            points.Add(new GeoPoint(18.5204 + (i % 2) * 0.00007, 73.8567 - (i % 3) * 0.00005));

        Assert.Equal(0, GeoMath.PathLengthM(points, jitterThresholdM: 15));
    }

    [Fact]
    public void RealMovementIsStillMeasured()
    {
        var points = new List<GeoPoint> { new(18.5204, 73.8567), new(18.5304, 73.8567) };
        Assert.InRange(GeoMath.PathLengthM(points, jitterThresholdM: 15), 1_050, 1_150);
    }

    [Fact]
    public void SimplificationKeepsTheShapeAndDropsTheFiller()
    {
        var points = new List<GeoPoint>();
        for (var i = 0; i <= 100; i++)
            points.Add(new GeoPoint(18.52 + i * 0.0005, 73.85));      // a straight line

        var simplified = GeoMath.Simplify(points, toleranceM: 20);

        Assert.Equal(2, simplified.Count);                            // endpoints only
        Assert.Equal(points[0], simplified[0]);
        Assert.Equal(points[^1], simplified[^1]);
    }

    [Fact]
    public void SimplificationPreservesACorner()
    {
        var points = new List<GeoPoint>
        {
            new(18.52, 73.85), new(18.53, 73.85), new(18.54, 73.85),   // north
            new(18.54, 73.86), new(18.54, 73.87)                       // then east
        };

        var simplified = GeoMath.Simplify(points, toleranceM: 20);

        Assert.Contains(new GeoPoint(18.54, 73.85), simplified);       // the corner survives
    }

    [Theory]
    [InlineData(0, 0, 0)]
    [InlineData(1_000, 60, 60)]
    [InlineData(500, 3_600, 0.5)]
    public void ImpliedSpeedIsComputedInKmph(double metres, double seconds, double expectedKmph)
    {
        var origin = new GeoPoint(18.5204, 73.8567);
        var start = new DateTimeOffset(2026, 8, 11, 9, 0, 0, TimeSpan.Zero);

        // Move north by the requested distance: 1° latitude ≈ 111,132 m.
        var destination = new GeoPoint(origin.Lat + metres / 111_132.0, origin.Lon);

        var speed = GeoMath.ImpliedSpeedKmph(origin, start, destination, start.AddSeconds(seconds));

        Assert.InRange(speed, expectedKmph * 0.97, expectedKmph * 1.03 + 0.01);
    }
}
