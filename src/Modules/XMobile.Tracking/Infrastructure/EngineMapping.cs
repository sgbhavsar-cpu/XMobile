using XMobile.Persistence.Enums;
using XMobile.Shared;
using EngineModels = XMobile.Tracking.Engine.Models;

namespace XMobile.Tracking.Infrastructure;

/// <summary>
/// Bidirectional conversions between the DB-facing enums in XMobile.Persistence.Enums (spelled to
/// match the Postgres labels exactly) and the pure engine's PascalCase enums in
/// XMobile.Tracking.Engine.Models (kept dependency-free of Persistence by design). Every member on
/// both sides is a 1:1 match, just spelled differently — see InferenceRunner.cs, the only caller.
/// Aliased as "EngineModels" rather than "Engine" — inside namespace XMobile.Tracking.Infrastructure,
/// the sibling namespace XMobile.Tracking.Engine is reachable unqualified as "Engine" and would
/// shadow a same-named alias (enclosing-namespace member lookup beats using-alias resolution).
/// </summary>
internal static class EngineMapping
{
    public static EngineModels.GeoPoint ToEngine(this GeoPoint p) => new(p.Lat, p.Lon);

    public static GeoPoint ToShared(this EngineModels.GeoPoint p) => new(p.Lat, p.Lon);

    public static EngineModels.PingSource ToEngine(this PingSource s) => s switch
    {
        PingSource.FG_SERVICE => EngineModels.PingSource.FgService,
        PingSource.GEOFENCE => EngineModels.PingSource.Geofence,
        PingSource.SIGNIFICANT_CHANGE => EngineModels.PingSource.SignificantChange,
        PingSource.IOS_VISIT => EngineModels.PingSource.IosVisit,
        PingSource.MOTION => EngineModels.PingSource.Motion,
        PingSource.MANUAL => EngineModels.PingSource.Manual,
        PingSource.HEARTBEAT => EngineModels.PingSource.Heartbeat,
        _ => throw new ArgumentOutOfRangeException(nameof(s)),
    };

    public static EngineModels.ActivityType ToEngineActivity(this string? activityType) => activityType?.ToUpperInvariant() switch
    {
        "STILL" => EngineModels.ActivityType.Still,
        "WALKING" => EngineModels.ActivityType.Walking,
        "RUNNING" => EngineModels.ActivityType.Running,
        "ON_BICYCLE" => EngineModels.ActivityType.OnBicycle,
        "IN_VEHICLE" => EngineModels.ActivityType.InVehicle,
        _ => EngineModels.ActivityType.Unknown,
    };

    public static EngineModels.GeofenceTransition ToEngine(this string eventType) => eventType switch
    {
        "ENTER" => EngineModels.GeofenceTransition.Enter,
        "EXIT" => EngineModels.GeofenceTransition.Exit,
        "DWELL" => EngineModels.GeofenceTransition.Dwell,
        _ => throw new ArgumentOutOfRangeException(nameof(eventType)),
    };

    public static EngineModels.PlaceKind ToEnginePlaceKind(this string? refType) => refType switch
    {
        "HOME" => EngineModels.PlaceKind.Home,
        "CUSTOMER_SITE" => EngineModels.PlaceKind.CustomerSite,
        "STAY" => EngineModels.PlaceKind.Stay,
        _ => EngineModels.PlaceKind.None,
    };

