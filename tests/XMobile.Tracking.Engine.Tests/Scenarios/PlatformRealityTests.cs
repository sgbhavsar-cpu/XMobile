using XMobile.Tracking.Engine.Models;
using XMobile.Tracking.Engine.Tests.Support;
using Xunit;

namespace XMobile.Tracking.Engine.Tests.Scenarios;

/// <summary>
/// The cases that break designs assuming an unbroken breadcrumb trail: iOS suppressing fixes,
/// Android OEMs killing the service, dead batteries, and overlapping geofences in a dense market.
/// On a BYOD fleet with no MDM these are the normal case, not the exception.
/// </summary>
public class PlatformRealityTests
{
    private static readonly TimeSpan Ist = TimeSpan.FromHours(5.5);
    private static DateTimeOffset At(int hour, int minute = 0) => new(2026, 8, 11, hour, minute, 0, Ist);

    private static readonly Guid YardId = new("66666666-6666-6666-6666-666666666666");

    [Fact]
    public void BackEstimatesDepartureWhenTheFirstFixOfTheDayIsAlreadyFarFromHome()
    {
        // Classic iOS: the app is suspended at home and only wakes up once the rep is well away.
        // Leaving the day with no departure at all is worse than an estimate — but the estimate
        // must be flagged, never presented as an observation.
        var home = Places.Home();
        var yard = Places.Site(YardId.ToString(), Places.NagpurYard);

        var input = new TraceBuilder()
            .StayAt(Places.MumbaiOffice, At(9, 30), TimeSpan.FromMinutes(20))
            .Build(home, [yard], At(6), At(12));

        var result = new JourneyEngine().Infer(input);
        var departure = result.Events.First(e => e.Type == JourneyEventType.DepartHome);

        Assert.True(departure.IsEstimated);
        Assert.Equal(EventStatus.NeedsReview, departure.Status);
        Assert.Equal(DetectionMethod.InferredFromGap, departure.Method);
        Assert.True(departure.OccurredAt < At(9, 30), "estimated departure must precede the first fix");
    }

    [Fact]
    public void DetectsArrivalFromAGeofenceCrossingAloneWhenNoFixesSurvive()
    {
        // iOS often reports the region crossing while suppressing the fixes around it. Without
        // this path the arrival simply would not exist on half the fleet.
        var home = Places.Home();
        var yard = Places.Site(YardId.ToString(), Places.PuneCustomer, "Main Yard");

        var input = new TraceBuilder()
            .StayAt(Places.PuneHome, At(7), TimeSpan.FromHours(1))
            .Geofence(yard.Id, PlaceKind.CustomerSite, GeofenceTransition.Enter, At(10, 15),
                Places.PuneCustomer)
            .Stay(Places.PuneCustomer, At(10, 15), At(11, 30))
            .Build(home, [yard], At(6), At(13));

        var result = new JourneyEngine().Infer(input);
        var arrival = result.Events.First(e => e.Type == JourneyEventType.ArriveCustomer);

        Assert.Equal(YardId, arrival.PlaceId);
        Assert.Equal(DetectionMethod.Geofence, arrival.Method);
        Assert.Equal(At(10, 15), arrival.OccurredAt);
    }

    [Fact]
    public void PrefersThePlannedSiteWhenTwoGeofencesOverlap()
    {
        // In a dense market two customers genuinely sit inside each other's radius. Picking the
        // nearer centre alone would attribute the visit to the neighbour about half the time.
        var home = Places.Home();
        var planned = Places.Site("66666666-6666-6666-6666-666666666666", Places.PuneCustomer, "Planned");
        var neighbour = Places.Site("66666666-6666-6666-6666-666666666667",
            Places.PuneCustomerNeighbour, "Neighbour");

        var tour = new TourContext
        {
            TourId = Guid.NewGuid(),
            PlannedStartDate = new DateOnly(2026, 8, 11),
            PlannedEndDate = new DateOnly(2026, 8, 11),
            AllPlannedSiteIds = [planned.Id],
            RemainingPlannedSiteIds = [planned.Id]
        };

        // Stand slightly closer to the neighbour's centre than the planned site's.
        var standingPoint = new GeoPoint(
            (Places.PuneCustomer.Lat + Places.PuneCustomerNeighbour.Lat * 3) / 4,
            (Places.PuneCustomer.Lon + Places.PuneCustomerNeighbour.Lon * 3) / 4);

        var input = new TraceBuilder()
            .StayAt(Places.PuneHome, At(7), TimeSpan.FromHours(1))
            .TravelFromTo(Places.PuneHome, standingPoint, At(9), TimeSpan.FromMinutes(20),
                TimeSpan.FromMinutes(2))
            .StayAt(standingPoint, At(9, 20), TimeSpan.FromMinutes(45))
            .Build(home, [planned, neighbour], At(6), At(13), tour: tour);

        var arrival = new JourneyEngine().Infer(input).Events
            .First(e => e.Type == JourneyEventType.ArriveCustomer);

        Assert.Equal(planned.Id, arrival.PlaceId);
    }

