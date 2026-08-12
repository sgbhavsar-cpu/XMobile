using XMobile.Tracking.Engine.Geo;
using XMobile.Tracking.Engine.Models;

namespace XMobile.Tracking.Engine.Tests.Support;

/// <summary>
/// Builds synthetic device traces so the awkward cases can be exercised in CI without a phone:
/// iOS gaps at departure, overlapping geofences, overnight rail journeys, mock locations,
/// battery death mid-tour.
/// </summary>
public sealed class TraceBuilder
{
    private readonly List<Ping> _pings = [];
    private readonly List<GeofenceEvent> _geofenceEvents = [];
    private readonly List<StayDetection> _stays = [];
    private readonly List<PauseWindow> _pauses = [];
    private readonly List<HealthSample> _health = [];

    private int _sequence;

    /// <summary>Deterministic ids: replay must be byte-identical between runs.</summary>
    private Guid NextId() => new($"00000000-0000-0000-0000-{++_sequence:D12}");

    public TraceBuilder StayAt(GeoPoint point, DateTimeOffset from, TimeSpan duration,
        TimeSpan? interval = null, double accuracyM = 15, ActivityType activity = ActivityType.Still,
        int? batteryPct = null)
    {
        var step = interval ?? TimeSpan.FromMinutes(5);
        for (var t = from; t <= from + duration; t += step)
        {
            _pings.Add(new Ping
            {
                Id = NextId(),
                RecordedAt = t,
                Point = point,
                AccuracyM = accuracyM,
                SpeedMps = 0,
                Activity = activity,
                IsMoving = false,
                BatteryPct = batteryPct
            });
        }
        return this;
    }

    /// <summary>Straight-line travel between two points, sampled at a fixed cadence.</summary>
    public TraceBuilder TravelFromTo(GeoPoint from, GeoPoint to, DateTimeOffset departAt,
        TimeSpan duration, TimeSpan? interval = null, ActivityType activity = ActivityType.InVehicle,
        double accuracyM = 20, double? jitterDeg = null)
    {
        var step = interval ?? TimeSpan.FromSeconds(60);
        var totalSeconds = duration.TotalSeconds;
        var distanceM = GeoMath.DistanceM(from, to);
        var speedMps = distanceM / totalSeconds;

        for (var elapsed = 0.0; elapsed <= totalSeconds; elapsed += step.TotalSeconds)
        {
            var fraction = elapsed / totalSeconds;

            // A tiny deterministic wobble keeps straightness realistic for mode classification.
            var wobble = jitterDeg ?? 0;
            var offset = wobble * Math.Sin(fraction * 12);

            _pings.Add(new Ping
            {
                Id = NextId(),
                RecordedAt = departAt.AddSeconds(elapsed),
                Point = new GeoPoint(
                    from.Lat + (to.Lat - from.Lat) * fraction + offset,
                    from.Lon + (to.Lon - from.Lon) * fraction),
                AccuracyM = accuracyM,
                SpeedMps = speedMps,
                Activity = activity,
                IsMoving = true
            });
        }
        return this;
    }

    public TraceBuilder Geofence(Guid placeId, PlaceKind kind, GeofenceTransition transition,
        DateTimeOffset at, GeoPoint? point = null)
    {
        _geofenceEvents.Add(new GeofenceEvent
        {
            Id = NextId(),
            GeofenceId = placeId,
            PlaceId = placeId,
            PlaceKind = kind,
            Transition = transition,
            OccurredAt = at,
            Point = point,
            AccuracyM = 25
        });
        return this;
    }

    public TraceBuilder Stay(GeoPoint point, DateTimeOffset arrivedAt, DateTimeOffset? departedAt = null)
    {
        _stays.Add(new StayDetection
        {
            Id = NextId(),
            ArrivedAt = arrivedAt,
            DepartedAt = departedAt,
            Point = point,
            AccuracyM = 40
        });
        return this;
    }

    public TraceBuilder Pause(DateTimeOffset from, DateTimeOffset? to, string reason = "PERSONAL_BREAK")
    {
        _pauses.Add(new PauseWindow
        {
            Id = NextId(),
            PausedAt = from,
            ResumedAt = to,
            ReasonCode = reason
        });
        return this;
    }

    public TraceBuilder Health(DateTimeOffset at, bool? serviceRunning = null,
        bool? locationEnabled = null, bool? powerSaving = null, string? permission = null,
        bool? rebooted = null, int? queuedPings = null, int? batteryPct = null)
    {
        _health.Add(new HealthSample
        {
            ReportedAt = at,
            ServiceRunning = serviceRunning,
            LocationEnabled = locationEnabled,
            IsPowerSaving = powerSaving,
            PermissionLevel = permission,
            WasRebooted = rebooted,
            QueuedPings = queuedPings,
            BatteryPct = batteryPct
        });
        return this;
    }

    public TraceBuilder MockPing(GeoPoint point, DateTimeOffset at)
    {
        _pings.Add(new Ping
        {
            Id = NextId(),
            RecordedAt = at,
            Point = point,
            AccuracyM = 5,
            IsMock = true
        });
        return this;
    }

    /// <summary>A single low-quality fix — present as evidence, but unable to move the machine.</summary>
    public TraceBuilder ImpreciseePing(GeoPoint point, DateTimeOffset at, double accuracyM = 800)
    {
        _pings.Add(new Ping
        {
            Id = NextId(),
            RecordedAt = at,
            Point = point,
            AccuracyM = accuracyM
        });
        return this;
    }

    public JourneyInput Build(Place home, IReadOnlyList<Place> sites, DateTimeOffset from,
        DateTimeOffset to, JourneyState entryState = JourneyState.AtHome, TourContext? tour = null,
        EngineConfig? config = null) => new()
        {
            UserId = new Guid("22222222-2222-2222-2222-222222222222"),
            WindowFrom = from,
            WindowTo = to,
            Pings = _pings,
            GeofenceEvents = _geofenceEvents,
            Stays = _stays,
            Pauses = _pauses,
            HealthSamples = _health,
            Home = home,
            Sites = sites,
            Tour = tour,
            EntryState = entryState,
            Config = config ?? EngineConfig.Default,
            LocalOffset = TimeSpan.FromHours(5.5)
        };
}

/// <summary>Real coordinates: distances and travel times in tests should be physically sensible.</summary>
public static class Places
{
    public static readonly GeoPoint PuneHome = new(18.5204, 73.8567);
    public static readonly GeoPoint PuneCustomer = new(18.5314, 73.8446);
    public static readonly GeoPoint PuneCustomerNeighbour = new(18.5316, 73.8449);   // ~35 m away
    public static readonly GeoPoint NagpurYard = new(21.1458, 79.0882);
    public static readonly GeoPoint NagpurHotel = new(21.1305, 79.0700);
    public static readonly GeoPoint MumbaiOffice = new(19.0760, 72.8777);

    public static Place Home(double radiusM = 200) => new()
    {
        Id = new Guid("33333333-3333-3333-3333-333333333333"),
        Kind = PlaceKind.Home,
        Name = "Home",
        Point = PuneHome,
        RadiusM = radiusM,
        GeoSource = GeoSource.FieldCaptured
    };

    public static Place Site(string id, GeoPoint point, string name = "Site",
        double radiusM = 150, GeoSource source = GeoSource.FieldCaptured) => new()
        {
            Id = new Guid(id),
            Kind = PlaceKind.CustomerSite,
            Name = name,
            Point = point,
            RadiusM = radiusM,
            CustomerId = new Guid("55555555-5555-5555-5555-555555555555"),
            GeoSource = source
        };
}