    public static string? ToRefType(this EngineModels.PlaceKind kind) => kind switch
    {
        EngineModels.PlaceKind.Home => "HOME",
        EngineModels.PlaceKind.CustomerSite => "CUSTOMER_SITE",
        EngineModels.PlaceKind.Stay => "STAY",
        EngineModels.PlaceKind.None => null,
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    public static JourneyState ToPersistence(this EngineModels.JourneyState s) => s switch
    {
        EngineModels.JourneyState.AtHome => JourneyState.AT_HOME,
        EngineModels.JourneyState.OutboundTransit => JourneyState.OUTBOUND_TRANSIT,
        EngineModels.JourneyState.AtCustomer => JourneyState.AT_CUSTOMER,
        EngineModels.JourneyState.InterTransit => JourneyState.INTER_TRANSIT,
        EngineModels.JourneyState.OvernightStop => JourneyState.OVERNIGHT_STOP,
        EngineModels.JourneyState.ReturnTransit => JourneyState.RETURN_TRANSIT,
        EngineModels.JourneyState.Paused => JourneyState.PAUSED,
        EngineModels.JourneyState.Unknown => JourneyState.UNKNOWN,
        _ => throw new ArgumentOutOfRangeException(nameof(s)),
    };

    public static EngineModels.JourneyState ToEngine(this JourneyState s) => s switch
    {
        JourneyState.AT_HOME => EngineModels.JourneyState.AtHome,
        JourneyState.OUTBOUND_TRANSIT => EngineModels.JourneyState.OutboundTransit,
        JourneyState.AT_CUSTOMER => EngineModels.JourneyState.AtCustomer,
        JourneyState.INTER_TRANSIT => EngineModels.JourneyState.InterTransit,
        JourneyState.OVERNIGHT_STOP => EngineModels.JourneyState.OvernightStop,
        JourneyState.RETURN_TRANSIT => EngineModels.JourneyState.ReturnTransit,
        JourneyState.PAUSED => EngineModels.JourneyState.Paused,
        JourneyState.UNKNOWN => EngineModels.JourneyState.Unknown,
        _ => throw new ArgumentOutOfRangeException(nameof(s)),
    };

    public static JourneyEventType ToPersistence(this EngineModels.JourneyEventType t) => t switch
    {
        EngineModels.JourneyEventType.DepartHome => JourneyEventType.DEPART_HOME,
        EngineModels.JourneyEventType.ArriveCustomer => JourneyEventType.ARRIVE_CUSTOMER,
        EngineModels.JourneyEventType.DepartCustomer => JourneyEventType.DEPART_CUSTOMER,
        EngineModels.JourneyEventType.StartReturn => JourneyEventType.START_RETURN,
        EngineModels.JourneyEventType.ArriveHome => JourneyEventType.ARRIVE_HOME,
        EngineModels.JourneyEventType.OvernightStopStart => JourneyEventType.OVERNIGHT_STOP_START,
        EngineModels.JourneyEventType.OvernightStopEnd => JourneyEventType.OVERNIGHT_STOP_END,
        EngineModels.JourneyEventType.TransitStart => JourneyEventType.TRANSIT_START,
        EngineModels.JourneyEventType.TransitEnd => JourneyEventType.TRANSIT_END,
        EngineModels.JourneyEventType.PauseStart => JourneyEventType.PAUSE_START,
        EngineModels.JourneyEventType.PauseEnd => JourneyEventType.PAUSE_END,
        EngineModels.JourneyEventType.GapStart => JourneyEventType.GAP_START,
        EngineModels.JourneyEventType.GapEnd => JourneyEventType.GAP_END,
        _ => throw new ArgumentOutOfRangeException(nameof(t)),
    };

    public static EngineModels.JourneyEventType ToEngine(this JourneyEventType t) => t switch
    {
        JourneyEventType.DEPART_HOME => EngineModels.JourneyEventType.DepartHome,
        JourneyEventType.ARRIVE_CUSTOMER => EngineModels.JourneyEventType.ArriveCustomer,
        JourneyEventType.DEPART_CUSTOMER => EngineModels.JourneyEventType.DepartCustomer,
        JourneyEventType.START_RETURN => EngineModels.JourneyEventType.StartReturn,
        JourneyEventType.ARRIVE_HOME => EngineModels.JourneyEventType.ArriveHome,
        JourneyEventType.OVERNIGHT_STOP_START => EngineModels.JourneyEventType.OvernightStopStart,
        JourneyEventType.OVERNIGHT_STOP_END => EngineModels.JourneyEventType.OvernightStopEnd,
        JourneyEventType.TRANSIT_START => EngineModels.JourneyEventType.TransitStart,
        JourneyEventType.TRANSIT_END => EngineModels.JourneyEventType.TransitEnd,
        JourneyEventType.PAUSE_START => EngineModels.JourneyEventType.PauseStart,
        JourneyEventType.PAUSE_END => EngineModels.JourneyEventType.PauseEnd,
        JourneyEventType.GAP_START => EngineModels.JourneyEventType.GapStart,
        JourneyEventType.GAP_END => EngineModels.JourneyEventType.GapEnd,
        _ => throw new ArgumentOutOfRangeException(nameof(t)),
    };

    public static SegmentType ToPersistence(this EngineModels.SegmentType t) => t switch
    {
        EngineModels.SegmentType.OutboundTravel => SegmentType.OUTBOUND_TRAVEL,
        EngineModels.SegmentType.InterTravel => SegmentType.INTER_TRAVEL,
        EngineModels.SegmentType.ReturnTravel => SegmentType.RETURN_TRAVEL,
        EngineModels.SegmentType.AtCustomer => SegmentType.AT_CUSTOMER,
        EngineModels.SegmentType.AtHome => SegmentType.AT_HOME,
        EngineModels.SegmentType.OvernightStop => SegmentType.OVERNIGHT_STOP,
        EngineModels.SegmentType.Gap => SegmentType.GAP,
        EngineModels.SegmentType.Paused => SegmentType.PAUSED,
        _ => throw new ArgumentOutOfRangeException(nameof(t)),
    };

    public static DetectionMethod ToPersistence(this EngineModels.DetectionMethod m) => m switch
    {
        EngineModels.DetectionMethod.Geofence => DetectionMethod.GEOFENCE,
        EngineModels.DetectionMethod.Dwell => DetectionMethod.DWELL,
        EngineModels.DetectionMethod.PingCluster => DetectionMethod.PING_CLUSTER,
        EngineModels.DetectionMethod.IosVisit => DetectionMethod.IOS_VISIT,
        EngineModels.DetectionMethod.Activity => DetectionMethod.ACTIVITY,
        EngineModels.DetectionMethod.Manual => DetectionMethod.MANUAL,
        EngineModels.DetectionMethod.InferredFromGap => DetectionMethod.INFERRED_FROM_GAP,
        EngineModels.DetectionMethod.CheckIn => DetectionMethod.CHECKIN,
        EngineModels.DetectionMethod.System => DetectionMethod.SYSTEM,
        _ => throw new ArgumentOutOfRangeException(nameof(m)),
    };

    public static EngineModels.DetectionMethod ToEngine(this DetectionMethod m) => m switch
    {
        DetectionMethod.GEOFENCE => EngineModels.DetectionMethod.Geofence,
        DetectionMethod.DWELL => EngineModels.DetectionMethod.Dwell,
        DetectionMethod.PING_CLUSTER => EngineModels.DetectionMethod.PingCluster,
        DetectionMethod.IOS_VISIT => EngineModels.DetectionMethod.IosVisit,
        DetectionMethod.ACTIVITY => EngineModels.DetectionMethod.Activity,
        DetectionMethod.MANUAL => EngineModels.DetectionMethod.Manual,
        DetectionMethod.INFERRED_FROM_GAP => EngineModels.DetectionMethod.InferredFromGap,
        DetectionMethod.CHECKIN => EngineModels.DetectionMethod.CheckIn,
        DetectionMethod.SYSTEM => EngineModels.DetectionMethod.System,
        _ => throw new ArgumentOutOfRangeException(nameof(m)),
    };

    public static EventStatus ToPersistence(this EngineModels.EventStatus s) => s switch
    {
        EngineModels.EventStatus.Detected => EventStatus.DETECTED,
        EngineModels.EventStatus.NeedsReview => EventStatus.NEEDS_REVIEW,
        EngineModels.EventStatus.Confirmed => EventStatus.CONFIRMED,
        EngineModels.EventStatus.Rejected => EventStatus.REJECTED,
        EngineModels.EventStatus.Superseded => EventStatus.SUPERSEDED,
        _ => throw new ArgumentOutOfRangeException(nameof(s)),
    };

    public static EngineModels.EventStatus ToEngine(this EventStatus s) => s switch
    {
        EventStatus.DETECTED => EngineModels.EventStatus.Detected,
        EventStatus.NEEDS_REVIEW => EngineModels.EventStatus.NeedsReview,
        EventStatus.CONFIRMED => EngineModels.EventStatus.Confirmed,
        EventStatus.REJECTED => EngineModels.EventStatus.Rejected,
        EventStatus.SUPERSEDED => EngineModels.EventStatus.Superseded,
        _ => throw new ArgumentOutOfRangeException(nameof(s)),
    };

    public static TravelMode ToPersistence(this EngineModels.TravelMode m) => m switch
    {
        EngineModels.TravelMode.Unknown => TravelMode.UNKNOWN,
        EngineModels.TravelMode.Walk => TravelMode.WALK,
        EngineModels.TravelMode.TwoWheeler => TravelMode.TWO_WHEELER,
        EngineModels.TravelMode.Car => TravelMode.CAR,
        EngineModels.TravelMode.Bus => TravelMode.BUS,
        EngineModels.TravelMode.Rail => TravelMode.RAIL,
        EngineModels.TravelMode.Air => TravelMode.AIR,
        EngineModels.TravelMode.Boat => TravelMode.BOAT,
        _ => throw new ArgumentOutOfRangeException(nameof(m)),
    };

    public static EngineModels.GeoSource ToEngine(this GeoSource s) => s switch
    {
        GeoSource.NONE => EngineModels.GeoSource.None,
        GeoSource.GEOCODED => EngineModels.GeoSource.Geocoded,
        GeoSource.IMPORTED => EngineModels.GeoSource.Imported,
        GeoSource.FIELD_CAPTURED => EngineModels.GeoSource.FieldCaptured,
        GeoSource.VERIFIED => EngineModels.GeoSource.Verified,
        _ => throw new ArgumentOutOfRangeException(nameof(s)),
    };
}
