using XMobile.Tracking.Engine.Models;
using XMobile.Tracking.Engine.Tests.Support;
using Xunit;

namespace XMobile.Tracking.Engine.Tests.Scenarios;

/// <summary>
/// The return leg is the genuinely ambiguous detection, and corrections are what keep reps
/// trusting the system. Both are asserted here.
/// </summary>
public class ReturnLegAndCorrectionTests
{
    private static readonly TimeSpan Ist = TimeSpan.FromHours(5.5);
    private static DateTimeOffset At(int hour, int minute = 0) => new(2026, 8, 11, hour, minute, 0, Ist);

    private static readonly Guid FirstSiteId = new("66666666-6666-6666-6666-666666666666");
    private static readonly Guid SecondSiteId = new("66666666-6666-6666-6666-666666666667");

    /// <summary>Two visits: the leg between them must not be mistaken for going home.</summary>
    private static JourneyInput TwoVisitDay(bool secondVisitStillPlanned)
    {
        var home = Places.Home();
        var first = Places.Site(FirstSiteId.ToString(), Places.PuneCustomer, "First");
        var second = Places.Site(SecondSiteId.ToString(), Places.MumbaiOffice, "Second");

        var tour = new TourContext
        {
            TourId = Guid.NewGuid(),
            PlannedStartDate = new DateOnly(2026, 8, 11),
            PlannedEndDate = new DateOnly(2026, 8, 11),
            AllPlannedSiteIds = [FirstSiteId, SecondSiteId],
            RemainingPlannedSiteIds = secondVisitStillPlanned ? [SecondSiteId] : []
        };

        var trace = new TraceBuilder()
            .StayAt(Places.PuneHome, At(7), TimeSpan.FromHours(1))
            .TravelFromTo(Places.PuneHome, Places.PuneCustomer, At(8), TimeSpan.FromMinutes(20),
                TimeSpan.FromMinutes(2))
            .StayAt(Places.PuneCustomer, At(8, 20), TimeSpan.FromMinutes(50))
            .TravelFromTo(Places.PuneCustomer, Places.MumbaiOffice, At(9, 15), TimeSpan.FromHours(3),
                TimeSpan.FromMinutes(10))
            .StayAt(Places.MumbaiOffice, At(12, 15), TimeSpan.FromMinutes(50));

        return trace.Build(home, [first, second], At(6), At(14), tour: tour);
    }

    [Fact]
    public void TravellingToTheNextCustomerIsNotRecordedAsHeadingHome()
    {
        var result = new JourneyEngine().Infer(TwoVisitDay(secondVisitStillPlanned: true));

        Assert.DoesNotContain(result.Events,
            e => e.Type == JourneyEventType.StartReturn && e.Status == EventStatus.Detected);

        Assert.Equal(2, result.Events.Count(e => e.Type == JourneyEventType.ArriveCustomer));
    }

    [Fact]
    public void AProvisionalReturnIsWithdrawnWhenTheRepReachesAnotherCustomer()
    {
        // With nothing left on the plan the engine reasonably suspects a return leg. Arriving at
        // a customer disproves it, and the retraction must be complete rather than left as a
        // contradictory pair of events.
        var result = new JourneyEngine().Infer(TwoVisitDay(secondVisitStillPlanned: false));

        var returns = result.Events.Where(e => e.Type == JourneyEventType.StartReturn).ToList();

        Assert.All(returns, r => Assert.True(r.OccurredAt > At(12),
            "a return leg recorded before the second visit should have been withdrawn"));
    }

    [Fact]
    public void ReturnSegmentsBelowTheConfidenceBarAreMarkedProvisional()
    {
        var home = Places.Home();
        var site = Places.Site(FirstSiteId.ToString(), Places.PuneCustomer, "Only");

        // No tour context: the engine cannot know whether the day is finished, so any homeward
        // leg is a suspicion until the rep actually gets home.
        var input = new TraceBuilder()
            .StayAt(Places.PuneHome, At(7), TimeSpan.FromHours(1))
            .TravelFromTo(Places.PuneHome, Places.PuneCustomer, At(8), TimeSpan.FromMinutes(20),
                TimeSpan.FromMinutes(2))
            .StayAt(Places.PuneCustomer, At(8, 20), TimeSpan.FromMinutes(50))
            .TravelFromTo(Places.PuneCustomer, Places.PuneHome, At(9, 15), TimeSpan.FromMinutes(20),
                TimeSpan.FromMinutes(2))
            .Build(home, [site], At(6), At(10));      // window ends before the rep gets home

        var result = new JourneyEngine().Infer(input);
        var startReturn = result.Events.FirstOrDefault(e => e.Type == JourneyEventType.StartReturn);

        Assert.NotNull(startReturn);
        Assert.Equal(EventStatus.NeedsReview, startReturn!.Status);
        Assert.Contains(result.Segments, s => s.Type == SegmentType.ReturnTravel && s.IsProvisional);
    }

