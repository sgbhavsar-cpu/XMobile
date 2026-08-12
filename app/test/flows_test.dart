import 'package:flutter_test/flutter_test.dart';
import 'package:xmobile/core/api/api_client.dart';
import 'package:xmobile/core/api/mock_api_client.dart';
import 'package:xmobile/core/models/enums.dart';
import 'package:xmobile/core/models/models.dart';

/// End-to-end flows against the in-memory backend.
///
/// These exercise the rules the forms rely on — the ones that decide whether a rep's day
/// is recorded correctly or quietly wrong. They run headlessly, with no device.
void main() {
  late MockApiClient api;

  setUp(() => api = MockApiClient(latency: Duration.zero));

  group('a day in the field', () {
    test('rep checks in, checks out and submits a report', () async {
      final plans = await api.visitPlans();
      final plan = plans.first;

      final visit = Visit(
        id: 'v1',
        visitPlanId: plan.id,
        customerId: plan.customerId,
        customerName: plan.customerName,
        siteId: plan.siteId,
        siteName: plan.siteName,
        visitTypeCode: plan.visitTypeCode,
        checkInAt: DateTime.now(),
        status: VisitStatus.checkedIn,
      );

      await api.checkIn(visit);

      // Checking in completes the plan: plan-vs-actual depends on this.
      final updatedPlans = await api.visitPlans();
      expect(
        updatedPlans.firstWhere((p) => p.id == plan.id).status,
        PlanStatus.completed,
      );

      await api.checkOut('v1', DateTime.now().add(const Duration(minutes: 45)), null);
      final visits = await api.visits();
      expect(visits.firstWhere((v) => v.id == 'v1').duration!.inMinutes, 45);

      await api.saveVisitReport(
        const VisitReport(
          visitId: 'v1',
          outcomeCode: 'ORDER_BOOKED',
          summary: 'Agreed Q4 volumes at the revised price.',
        ),
        submit: true,
      );

      final report = await api.visitReport('v1');
      expect(report!.isDraft, isFalse);
      expect(
        (await api.visits()).firstWhere((v) => v.id == 'v1').status,
        VisitStatus.reportSubmitted,
      );
    });

    test('cannot check in while already checked in somewhere else', () async {
      Visit make(String id, String name) => Visit(
            id: id,
            customerId: 'cust-1',
            customerName: name,
            siteId: 'site-1',
            siteName: 'Main Yard',
            visitTypeCode: 'SALES_CALL',
            checkInAt: DateTime.now(),
            status: VisitStatus.checkedIn,
          );

      await api.checkIn(make('v1', 'First customer'));

      // Two open visits would make time-on-site meaningless for both.
      expect(
        () => api.checkIn(make('v2', 'Second customer')),
        throwsA(isA<ApiException>()),
      );
    });

    test('check-out before check-in is refused', () async {
      final checkInAt = DateTime.now();
      await api.checkIn(Visit(
        id: 'v1',
        customerId: 'cust-1',
        customerName: 'Nagpur Distributors Pvt Ltd',
        siteId: 'site-1',
        siteName: 'Main Yard',
        visitTypeCode: 'SALES_CALL',
        checkInAt: checkInAt,
        status: VisitStatus.checkedIn,
      ));

      expect(
        () => api.checkOut('v1', checkInAt.subtract(const Duration(minutes: 10)), null),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('out-of-geofence check-in', () {
    Visit farAway({String? reasonCode}) => Visit(
          id: 'v-far',
          customerId: 'cust-1',
          customerName: 'Nagpur Distributors Pvt Ltd',
          siteId: 'site-1',
          siteName: 'Main Yard',
          visitTypeCode: 'SALES_CALL',
          checkInAt: DateTime.now(),
          status: VisitStatus.checkedIn,
          isOutOfGeofence: true,
          outOfFenceReasonCode: reasonCode,
        );

    test('is refused without a reason', () async {
      expect(() => api.checkIn(farAway()), throwsA(isA<ApiException>()));
    });

    test('is allowed with a reason, and flagged rather than blocked', () async {
      // Refusing it outright would strand reps whose recorded customer location is wrong.
      final visit = await api.checkIn(farAway(reasonCode: 'WRONG_LOCATION_ON_FILE'));
      expect(visit.isOutOfGeofence, isTrue);
      expect(visit.outOfFenceReasonCode, 'WRONG_LOCATION_ON_FILE');
    });
  });

  group('visit reports', () {
    test('submitting requires an outcome and a summary', () async {
      await api.checkIn(Visit(
        id: 'v1',
        customerId: 'cust-1',
        customerName: 'Nagpur Distributors Pvt Ltd',
        siteId: 'site-1',
        siteName: 'Main Yard',
        visitTypeCode: 'SALES_CALL',
        checkInAt: DateTime.now(),
        status: VisitStatus.checkedIn,
      ));

      expect(
        () => api.saveVisitReport(const VisitReport(visitId: 'v1'), submit: true),
        throwsA(isA<ApiException>()),
      );

      // A draft has no such requirement: half-written notes must never be lost.
      final draft = await api.saveVisitReport(
        const VisitReport(visitId: 'v1', summary: 'partial'),
        submit: false,
      );
      expect(draft.isDraft, isTrue);
    });

    test('an outcome that needs a follow-up date will not submit without one', () async {
      await api.checkIn(Visit(
        id: 'v1',
        customerId: 'cust-1',
        customerName: 'Nagpur Distributors Pvt Ltd',
        siteId: 'site-1',
        siteName: 'Main Yard',
        visitTypeCode: 'SALES_CALL',
        checkInAt: DateTime.now(),
        status: VisitStatus.checkedIn,
      ));

      expect(
        () => api.saveVisitReport(
          const VisitReport(
            visitId: 'v1',
            outcomeCode: 'QUOTE_GIVEN',
            summary: 'Quoted for the annual contract.',
          ),
          submit: true,
        ),
        throwsA(isA<ApiException>()),
      );
    });

    test('a submitted report is immutable', () async {
      await api.checkIn(Visit(
        id: 'v1',
        customerId: 'cust-1',
        customerName: 'Nagpur Distributors Pvt Ltd',
        siteId: 'site-1',
        siteName: 'Main Yard',
        visitTypeCode: 'SALES_CALL',
        checkInAt: DateTime.now(),
        status: VisitStatus.checkedIn,
      ));

      await api.saveVisitReport(
        const VisitReport(
          visitId: 'v1',
          outcomeCode: 'INFO_ONLY',
          summary: 'Shared the new catalogue.',
        ),
        submit: true,
      );

      // A report that can be quietly rewritten afterwards is not evidence of anything.
      expect(
        () => api.saveVisitReport(
          const VisitReport(
            visitId: 'v1',
            outcomeCode: 'ORDER_BOOKED',
            summary: 'Actually they ordered.',
          ),
          submit: false,
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('expenses', () {
    Expense base({
      String category = 'MEALS',
      double amount = 250,
      List<String> attachments = const [],
      String? tourId,
      String? from,
      String? to,
    }) =>
        Expense(
          id: 'e1',
          categoryCode: category,
          expenseDate: DateTime.now(),
          amount: amount,
          status: ExpenseStatus.draft,
          attachmentIds: attachments,
          tourId: tourId,
          fromPlace: from,
          toPlace: to,
        );

    test('a draft saves with almost nothing filled in', () async {
      final saved = await api.saveExpense(base(), submit: false);
      expect(saved.status, ExpenseStatus.draft);
    });

    test('submitting enforces the receipt threshold for the category', () async {
      // Meals need a receipt above ₹300, not below.
      await api.saveExpense(base(amount: 250), submit: true);

      expect(
        () => api.saveExpense(base(amount: 900), submit: true),
        throwsA(isA<ApiException>()),
      );

      final withReceipt =
          await api.saveExpense(base(amount: 900, attachments: ['att-1']), submit: true);
      expect(withReceipt.status, ExpenseStatus.submitted);
    });

    test('rail travel needs a route and a tour', () async {
      expect(
        () => api.saveExpense(
            base(category: 'TRAVEL_RAIL', amount: 2450, attachments: ['a']),
            submit: true),
        throwsA(isA<ApiException>()),
      );

      final complete = await api.saveExpense(
        base(
          category: 'TRAVEL_RAIL',
          amount: 2450,
          attachments: ['a'],
          tourId: 'tour-1',
          from: 'Pune',
          to: 'Nagpur',
        ),
        submit: true,
      );
      expect(complete.status, ExpenseStatus.submitted);
    });

    test('an expense already sent to XInfo cannot be edited or deleted', () async {
      // Money has left the system; corrections are a new entry.
      final pushed = (await api.expenses()).firstWhere((e) => e.status == ExpenseStatus.pushed);

      expect(
        () => api.saveExpense(pushed.copyWith(amount: 999), submit: false),
        throwsA(isA<ApiException>()),
      );
      expect(() => api.deleteExpense(pushed.id), throwsA(isA<ApiException>()));
    });

    test('a future-dated expense is refused', () async {
      final future = Expense(
        id: 'e-future',
        categoryCode: 'MEALS',
        expenseDate: DateTime.now().add(const Duration(days: 5)),
        amount: 100,
        status: ExpenseStatus.draft,
      );
      expect(() => api.saveExpense(future, submit: false), throwsA(isA<ApiException>()));
    });

    test('duplicate candidates are surfaced, not blocked', () async {
      await api.saveExpense(base(amount: 500), submit: false);

      final second = Expense(
        id: 'e2',
        categoryCode: 'MEALS',
        expenseDate: DateTime.now(),
        amount: 500,
        status: ExpenseStatus.draft,
      );

      final duplicates = await api.duplicateCandidates(second);
      expect(duplicates, isNotEmpty);

      // Warned, then saved anyway: two identical meals on one day is entirely possible.
      final saved = await api.saveExpense(second, submit: false);
      expect(saved.status, ExpenseStatus.draft);
    });
  });

  group('shared receipts', () {
    test('a shared UPI screenshot arrives read, with a suggested category', () async {
      final item = await api.simulateSharedFile(
        fileName: 'upi_payment.jpg',
        sourceApp: 'com.google.android.apps.nbu.paisa.user',
      );

      expect(item.ocr, isNotNull);
      expect(item.ocr!.amount, greaterThan(0));
      expect(item.suggestedCategoryCode, isNotNull);
      expect(item.attachment.captureSource, CaptureSource.shareIntent);

      expect((await api.shareInbox()).map((i) => i.id), contains(item.id));
    });

    test('a shared ticket PDF is recognised as rail travel', () async {
      final item = await api.simulateSharedFile(
        fileName: 'irctc_ticket.pdf',
        sourceApp: 'com.whatsapp',
      );

      expect(item.attachment.isPdf, isTrue);
      expect(item.suggestedCategoryCode, 'TRAVEL_RAIL');
    });

    test('sharing works while offline — on-device OCR needs no network', () async {
      api.offline = true;

      final item = await api.simulateSharedFile(
        fileName: 'upi_payment.jpg',
        sourceApp: 'com.google.android.apps.nbu.paisa.user',
      );
      expect(item.ocr, isNotNull);
    });

    test('dismissing removes it from the inbox', () async {
      final item = await api.simulateSharedFile(fileName: 'x.jpg', sourceApp: 'app');
      await api.dismissShareInboxItem(item.id);
      expect((await api.shareInbox()).map((i) => i.id), isNot(contains(item.id)));
    });
  });

  group('tours', () {
    test('only one tour can be in progress at a time', () async {
      final planned = (await api.tours()).firstWhere((t) => t.status == TourStatus.planned);

      // The seeded Nagpur tour is already running.
      expect(() => api.startTour(planned.id), throwsA(isA<ApiException>()));
    });

    test('a tour cannot be finished with a visit still open', () async {
      await api.checkIn(Visit(
        id: 'v-open',
        tourId: 'tour-1',
        customerId: 'cust-1',
        customerName: 'Nagpur Distributors Pvt Ltd',
        siteId: 'site-1',
        siteName: 'Main Yard',
        visitTypeCode: 'SALES_CALL',
        checkInAt: DateTime.now(),
        status: VisitStatus.checkedIn,
      ));

      expect(() => api.completeTour('tour-1'), throwsA(isA<ApiException>()));

      await api.checkOut('v-open', DateTime.now(), null);
      final completed = await api.completeTour('tour-1');
      expect(completed.status, TourStatus.completed);
    });

    test('end date before start date is refused', () async {
      final tour = Tour(
        id: 't-bad',
        title: 'Backwards',
        plannedStartDate: DateTime.now(),
        plannedEndDate: DateTime.now().subtract(const Duration(days: 2)),
        status: TourStatus.planned,
      );
      expect(() => api.saveTour(tour), throwsA(isA<ApiException>()));
    });

    test('skipping a visit needs a reason, and a remark when the reason demands one',
        () async {
      final plan = (await api.visitPlans()).first;

      expect(() => api.skipVisitPlan(plan.id, 'NOT_A_REASON', null),
          throwsA(isA<ApiException>()));

      expect(() => api.skipVisitPlan(plan.id, 'PERSONAL_EMERGENCY', null),
          throwsA(isA<ApiException>()));

      final skipped =
          await api.skipVisitPlan(plan.id, 'CUSTOMER_UNAVAILABLE', null);
      expect(skipped.status, PlanStatus.skipped);
    });
  });

  group('field-created customers', () {
    test('a proposed customer is a prospect and is immediately visitable', () async {
      const draft = Customer(
        id: 'new-1',
        name: 'Wardha Traders',
        lifecycleStatus: AccountLifecycle.active, // whatever is asked for...
      );

      final created = await api.proposeCustomer(draft);

      // ...it lands as a prospect: XInfo owns the master.
      expect(created.lifecycleStatus, AccountLifecycle.prospect);
      expect(created.isVisitable, isTrue);
      expect(created.id, 'new-1', reason: 'the local id must survive approval unchanged');
    });

    test('a nameless customer is refused', () async {
      expect(
        () => api.proposeCustomer(
            const Customer(id: 'x', name: '  ', lifecycleStatus: AccountLifecycle.prospect)),
        throwsA(isA<ApiException>()),
      );
    });

    test('capturing a location in the field supersedes a geocoded one', () async {
      final before = (await api.customer('cust-3')).sites.first;
      expect(before.geoSource, GeoSource.geocoded);

      final after = await api.captureSiteLocation(
          before.id, const GeoPoint(18.5645, 73.7770), radiusM: 120);

      expect(after.geoSource, GeoSource.fieldCaptured);
      expect(after.geofenceRadiusM, 120);
    });
  });

  group('opportunities', () {
    test('a rep can create one in the field and it records its history', () async {
      final created = await api.createOpportunity(const Opportunity(
        id: 'opp-new',
        customerId: 'cust-2',
        customerName: 'Kothrud Hardware Stores',
        title: 'Festive season stock',
        stageCode: 'IDENTIFIED',
        estimatedValue: 90000,
      ));

      expect(created.repFieldsUpdatedAt, isNotNull);
      expect((await api.opportunityHistory('opp-new')), hasLength(1));
    });

    test('moving to a stage that demands a reason is refused without one', () async {
      final opportunity = (await api.opportunities()).first;

      expect(
        () => api.updateOpportunity(opportunity.copyWith(stageCode: 'LOST')),
        throwsA(isA<ApiException>()),
      );

      final lost = await api.updateOpportunity(
        opportunity.copyWith(stageCode: 'LOST'),
        reason: 'Lost on price to Sharma Enterprises',
        visitId: 'v1',
      );

      expect(lost.closedAt, isNotNull);

      // The change is attributed to the visit that caused it — that link is what turns
      // visit reports into pipeline analytics.
      final history = await api.opportunityHistory(opportunity.id);
      expect(history.first.visitId, 'v1');
      expect(history.first.fromStage, isNot('LOST'));
    });

    test('closed opportunities drop out of the open list', () async {
      final opportunity = (await api.opportunities()).first;
      await api.updateOpportunity(
        opportunity.copyWith(stageCode: 'WON'),
        reason: 'Order confirmed',
      );

      final open = await api.opportunities(openOnly: true);
      expect(open.map((o) => o.id), isNot(contains(opportunity.id)));

      final all = await api.opportunities(openOnly: false);
      expect(all.map((o) => o.id), contains(opportunity.id));
    });
  });

  group('customer 360', () {
    test('summarises orders, visits and pipeline for the pre-call briefing', () async {
      final summary = await api.customerSummary('cust-1');

      expect(summary.sales12m, greaterThan(0));
      expect(summary.openOpportunities, greaterThan(0));
      expect(summary.salesAsOf, isNotNull,
          reason: 'cached XInfo data must always carry its age');
    });

    test('sales history comes back newest first', () async {
      final history = await api.salesHistory('cust-1');
      expect(history.length, greaterThan(1));
      for (var i = 1; i < history.length; i++) {
        expect(history[i - 1].documentDate.isBefore(history[i].documentDate), isFalse);
      }
    });
  });

  group('journey', () {
    test('a manual event is recorded as certain', () async {
      final added = await api.addManualJourneyEvent(JourneyEvent(
        id: 'je-manual',
        type: JourneyEventType.departHome,
        occurredAt: DateTime.now().subtract(const Duration(hours: 3)),
        status: EventStatus.detected,
      ));

      expect(added.isManual, isTrue);
      expect(added.status, EventStatus.confirmed);
      expect(added.confidence, 1.0);
    });

    test('correcting an event keeps what was originally detected', () async {
      final now = DateTime.now();
      final events = await api.journeyEvents(
        from: now.subtract(const Duration(days: 3)),
        to: now.add(const Duration(days: 1)),
      );
      final target = events.firstWhere((e) => e.status == EventStatus.needsReview);
      final detectedAt = target.occurredAt;

      final corrected = await api.correctJourneyEvent(
        target.id,
        detectedAt.subtract(const Duration(minutes: 25)),
        'Phone woke up late — I arrived at 9:40',
      );

      expect(corrected.occurredAt, detectedAt.subtract(const Duration(minutes: 25)));
      expect(corrected.originalOccurredAt, detectedAt,
          reason: 'the original detection must survive the correction');
      expect(corrected.isManual, isTrue);
    });

    test('a correction without a reason is refused', () async {
      final now = DateTime.now();
      final events = await api.journeyEvents(
        from: now.subtract(const Duration(days: 3)),
        to: now.add(const Duration(days: 1)),
      );

      expect(
        () => api.correctJourneyEvent(events.first.id, DateTime.now(), '   '),
        throwsA(isA<ApiException>()),
      );
    });

    test('mileage is suggested from tracked travel, flagged as indicative', () async {
      final suggestion = await api.mileageSuggestion(DateTime.now());

      expect(suggestion, isNotNull);
      expect(suggestion!.travelMode, TravelMode.car);
      expect(suggestion.suggestedAmount, closeTo(38 * 9.0, 0.01));
    });
  });

  group('tracking', () {
    test('pausing needs a reason; resuming does not', () async {
      expect(() => api.setTrackingActive(false), throwsA(isA<ApiException>()));

      await api.setTrackingActive(false, pauseReasonCode: 'PERSONAL_BREAK');
      expect(await api.isTrackingActive(), isFalse);

      await api.setTrackingActive(true);
      expect(await api.isTrackingActive(), isTrue);
    });

    test('the health score reflects what is actually wrong', () async {
      final health = await api.trackingHealth();

      // The seed is deliberately imperfect so the fix flow is worth seeing.
      expect(health.score, lessThan(80));
      expect(health.issues, isNotEmpty);

      final fixed = await api.updateTrackingHealth(health.copyWith(
        locationPermission: 'ALWAYS',
        batteryOptimised: false,
        autostartConfigured: true,
        activityPermission: true,
      ));

      expect(fixed.score, 100);
      expect(fixed.issues, isEmpty);
    });
  });

  group('offline', () {
    test('every read and write fails as OfflineException, never silently', () async {
      api.offline = true;

      expect(() => api.customers(), throwsA(isA<OfflineException>()));
      expect(() => api.tours(), throwsA(isA<OfflineException>()));
      expect(
        () => api.saveExpense(
          Expense(
            id: 'e-off',
            categoryCode: 'MEALS',
            expenseDate: DateTime.now(),
            amount: 100,
            status: ExpenseStatus.draft,
          ),
          submit: false,
        ),
        throwsA(isA<OfflineException>()),
      );
    });

    test('coming back online restores normal behaviour', () async {
      api.offline = true;

      // await the failure before flipping the flag: the call resolves asynchronously, so
      // an un-awaited expectation would read the flag after it had already changed back.
      await expectLater(() => api.customers(), throwsA(isA<OfflineException>()));

      api.offline = false;
      expect(await api.customers(), isNotEmpty);
    });

    test('XInfo being down is a different failure from being offline', () async {
      // Online, but the CRM is unreachable: the expense is kept and retried, and the rep
      // is told something different from "you are offline".
      api.xinfoDown = true;

      expect(
        () => api.saveExpense(
          Expense(
            id: 'e-xinfo',
            categoryCode: 'MEALS',
            expenseDate: DateTime.now(),
            amount: 120,
            status: ExpenseStatus.draft,
          ),
          submit: true,
        ),
        throwsA(isA<ApiException>()),
      );

      final saved = (await api.expenses()).firstWhere((e) => e.id == 'e-xinfo');
      expect(saved.status, ExpenseStatus.pushFailed,
          reason: 'the expense must survive so it can be retried');
    });
  });
}
