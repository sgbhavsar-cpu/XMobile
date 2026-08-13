// Members are named to match the PostgreSQL enum labels in db/schema exactly (see
// XMobilePostgres.RegisterEnumTypes, which maps these 1:1 with no name translation) rather than
// following .NET PascalCase enum-member style — that exactness is what keeps the mapping obvious
// and avoids a second source of truth for the label spelling.
namespace XMobile.Persistence.Enums;

public enum UserStatus { ACTIVE, INACTIVE, SUSPENDED }

public enum DevicePlatform { ANDROID, IOS }

public enum GeoSource { NONE, GEOCODED, IMPORTED, FIELD_CAPTURED, VERIFIED }

public enum AccountLifecycle { PROSPECT, PENDING_APPROVAL, ACTIVE, REJECTED, INACTIVE }

public enum TourStatus { DRAFT, PLANNED, IN_PROGRESS, COMPLETED, CANCELLED, ABANDONED }

public enum DayActivity { TRAVEL, VISITS, MIXED, REST, LEAVE }

public enum PlanStatus { PLANNED, COMPLETED, SKIPPED, RESCHEDULED, CANCELLED }

public enum TravelMode { WALK, TWO_WHEELER, CAR, BUS, RAIL, AIR, BOAT, UNKNOWN }

public enum VisitStatus { CHECKED_IN, CHECKED_OUT, REPORT_SUBMITTED, VOIDED }

public enum CheckinMethod { GEOFENCE, MANUAL, QR, NFC, REMOTE }

public enum TemplateStatus { DRAFT, PUBLISHED, RETIRED }

public enum ChangeOp { UPSERT, DELETE, SCOPE_REMOVE }

public enum MutationOp { INSERT, UPDATE, DELETE }

public enum MutationStatus { APPLIED, DUPLICATE, CONFLICT, REJECTED, DEFERRED }

public enum JourneyState { AT_HOME, OUTBOUND_TRANSIT, AT_CUSTOMER, INTER_TRANSIT, OVERNIGHT_STOP, RETURN_TRANSIT, PAUSED, UNKNOWN }

public enum JourneyEventType
{
    DEPART_HOME, ARRIVE_CUSTOMER, DEPART_CUSTOMER, START_RETURN, ARRIVE_HOME,
    OVERNIGHT_STOP_START, OVERNIGHT_STOP_END, TRANSIT_START, TRANSIT_END,
    PAUSE_START, PAUSE_END, GAP_START, GAP_END,
}

public enum SegmentType { OUTBOUND_TRAVEL, INTER_TRAVEL, RETURN_TRAVEL, AT_CUSTOMER, AT_HOME, OVERNIGHT_STOP, GAP, PAUSED }

public enum DetectionMethod { GEOFENCE, DWELL, PING_CLUSTER, IOS_VISIT, ACTIVITY, MANUAL, INFERRED_FROM_GAP, CHECKIN, SYSTEM }

public enum EventStatus { DETECTED, NEEDS_REVIEW, CONFIRMED, REJECTED, SUPERSEDED }

public enum PingSource { FG_SERVICE, GEOFENCE, SIGNIFICANT_CHANGE, IOS_VISIT, MOTION, MANUAL, HEARTBEAT }

public enum SessionStatus { ACTIVE, PAUSED, ENDED }