    [Fact]
    public void ImpreciseFixesCannotOnTheirOwnTriggerATransition()
    {
        // A 800 m accuracy fix "inside" a 150 m fence is not evidence of arrival.
        var home = Places.Home();
        var yard = Places.Site(YardId.ToString(), Places.PuneCustomer);

        var input = new TraceBuilder()
            .StayAt(Places.PuneHome, At(7), TimeSpan.FromHours(1))
            .ImpreciseePing(Places.PuneCustomer, At(9, 0))
            .ImpreciseePing(Places.PuneCustomer, At(9, 30))
            .ImpreciseePing(Places.PuneCustomer, At(10, 0))
            .Build(home, [yard], At(6), At(11));

        var result = new JourneyEngine().Infer(input);

        Assert.DoesNotContain(result.Events, e => e.Type == JourneyEventType.ArriveCustomer);
    }

    [Fact]
    public void GapWithQueuedDataIsReportedAsNoSignalNotAsATrackingFailure()
    {
        // The data existed on the device the whole time; only the upload failed. Reporting that
        // as a tracking failure would put reps in front of managers for having driven through
        // a valley.
        var home = Places.Home();
        var yard = Places.Site(YardId.ToString(), Places.NagpurYard);

        var input = new TraceBuilder()
            .StayAt(Places.PuneHome, At(6), TimeSpan.FromMinutes(30))
            .StayAt(Places.MumbaiOffice, At(11), TimeSpan.FromMinutes(30))
            .Health(At(8), queuedPings: 320, serviceRunning: true, locationEnabled: true)
            .Build(home, [yard], At(6), At(12));

        var anomalies = new JourneyEngine().Infer(input).Anomalies;

        Assert.Contains(anomalies, a => a.Type == AnomalyTypes.NoSignal);
        Assert.DoesNotContain(anomalies, a => a.Type == AnomalyTypes.GapUnexplained);
    }

    [Theory]
    [InlineData("PERMISSION", AnomalyTypes.PermissionRevoked, AnomalySeverity.High)]
    [InlineData("LOCATION_OFF", AnomalyTypes.LocationOff, AnomalySeverity.High)]
    [InlineData("APP_KILLED", AnomalyTypes.AppKilled, AnomalySeverity.Medium)]
    [InlineData("REBOOT", AnomalyTypes.DeviceOff, AnomalySeverity.Low)]
    [InlineData("NONE", AnomalyTypes.GapUnexplained, AnomalySeverity.High)]
    public void GapsAreClassifiedByCauseSoTheyAreExplainableRatherThanMysterious(
        string cause, string expectedType, AnomalySeverity expectedSeverity)
    {
        var home = Places.Home();
        var yard = Places.Site(YardId.ToString(), Places.NagpurYard);

        var trace = new TraceBuilder()
            .StayAt(Places.PuneHome, At(6), TimeSpan.FromMinutes(30))
            .StayAt(Places.MumbaiOffice, At(11), TimeSpan.FromMinutes(30));

        _ = cause switch
        {
            "PERMISSION" => trace.Health(At(8), permission: "DENIED"),
            "LOCATION_OFF" => trace.Health(At(8), locationEnabled: false),
            "APP_KILLED" => trace.Health(At(8), serviceRunning: false),
            "REBOOT" => trace.Health(At(8), rebooted: true),
            _ => trace
        };

        var anomalies = new JourneyEngine().Infer(trace.Build(home, [yard], At(6), At(12))).Anomalies;
        var gap = anomalies.First(a => a.Type == expectedType);

        Assert.Equal(expectedSeverity, gap.Severity);
    }

    [Fact]
    public void DeclaredPauseIsNotReportedAsAnUnexplainedGap()
    {
        // A pause is a logged decision, not a failure. It still surfaces as a low-severity
        // exception so a manager can see it — the system makes it visible, it does not block it.
        var home = Places.Home();
        var yard = Places.Site(YardId.ToString(), Places.NagpurYard);

        var input = new TraceBuilder()
            .StayAt(Places.PuneHome, At(6), TimeSpan.FromMinutes(30))
            .StayAt(Places.PuneHome, At(11), TimeSpan.FromMinutes(30))
            .Pause(At(6, 35), At(10, 55), "PRIVATE_TRIP")
            .Build(home, [yard], At(6), At(12));

        var anomalies = new JourneyEngine().Infer(input).Anomalies;

        Assert.DoesNotContain(anomalies, a => a.Type == AnomalyTypes.GapUnexplained);
        Assert.Contains(anomalies, a => a.Type == AnomalyTypes.LongPause && a.Severity == AnomalySeverity.Low);
    }

    [Fact]
    public void ReconstructsDistanceAcrossAGapAndMarksItEstimated()
    {
        var home = Places.Home();
        var yard = Places.Site(YardId.ToString(), Places.NagpurYard);

        var input = new TraceBuilder()
            .StayAt(Places.PuneHome, At(6), TimeSpan.FromMinutes(30))
            .TravelFromTo(Places.PuneHome, Places.PuneCustomer, At(6, 35), TimeSpan.FromMinutes(20),
                TimeSpan.FromMinutes(2))
            .StayAt(Places.MumbaiOffice, At(11), TimeSpan.FromMinutes(30))
            .Build(home, [yard], At(6), At(12));

        var result = new JourneyEngine().Infer(input);
        var travel = result.Segments.Where(s => s.Type == SegmentType.OutboundTravel).ToList();

        Assert.NotEmpty(travel);
        Assert.Contains(travel, s => s.IsEstimated);
        Assert.True(result.EstimatedDistanceM > 0,
            "gap-spanning distance must be attributed and flagged, never silently claimed");
    }
}
