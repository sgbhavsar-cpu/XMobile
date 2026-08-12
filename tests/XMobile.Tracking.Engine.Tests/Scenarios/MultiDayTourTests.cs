using XMobile.Tracking.Engine.Models;
using XMobile.Tracking.Engine.Tests.Support;
using Xunit;

namespace XMobile.Tracking.Engine.Tests.Scenarios;

/// <summary>
/// The scenario from docs/02 §5: Pune → Nagpur and back, spanning four calendar days with an
/// overnight rail journey, a hotel stop, and a full day of return travel. This is the case the
/// whole tour model exists for, so it is asserted end to end.
/// </summary>
public class MultiDayTourTests
{
    private static readonly TimeSpan Ist = TimeSpan.FromHours(5.5);

    private static DateTimeOffset At(int day, int hour, int minute = 0)
        => new(2026, 8, day, hour, minute, 0, Ist);

    private static readonly Guid YardId = new("66666666-6666-6666-6666-666666666666");

    private static JourneyInput BuildTour()
    {
        var home = Places.Home();
        var yard = Places.Site(YardId.ToString(), Places.NagpurYard, "Nagpur Yard");

        var tour = new TourContext
        {
            TourId = new Guid("77777777-7777-7777-7777-777777777777"),
            PlannedStartDate = new DateOnly(2026, 8, 10),
            PlannedEndDate = new DateOnly(2026, 8, 12),
            AllPlannedSiteIds = [YardId],
            RemainingPlannedSiteIds = []          // the yard visit is done by inference time
        };

        var trace = new TraceBuilder()
            // Mon: at home, then the overnight train
            .StayAt(Places.PuneHome, At(10, 16, 0), TimeSpan.FromHours(2) + TimeSpan.FromMinutes(40))
            .TravelFromTo(Places.PuneHome, Places.NagpurHotel, At(10, 18, 40), TimeSpan.FromHours(11),
                TimeSpan.FromMinutes(20))
            // Tue: rest at the hotel, then the visit, then back to the hotel
            .StayAt(Places.NagpurHotel, At(11, 5, 40), TimeSpan.FromHours(3) + TimeSpan.FromMinutes(50),
                TimeSpan.FromMinutes(15))
            .TravelFromTo(Places.NagpurHotel, Places.NagpurYard, At(11, 9, 30), TimeSpan.FromMinutes(35),
                TimeSpan.FromMinutes(5))
            .StayAt(Places.NagpurYard, At(11, 10, 5), TimeSpan.FromMinutes(85))
            .TravelFromTo(Places.NagpurYard, Places.NagpurHotel, At(11, 11, 30), TimeSpan.FromMinutes(30),
                TimeSpan.FromMinutes(5))
            // Tue night at the hotel
            .StayAt(Places.NagpurHotel, At(11, 12, 0), TimeSpan.FromHours(20), TimeSpan.FromMinutes(30))
            // Wed: the return leg, a full day of travel
            .TravelFromTo(Places.NagpurHotel, Places.PuneHome, At(12, 8, 0), TimeSpan.FromHours(12),
                TimeSpan.FromMinutes(20))
            .StayAt(Places.PuneHome, At(12, 20, 0), TimeSpan.FromHours(2));

        return trace.Build(home, [yard], At(10, 12, 0), At(12, 23, 0), tour: tour);
    }

    private static JourneyResult Run() => new JourneyEngine().Infer(BuildTour());

    [Fact]
    public void DetectsTheWholeTourFromDepartureToReturn()
    {
        var types = Run().Events.Select(e => e.Type).ToList();

        Assert.Contains(JourneyEventType.DepartHome, types);
        Assert.Contains(JourneyEventType.ArriveCustomer, types);
        Assert.Contains(JourneyEventType.DepartCustomer, types);
        Assert.Contains(JourneyEventType.OvernightStopStart, types);
        Assert.Contains(JourneyEventType.StartReturn, types);
        Assert.Contains(JourneyEventType.ArriveHome, types);
    }

    [Fact]
    public void DepartureAndReturnLandOnTheRightDays()
    {
        var result = Run();

        var depart = result.Events.First(e => e.Type == JourneyEventType.DepartHome);
        var arriveHome = result.Events.Last(e => e.Type == JourneyEventType.ArriveHome);

        Assert.Equal(new DateOnly(2026, 8, 10), depart.LocalDate);
        Assert.Equal(new DateOnly(2026, 8, 12), arriveHome.LocalDate);
        Assert.Equal(JourneyState.AtHome, result.EndState);
    }

