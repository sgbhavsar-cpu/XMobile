import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/mock_api_client.dart';
import '../db/app_database.dart';
import '../models/enums.dart';
import '../models/models.dart';
import 'outbox.dart';

/// The single seam between the app and the backend.
///
/// Swapping the in-memory client for the HTTP one is an override of this provider and
/// nothing else — no screen, form or repository knows which is in use.
final apiClientProvider = Provider<ApiClient>((ref) => MockApiClient());

/// Exposed so the Developer screen can toggle offline/XInfo-down simulation.
final mockApiProvider = Provider<MockApiClient?>((ref) {
  final client = ref.watch(apiClientProvider);
  return client is MockApiClient ? client : null;
});

// ------------------------------------------------------------------ session

class Session {
  const Session({this.user, this.isSignedIn = false});

  final AppUser? user;
  final bool isSignedIn;
}

class SessionNotifier extends StateNotifier<Session> {
  SessionNotifier(this._api) : super(const Session());

  final ApiClient _api;

  Future<void> signIn(String employeeCode, String password) async {
    final user = await _api.signIn(employeeCode: employeeCode, password: password);
    state = Session(user: user, isSignedIn: true);
  }

  void signOut() => state = const Session();

  Future<void> refresh() async {
    if (!state.isSignedIn) return;
    state = Session(user: await _api.currentUser(), isSignedIn: true);
  }
}

final sessionProvider = StateNotifierProvider<SessionNotifier, Session>(
  (ref) => SessionNotifier(ref.watch(apiClientProvider)),
);

// ------------------------------------------------------------------ connectivity

/// Whether the last API call failed for want of a network. Drives the offline banner
/// and the decision to queue rather than fail.
final connectivityProvider = StateProvider<bool>((ref) => true);

// ------------------------------------------------------------------ reference data
//
// Reference data is small, changes rarely and is needed by half the forms, so it is
// loaded once and kept.

final visitTypesProvider = FutureProvider<List<VisitType>>(
  (ref) => ref.watch(apiClientProvider).visitTypes(),
);

final visitOutcomesProvider = FutureProvider<List<VisitOutcome>>(
  (ref) => ref.watch(apiClientProvider).visitOutcomes(),
);

final reasonCodesProvider = FutureProvider.family<List<ReasonCode>, String>(
  (ref, domain) => ref.watch(apiClientProvider).reasonCodes(domain),
);

final expenseCategoriesProvider = FutureProvider<List<ExpenseCategory>>(
  (ref) => ref.watch(apiClientProvider).expenseCategories(),
);

final opportunityStagesProvider = FutureProvider<List<OpportunityStage>>(
  (ref) => ref.watch(apiClientProvider).opportunityStages(),
);

final formTemplatesProvider = FutureProvider<List<FormTemplate>>(
  (ref) => ref.watch(apiClientProvider).formTemplates(),
);

// ------------------------------------------------------------------ data
//
// A bumped [refreshTickProvider] invalidates every list at once. Crude compared with
// per-entity cache invalidation, but with an in-memory backend it keeps every screen
// consistent after a mutation without threading refresh calls through the whole app.

final refreshTickProvider = StateProvider<int>((ref) => 0);

void bumpRefresh(Ref ref) =>
    ref.read(refreshTickProvider.notifier).update((tick) => tick + 1);

void bumpRefreshFrom(WidgetRef ref) =>
    ref.read(refreshTickProvider.notifier).update((tick) => tick + 1);

final customersProvider = FutureProvider.family<List<Customer>, String?>((ref, query) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).customers(query: query);
});

final customerProvider = FutureProvider.family<Customer, String>((ref, id) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).customer(id);
});

final customerSummaryProvider = FutureProvider.family<Customer360, String>((ref, id) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).customerSummary(id);
});

final salesHistoryProvider = FutureProvider.family<List<SalesHistoryItem>, String>((ref, id) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).salesHistory(id);
});

final customerVisitsProvider = FutureProvider.family<List<Visit>, String>((ref, id) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).customerVisits(id);
});

