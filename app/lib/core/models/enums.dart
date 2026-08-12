/// Enumerations mirroring the API contract (api/openapi.yaml) and the database
/// enum types. Wire values are the SCREAMING_SNAKE strings the API uses; `label`
/// is what a rep sees.
library;

enum TourStatus {
  draft('DRAFT', 'Draft'),
  planned('PLANNED', 'Planned'),
  inProgress('IN_PROGRESS', 'In progress'),
  completed('COMPLETED', 'Completed'),
  cancelled('CANCELLED', 'Cancelled'),
  abandoned('ABANDONED', 'Abandoned');

  const TourStatus(this.wire, this.label);
  final String wire;
  final String label;

  static TourStatus fromWire(String value) =>
      TourStatus.values.firstWhere((e) => e.wire == value, orElse: () => TourStatus.draft);

  bool get isOpen => this == TourStatus.planned || this == TourStatus.inProgress;
}

enum DayActivity {
  travel('TRAVEL', 'Travel'),
  visits('VISITS', 'Visits'),
  mixed('MIXED', 'Mixed'),
  rest('REST', 'Rest'),
  leave('LEAVE', 'Leave');

  const DayActivity(this.wire, this.label);
  final String wire;
  final String label;

  static DayActivity fromWire(String value) =>
      DayActivity.values.firstWhere((e) => e.wire == value, orElse: () => DayActivity.visits);
}

enum PlanStatus {
  planned('PLANNED', 'Planned'),
  completed('COMPLETED', 'Completed'),
  skipped('SKIPPED', 'Skipped'),
  rescheduled('RESCHEDULED', 'Rescheduled'),
  cancelled('CANCELLED', 'Cancelled');

  const PlanStatus(this.wire, this.label);
  final String wire;
  final String label;

  static PlanStatus fromWire(String value) =>
      PlanStatus.values.firstWhere((e) => e.wire == value, orElse: () => PlanStatus.planned);
}

enum VisitStatus {
  checkedIn('CHECKED_IN', 'Checked in'),
  checkedOut('CHECKED_OUT', 'Checked out'),
  reportSubmitted('REPORT_SUBMITTED', 'Report submitted'),
  voided('VOIDED', 'Voided');

  const VisitStatus(this.wire, this.label);
  final String wire;
  final String label;

  static VisitStatus fromWire(String value) =>
      VisitStatus.values.firstWhere((e) => e.wire == value, orElse: () => VisitStatus.checkedIn);
}

enum CheckInMethod {
  geofence('GEOFENCE', 'Automatic (geofence)'),
  manual('MANUAL', 'Manual'),
  qr('QR', 'QR code'),
  nfc('NFC', 'NFC'),
  remote('REMOTE', 'Remote / phone visit');

  const CheckInMethod(this.wire, this.label);
  final String wire;
  final String label;

  static CheckInMethod fromWire(String value) =>
      CheckInMethod.values.firstWhere((e) => e.wire == value, orElse: () => CheckInMethod.manual);
}

enum ExpenseStatus {
  draft('DRAFT', 'Draft'),
  submitted('SUBMITTED', 'Submitted'),
  pushed('PUSHED', 'Sent to XInfo'),
  acknowledged('ACKNOWLEDGED', 'Acknowledged'),
  pushFailed('PUSH_FAILED', 'Send failed'),
  voided('VOIDED', 'Voided');

  const ExpenseStatus(this.wire, this.label);
  final String wire;
  final String label;

  static ExpenseStatus fromWire(String value) =>
      ExpenseStatus.values.firstWhere((e) => e.wire == value, orElse: () => ExpenseStatus.draft);

  /// Once pushed, XInfo owns the record; corrections become a new entry.
  bool get isEditable => this == ExpenseStatus.draft || this == ExpenseStatus.submitted;
}

enum CaptureSource {
  manual('MANUAL', 'Entered manually'),
  shareIntent('SHARE_INTENT', 'Shared from another app'),
  camera('CAMERA', 'Camera'),
  gallery('GALLERY', 'Gallery'),
  file('FILE', 'File'),
  autoMileage('AUTO_MILEAGE', 'From tracked distance');

  const CaptureSource(this.wire, this.label);
  final String wire;
  final String label;

