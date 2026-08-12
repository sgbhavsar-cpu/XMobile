import '../models/models.dart';

/// The contract between the app and the backend, mirroring api/openapi.yaml.
///
/// Everything above this interface is written as if the API exists. Today it is
/// satisfied by [MockApiClient], which holds realistic data in memory so every screen
/// and form can be used and tested before the backend is built. Connecting to the real
/// service means implementing this once against HTTP and swapping one provider —
/// no screen, form or repository changes.
abstract interface class ApiClient {
  // --- auth ---
  Future<AppUser> signIn({required String employeeCode, required String password});
  Future<AppUser> currentUser();
  Future<void> updateHomeLocation(HomeLocation home);

  // --- reference data ---
  Future<List<VisitType>> visitTypes();
  Future<List<VisitOutcome>> visitOutcomes();
  Future<List<ReasonCode>> reasonCodes(String domain);
  Future<List<ExpenseCategory>> expenseCategories();
  Future<List<OpportunityStage>> opportunityStages();
  Future<List<FormTemplate>> formTemplates();

  // --- customers ---
  Future<List<Customer>> customers({String? query});
  Future<Customer> customer(String id);
  Future<Customer360> customerSummary(String id);
  Future<List<SalesHistoryItem>> salesHistory(String customerId);
  Future<List<Visit>> customerVisits(String customerId);
  Future<Customer> proposeCustomer(Customer draft);
  Future<CustomerSite> addSite(CustomerSite site);
  Future<CustomerContact> addContact(CustomerContact contact);
  Future<CustomerSite> captureSiteLocation(String siteId, GeoPoint point, {int? radiusM});

  // --- opportunities ---
  Future<List<Opportunity>> opportunities({String? customerId, bool openOnly});
  Future<Opportunity> createOpportunity(Opportunity draft);
  Future<Opportunity> updateOpportunity(Opportunity updated, {String? visitId, String? reason});
  Future<List<OpportunityStageChange>> opportunityHistory(String opportunityId);

  // --- planning ---
  Future<List<Tour>> tours();
  Future<Tour> tour(String id);
  Future<Tour> saveTour(Tour tour);
  Future<Tour> startTour(String id);
  Future<Tour> completeTour(String id);
  Future<List<VisitPlan>> visitPlans({DateTime? from, DateTime? to, String? tourId});
  Future<VisitPlan> saveVisitPlan(VisitPlan plan);
  Future<VisitPlan> skipVisitPlan(String planId, String reasonCode, String? remark);

  // --- visits ---
  Future<List<Visit>> visits({DateTime? from, DateTime? to});
  Future<Visit> checkIn(Visit visit);
  Future<Visit> checkOut(String visitId, DateTime at, GeoPoint? point);
  Future<VisitReport?> visitReport(String visitId);
  Future<VisitReport> saveVisitReport(VisitReport report, {required bool submit});
  Future<void> linkVisitOpportunities(String visitId, List<String> opportunityIds);
  Future<List<String>> visitOpportunityIds(String visitId);

  // --- expenses ---
  Future<List<Expense>> expenses({DateTime? from, DateTime? to});
  Future<Expense> saveExpense(Expense expense, {required bool submit});
  Future<void> deleteExpense(String id);
  Future<List<Expense>> duplicateCandidates(Expense expense);
  Future<MileageSuggestion?> mileageSuggestion(DateTime date, {String? tourId});
  Future<List<ShareInboxItem>> shareInbox();
  Future<ShareInboxItem> simulateSharedFile({required String fileName, required String sourceApp});
  Future<void> dismissShareInboxItem(String id);
  Future<Attachment> addAttachment(Attachment attachment);
  Future<List<Attachment>> attachments();

  // --- journey / tracking ---
  Future<List<JourneyEvent>> journeyEvents({required DateTime from, required DateTime to});
  Future<List<JourneySegment>> journeySegments({required DateTime from, required DateTime to});
  Future<List<DaySummary>> daySummaries({required DateTime from, required DateTime to});
  Future<JourneyEvent> addManualJourneyEvent(JourneyEvent event);
  Future<JourneyEvent> correctJourneyEvent(String eventId, DateTime occurredAt, String reason);
  Future<JourneyEvent> confirmJourneyEvent(String eventId);
  Future<TrackingHealth> trackingHealth();
  Future<TrackingHealth> updateTrackingHealth(TrackingHealth health);
  Future<bool> isTrackingActive();
  Future<void> setTrackingActive(bool active, {String? pauseReasonCode});
}

/// Raised for anything the API refuses. Carries a message fit to show a rep.
class ApiException implements Exception {
  ApiException(this.message, {this.fieldErrors = const {}});

  final String message;
  final Map<String, String> fieldErrors;

  @override
  String toString() => message;
}

/// Raised when the device has no connectivity. Callers queue the mutation and carry on —
/// nothing user-facing ever blocks on the network.
class OfflineException implements Exception {
  const OfflineException();

  @override
  String toString() => 'No connection';
}