    [Fact]
    public void ManualCorrectionReplacesTheAutoDetectionAndIsNeverOverwritten()
    {
        // If a rep cannot correct a wrong detection they stop trusting the system; if the
        // correction silently replaces the detection, the audit trail is gone. Anchors do the
        // first without the second.
        var home = Places.Home();
        var site = Places.Site(FirstSiteId.ToString(), Places.PuneCustomer, "Main");

        var correctedDeparture = At(8, 42);

        var trace = new TraceBuilder()
            .StayAt(Places.PuneHome, At(7), TimeSpan.FromHours(1) + TimeSpan.FromMinutes(50))
            .TravelFromTo(Places.PuneHome, Places.PuneCustomer, At(8, 50), TimeSpan.FromMinutes(20),
                TimeSpan.FromMinutes(2))
            .StayAt(Places.PuneCustomer, At(9, 10), TimeSpan.FromMinutes(50));

        var baseInput = trace.Build(home, [site], At(6), At(12));

        var withAnchor = baseInput with
        {
            Anchors =
            [
                new JourneyEvent
                {
                    Type = JourneyEventType.DepartHome,
                    OccurredAt = correctedDeparture,
                    LocalDate = new DateOnly(2026, 8, 11),
                    PlaceKind = PlaceKind.Home,
                    PlaceId = home.Id,
                    Method = DetectionMethod.Manual,
                    Confidence = 1.0,
                    Status = EventStatus.Confirmed,
                    IsAnchor = true
                }
            ]
        };

        var result = new JourneyEngine().Infer(withAnchor);
        var departures = result.Events.Where(e => e.Type == JourneyEventType.DepartHome).ToList();

        var departure = Assert.Single(departures);
        Assert.Equal(correctedDeparture, departure.OccurredAt);
        Assert.True(departure.IsAnchor);
        Assert.Equal(1.0, departure.Confidence);
        Assert.Equal(DetectionMethod.Manual, departure.Method);
    }

    [Fact]
    public void AnchorsFarFromAnAutoDetectionDoNotSuppressIt()
    {
        // Suppression is deliberately narrow: an anchor for a different part of the day must not
        // silently delete an unrelated detection.
        var home = Places.Home();
        var site = Places.Site(FirstSiteId.ToString(), Places.PuneCustomer, "Main");

        var baseInput = new TraceBuilder()
            .StayAt(Places.PuneHome, At(7), TimeSpan.FromHours(1))
            .TravelFromTo(Places.PuneHome, Places.PuneCustomer, At(8), TimeSpan.FromMinutes(20),
                TimeSpan.FromMinutes(2))
            .StayAt(Places.PuneCustomer, At(8, 20), TimeSpan.FromMinutes(50))
            .Build(home, [site], At(6), At(12));

        var withDistantAnchor = baseInput with
        {
            Anchors =
            [
                new JourneyEvent
                {
                    Type = JourneyEventType.DepartHome,
                    OccurredAt = At(5, 0),                 // hours away from the real departure
                    LocalDate = new DateOnly(2026, 8, 11),
                    PlaceKind = PlaceKind.Home,
                    PlaceId = home.Id,
                    Method = DetectionMethod.Manual,
                    Confidence = 1.0,
                    Status = EventStatus.Confirmed,
                    IsAnchor = true
                }
            ]
        };

        var departures = new JourneyEngine().Infer(withDistantAnchor).Events
            .Where(e => e.Type == JourneyEventType.DepartHome)
            .ToList();

        Assert.Equal(2, departures.Count);
    }
}
