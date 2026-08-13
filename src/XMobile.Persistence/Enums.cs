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