    [Fact]
    public void OutboundTravelSpansMidnightAsOneSegment()
    {
        // Segments are timestamp ranges, not dates. A leg that crosses midnight must not be
        // split into two, or every multi-day travel report is wrong.
        var outbound = Run().Segments.First(s => s.Type == SegmentType.OutboundTravel);

        Assert.Equal(new DateOnly(2026, 8, 10), DateOnly.FromDateTime(outbound.StartedAt.ToOffset(Ist).DateTime));
        Assert.Equal(new DateOnly(2026, 8, 11), DateOnly.FromDateTime(outbound.EndedAt!.Value.ToOffset(Ist).DateTime));
        Assert.True(outbound.DurationSeconds > 10 * 3600);
    }

    [Fact]
    public void VisitOnTheMiddleDayIsAttributedToTheRightCustomer()
    {
        var result = Run();
        var arrival = result.Events.First(e => e.Type == JourneyEventType.ArriveCustomer);

        Assert.Equal(YardId, arrival.PlaceId);
        Assert.Equal(new DateOnly(2026, 8, 11), arrival.LocalDate);

        var atCustomer = result.Segments.Single(s => s.Type == SegmentType.AtCustomer);
        Assert.InRange(atCustomer.DurationSeconds!.Value, 80 * 60, 95 * 60);
    }

    [Fact]
    public void HotelNightIsDetectedAsAnOvernightStopNotAsIdleTravel()
    {
        var result = Run();

        var overnightStart = result.Events.First(e => e.Type == JourneyEventType.OvernightStopStart);
        var overnightEnd = result.Events.First(e => e.Type == JourneyEventType.OvernightStopEnd);

        Assert.Equal(new DateOnly(2026, 8, 11), overnightStart.LocalDate);
        Assert.True(overnightEnd.OccurredAt - overnightStart.OccurredAt >= TimeSpan.FromHours(12));
        Assert.Contains(result.Segments, s => s.Type == SegmentType.OvernightStop);
    }

    [Fact]
    public void ADayOfPureTravelProducesNoVisitsAndThatIsNotAViolation()
    {
        // Monday and Wednesday are travel days. Absence of visits on them must not read as
        // non-compliance — the segments show why the day had none.
        var result = Run();

        var mondayVisits = result.Events.Count(
            e => e.Type == JourneyEventType.ArriveCustomer && e.LocalDate == new DateOnly(2026, 8, 10));

        Assert.Equal(0, mondayVisits);
        Assert.Contains(result.Segments, s =>
            s.LocalDate == new DateOnly(2026, 8, 10) && s.Type == SegmentType.OutboundTravel);
    }

    [Fact]
    public void ReturnLegIsConfidentOnTheLastTourDay()
    {
        var startReturn = Run().Events.First(e => e.Type == JourneyEventType.StartReturn);

        Assert.Equal(EventStatus.Detected, startReturn.Status);
        Assert.True(startReturn.Confidence >= EngineConfig.Default.AutoConfirmConfidence,
            $"return confidence was {startReturn.Confidence:F2}");
    }

    [Fact]
    public void LongDistanceLegsAreClassifiedAsRailNotCar()
    {
        // Rail kilometres must not be reimbursed as car kilometres. An overnight train averages
        // ~56 km/h over this route, so speed alone cannot make the call — straightness does.
        var outbound = Run().Segments.First(s => s.Type == SegmentType.OutboundTravel);

        Assert.Equal(TravelMode.Rail, outbound.TravelMode);
        Assert.InRange(outbound.DistanceM, 550_000, 700_000);   // straight-line Pune → Nagpur ≈ 620 km
    }

    [Fact]
    public void TotalDistanceCoversBothLongLegs()
    {
        var result = Run();

        // Two ~620 km legs. The synthetic trace flies straight, so this is the straight-line
        // distance rather than a road route.
        Assert.InRange(result.TotalDistanceM, 1_150_000, 1_350_000);
        Assert.Equal(0, result.EstimatedDistanceM);      // continuous evidence throughout
    }
}
