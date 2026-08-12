using XMobile.Tracking.Engine.Models;
using XMobile.Tracking.Engine.Tests.Support;
using Xunit;

namespace XMobile.Tracking.Engine.Tests.Scenarios;

/// <summary>
/// The ordinary day: leave home, visit a customer, come back. If this is not exactly right,
/// nothing else matters.
/// </summary>
public class SingleDayTests
{
    private static readonly DateTimeOffset Ist = new(2026, 8, 11, 0, 0, 0, TimeSpan.FromHours(5.5));

    private static JourneyInput BuildOrdinaryDay(GeoSource siteGeoSource = GeoSource.FieldCaptured)
    {
        var home = Places.Home();
        var site = Places.Site("66666666-6666-6666-6666-666666666666", Places.PuneCustomer,
            "Main Yard", source: siteGeoSource);

        var depart = Ist.AddHours(9);            // 09:00
        var arrive = Ist.AddHours(9.5);          // 09:30
        var leaveSite = Ist.AddHours(10.5);      // 10:30
        var home2 = Ist.AddHours(11);            // 11:00

        var trace = new TraceBuilder()
            .StayAt(Places.PuneHome, Ist.AddHours(7), TimeSpan.FromHours(2))
            .TravelFromTo(Places.PuneHome, Places.PuneCustomer, depart, TimeSpan.FromMinutes(30),
                TimeSpan.FromMinutes(2))
            .StayAt(Places.PuneCustomer, arrive, TimeSpan.FromHours(1))
            .TravelFromTo(Places.PuneCustomer, Places.PuneHome, leaveSite, TimeSpan.FromMinutes(30),
                TimeSpan.FromMinutes(2))
            .StayAt(Places.PuneHome, home2, TimeSpan.FromHours(1));

        return trace.Build(home, [site], Ist.AddHours(6), Ist.AddHours(13));
    }

    [Fact]
    public void DetectsTheFourTransitionsOfAnOrdinaryDay()
    {
        var result = new JourneyEngine().Infer(BuildOrdinaryDay());

        var types = result.Events.Select(e => e.Type).ToList();

        Assert.Contains(JourneyEventType.DepartHome, types);
        Assert.Contains(JourneyEventType.ArriveCustomer, types);
        Assert.Contains(JourneyEventType.DepartCustomer, types);
        Assert.Contains(JourneyEventType.ArriveHome, types);
        Assert.Equal(JourneyState.AtHome, result.EndState);
    }

    [Fact]
    public void TransitionTimesLandWithinFiveMinutesOfTruth()
    {
        var result = new JourneyEngine().Infer(BuildOrdinaryDay());
        var tolerance = TimeSpan.FromMinutes(5);

        AssertNear(Ist.AddHours(9), Single(result, JourneyEventType.DepartHome).OccurredAt, tolerance);
        AssertNear(Ist.AddHours(9.5), Single(result, JourneyEventType.ArriveCustomer).OccurredAt, tolerance);
        AssertNear(Ist.AddHours(10.5), Single(result, JourneyEventType.DepartCustomer).OccurredAt, tolerance);
        AssertNear(Ist.AddHours(11), Single(result, JourneyEventType.ArriveHome).OccurredAt, tolerance);
    }

    [Fact]
    public void DepartureIsTheLastFixInsideTheFenceNotTheFirstOneOutside()
    {
        // Overstating departure time by the sampling interval is a systematic error that shows
        // up in every travel-time report, so it is asserted explicitly.
        var result = new JourneyEngine().Infer(BuildOrdinaryDay());
        var departure = Single(result, JourneyEventType.DepartHome);

        Assert.True(departure.OccurredAt <= Ist.AddHours(9).AddMinutes(3),
            $"departure at {departure.OccurredAt:HH:mm:ss} should be at or before the first outbound fix");
    }

    [Fact]
    public void ArrivalsAtTrustedSitesAutoConfirm()
    {
        var result = new JourneyEngine().Infer(BuildOrdinaryDay());
        var arrival = Single(result, JourneyEventType.ArriveCustomer);

        Assert.Equal(EventStatus.Detected, arrival.Status);
        Assert.True(arrival.Confidence >= EngineConfig.Default.AutoConfirmConfidence);
    }

    [Fact]
    public void ArrivalsAtMerelyGeocodedSitesAreHeldForReview()
    {
        // A bad geocode must never silently manufacture a visit record.
        var result = new JourneyEngine().Infer(BuildOrdinaryDay(GeoSource.Geocoded));
        var arrival = Single(result, JourneyEventType.ArriveCustomer);

        Assert.Equal(EventStatus.NeedsReview, arrival.Status);
    }

    [Fact]
    public void ProducesTimeAtCustomerAndTravelSegments()
    {
        var result = new JourneyEngine().Infer(BuildOrdinaryDay());

        var atCustomer = result.Segments.Single(s => s.Type == SegmentType.AtCustomer);
        Assert.InRange(atCustomer.DurationSeconds!.Value, 55 * 60, 65 * 60);

        var outbound = result.Segments.Single(s => s.Type == SegmentType.OutboundTravel);
        Assert.InRange(outbound.DistanceM, 1_500, 2_200);       // Pune home → customer ≈ 1.75 km
        Assert.False(outbound.IsEstimated);
    }

    [Fact]
    public void StationaryTimeDoesNotAccumulateDistance()
    {
        // A phone on a desk generates hundreds of metres of fictional travel if every fix is summed.
        var result = new JourneyEngine().Infer(BuildOrdinaryDay());

        Assert.All(result.Segments.Where(s => s.Type is SegmentType.AtHome or SegmentType.AtCustomer),
            s => Assert.Equal(0, s.DistanceM));
    }

    [Fact]
    public void ArrivingHomeConfirmsTheReturnLeg()
    {
        var result = new JourneyEngine().Infer(BuildOrdinaryDay());
        var startReturn = result.Events.SingleOrDefault(e => e.Type == JourneyEventType.StartReturn);

        Assert.NotNull(startReturn);
        Assert.Equal(EventStatus.Detected, startReturn!.Status);
        Assert.True(startReturn.Evidence.ContainsKey("confirmed_by_home_arrival"));
    }

    [Fact]
    public void CleanDayProducesNoAnomalies()
    {
        var result = new JourneyEngine().Infer(BuildOrdinaryDay());
        Assert.Empty(result.Anomalies);
    }

    private static JourneyEvent Single(JourneyResult result, JourneyEventType type)
        => result.Events.Single(e => e.Type == type);

    private static void AssertNear(DateTimeOffset expected, DateTimeOffset actual, TimeSpan tolerance)
        => Assert.True((expected - actual).Duration() <= tolerance,
            $"expected ~{expected:HH:mm:ss}, got {actual:HH:mm:ss} (tolerance {tolerance.TotalMinutes:F0}m)");
}