  static CaptureSource fromWire(String value) =>
      CaptureSource.values.firstWhere((e) => e.wire == value, orElse: () => CaptureSource.manual);
}

enum TravelMode {
  unknown('UNKNOWN', 'Unknown'),
  walk('WALK', 'Walk'),
  twoWheeler('TWO_WHEELER', 'Two-wheeler'),
  car('CAR', 'Car'),
  bus('BUS', 'Bus'),
  rail('RAIL', 'Rail'),
  air('AIR', 'Air'),
  boat('BOAT', 'Boat');

  const TravelMode(this.wire, this.label);
  final String wire;
  final String label;

  static TravelMode fromWire(String? value) =>
      TravelMode.values.firstWhere((e) => e.wire == value, orElse: () => TravelMode.unknown);
}

enum JourneyEventType {
  departHome('DEPART_HOME', 'Left home'),
  arriveCustomer('ARRIVE_CUSTOMER', 'Reached customer'),
  departCustomer('DEPART_CUSTOMER', 'Left customer'),
  startReturn('START_RETURN', 'Started back'),
  arriveHome('ARRIVE_HOME', 'Reached home'),
  overnightStopStart('OVERNIGHT_STOP_START', 'Overnight stop'),
  overnightStopEnd('OVERNIGHT_STOP_END', 'Left overnight stop'),
  transitStart('TRANSIT_START', 'Transit started'),
  transitEnd('TRANSIT_END', 'Transit ended'),
  pauseStart('PAUSE_START', 'Tracking paused'),
  pauseEnd('PAUSE_END', 'Tracking resumed'),
  gapStart('GAP_START', 'Signal lost'),
  gapEnd('GAP_END', 'Signal restored');

  const JourneyEventType(this.wire, this.label);
  final String wire;
  final String label;

  static JourneyEventType fromWire(String value) => JourneyEventType.values
      .firstWhere((e) => e.wire == value, orElse: () => JourneyEventType.transitStart);

  /// The four transitions a rep can enter by hand when detection missed them.
  static const manualEntryTypes = [
    JourneyEventType.departHome,
    JourneyEventType.arriveCustomer,
    JourneyEventType.departCustomer,
    JourneyEventType.startReturn,
    JourneyEventType.arriveHome,
    JourneyEventType.overnightStopStart,
  ];
}

enum EventStatus {
  detected('DETECTED', 'Detected'),
  needsReview('NEEDS_REVIEW', 'Needs review'),
  confirmed('CONFIRMED', 'Confirmed'),
  rejected('REJECTED', 'Rejected'),
  superseded('SUPERSEDED', 'Superseded');

  const EventStatus(this.wire, this.label);
  final String wire;
  final String label;

  static EventStatus fromWire(String value) =>
      EventStatus.values.firstWhere((e) => e.wire == value, orElse: () => EventStatus.detected);
}

enum AccountLifecycle {
  prospect('PROSPECT', 'Prospect'),
  pendingApproval('PENDING_APPROVAL', 'Awaiting approval'),
  active('ACTIVE', 'Active'),
  rejected('REJECTED', 'Rejected'),
  inactive('INACTIVE', 'Inactive');

  const AccountLifecycle(this.wire, this.label);
  final String wire;
  final String label;

  static AccountLifecycle fromWire(String value) => AccountLifecycle.values
      .firstWhere((e) => e.wire == value, orElse: () => AccountLifecycle.active);
}

enum GeoSource {
  none('NONE', 'Not set'),
  geocoded('GEOCODED', 'From address'),
  imported('IMPORTED', 'Imported'),
  fieldCaptured('FIELD_CAPTURED', 'Captured on site'),
  verified('VERIFIED', 'Verified');

  const GeoSource(this.wire, this.label);
  final String wire;
  final String label;

  static GeoSource fromWire(String? value) =>
      GeoSource.values.firstWhere((e) => e.wire == value, orElse: () => GeoSource.none);

  bool get isTrusted => this == GeoSource.fieldCaptured || this == GeoSource.verified;
}

enum SyncState {
  synced('SYNCED', 'Synced'),
  pending('PENDING', 'Waiting to sync'),
  failed('FAILED', 'Sync failed'),
  conflict('CONFLICT', 'Needs your decision');

  const SyncState(this.wire, this.label);
  final String wire;
  final String label;
}