final opportunitiesProvider =
    FutureProvider.family<List<Opportunity>, ({String? customerId, bool openOnly})>((ref, args) {
  ref.watch(refreshTickProvider);
  return ref
      .watch(apiClientProvider)
      .opportunities(customerId: args.customerId, openOnly: args.openOnly);
});

final opportunityHistoryProvider =
    FutureProvider.family<List<OpportunityStageChange>, String>((ref, id) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).opportunityHistory(id);
});

final toursProvider = FutureProvider<List<Tour>>((ref) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).tours();
});

final tourProvider = FutureProvider.family<Tour, String>((ref, id) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).tour(id);
});

final visitPlansProvider =
    FutureProvider.family<List<VisitPlan>, ({DateTime? from, DateTime? to, String? tourId})>(
        (ref, args) {
  ref.watch(refreshTickProvider);
  return ref
      .watch(apiClientProvider)
      .visitPlans(from: args.from, to: args.to, tourId: args.tourId);
});

final visitsProvider =
    FutureProvider.family<List<Visit>, ({DateTime? from, DateTime? to})>((ref, args) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).visits(from: args.from, to: args.to);
});

final visitReportProvider = FutureProvider.family<VisitReport?, String>((ref, visitId) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).visitReport(visitId);
});

final visitOpportunityIdsProvider = FutureProvider.family<List<String>, String>((ref, visitId) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).visitOpportunityIds(visitId);
});

final expensesProvider =
    FutureProvider.family<List<Expense>, ({DateTime? from, DateTime? to})>((ref, args) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).expenses(from: args.from, to: args.to);
});

final shareInboxProvider = FutureProvider<List<ShareInboxItem>>((ref) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).shareInbox();
});

final journeyEventsProvider =
    FutureProvider.family<List<JourneyEvent>, ({DateTime from, DateTime to})>((ref, args) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).journeyEvents(from: args.from, to: args.to);
});

final journeySegmentsProvider =
    FutureProvider.family<List<JourneySegment>, ({DateTime from, DateTime to})>((ref, args) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).journeySegments(from: args.from, to: args.to);
});

final daySummariesProvider =
    FutureProvider.family<List<DaySummary>, ({DateTime from, DateTime to})>((ref, args) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).daySummaries(from: args.from, to: args.to);
});

final trackingHealthProvider = FutureProvider<TrackingHealth>((ref) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).trackingHealth();
});

final trackingActiveProvider = FutureProvider<bool>((ref) {
  ref.watch(refreshTickProvider);
  return ref.watch(apiClientProvider).isTrackingActive();
});

/// The tour the rep is on right now, if any — the anchor for today's screen.
final activeTourProvider = FutureProvider<Tour?>((ref) async {
  ref.watch(refreshTickProvider);
  final tours = await ref.watch(apiClientProvider).tours();
  for (final tour in tours) {
    if (tour.status == TourStatus.inProgress) return tour;
  }
  return null;
});

/// The visit currently checked in to, if any. Its presence changes what Today offers.
final openVisitProvider = FutureProvider<Visit?>((ref) async {
  ref.watch(refreshTickProvider);
  final visits = await ref.watch(apiClientProvider).visits();
  for (final visit in visits) {
    if (visit.isOpen) return visit;
  }
  return null;
});

// ------------------------------------------------------------------ local persistence

/// Defaults to a real on-device file (see AppDatabase's constructor); override with
/// `AppDatabase(NativeDatabase.memory())` in tests, the same pattern `apiClientProvider`
/// demonstrates for swapping in a fake.
final driftDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

// ------------------------------------------------------------------ outbox

final outboxProvider = StateNotifierProvider<OutboxNotifier, List<OutboxEntry>>(
  (ref) => OutboxNotifier(ref.watch(driftDatabaseProvider)),
);

final pendingSyncCountProvider = Provider<int>((ref) {
  final entries = ref.watch(outboxProvider);
  return entries.where((e) => e.state != SyncState.synced).length;
});
