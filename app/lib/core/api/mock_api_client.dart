import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';

import '../models/enums.dart';
import '../models/models.dart';
import 'api_client.dart';
import 'seed_data.dart';

/// In-memory backend, seeded with a realistic territory and a tour in progress.
///
/// It exists so the whole app can be used and tested before the API is built: every
/// screen writes through the same [ApiClient] contract the HTTP implementation will
/// satisfy. It also models two things a naive stub would not, because both change how
/// the UI must behave:
///
///  * **latency** — every call takes a beat, so loading states are real and get exercised;
///  * **connectivity** — [offline] makes calls throw [OfflineException], which is how the
///    outbox, pending badges and sync screen get tested without a network to unplug.
class MockApiClient implements ApiClient {
  MockApiClient({this.latency = const Duration(milliseconds: 120)}) {
    _seed();
  }

  final Duration latency;
  final _uuid = const Uuid();

  /// Flip from the Developer screen to exercise offline behaviour end to end.
  bool offline = false;

  /// Simulates XInfo being unreachable while the device is online — a different
  /// failure with a different response (queue and retry, not "you are offline").
  bool xinfoDown = false;

  late AppUser _user;
  late HomeLocation _home;

  final _customers = <String, Customer>{};
  final _opportunities = <String, Opportunity>{};
  final _opportunityHistory = <String, List<OpportunityStageChange>>{};
  final _salesHistory = <String, List<SalesHistoryItem>>{};
  final _tours = <String, Tour>{};
  final _plans = <String, VisitPlan>{};
  final _visits = <String, Visit>{};
  final _reports = <String, VisitReport>{};
  final _visitOpportunities = <String, List<String>>{};
  final _expenses = <String, Expense>{};
  final _attachments = <String, Attachment>{};
  final _shareInbox = <String, ShareInboxItem>{};
  final _journeyEvents = <String, JourneyEvent>{};
  final _segments = <String, JourneySegment>{};

  late TrackingHealth _health;
  bool _trackingActive = true;

  // ------------------------------------------------------------------ plumbing

  Future<T> _call<T>(T Function() body) async {
    await Future<void>.delayed(latency);
    if (offline) throw const OfflineException();
    return body();
  }

  String _id() => _uuid.v4();

  // ------------------------------------------------------------------ auth

  @override
  Future<AppUser> signIn({required String employeeCode, required String password}) async {
    await Future<void>.delayed(latency);
    if (employeeCode.trim().isEmpty) {
      throw ApiException('Enter your employee code',
          fieldErrors: {'employeeCode': 'Required'});
    }
    if (password.trim().length < 4) {
      throw ApiException('Password must be at least 4 characters',
          fieldErrors: {'password': 'Too short'});
    }
    return _user;
  }

  @override
  Future<AppUser> currentUser() => _call(() => _user);

  @override
  Future<void> updateHomeLocation(HomeLocation home) => _call(() {
        _home = home;
        _user = AppUser(
          id: _user.id,
          employeeCode: _user.employeeCode,
          fullName: _user.fullName,
          roles: _user.roles,
          email: _user.email,
          phone: _user.phone,
          grade: _user.grade,
          homeLocation: home,
          orgUnitName: _user.orgUnitName,
          managerName: _user.managerName,
        );
      });

  // ------------------------------------------------------------------ reference

  @override
  Future<List<VisitType>> visitTypes() => _call(() => SeedData.visitTypes);

  @override
  Future<List<VisitOutcome>> visitOutcomes() => _call(() => SeedData.visitOutcomes);

  @override
  Future<List<ReasonCode>> reasonCodes(String domain) =>
      _call(() => SeedData.reasonCodes.where((r) => r.domain == domain).toList());

  @override
  Future<List<ExpenseCategory>> expenseCategories() => _call(() => SeedData.expenseCategories);

  @override
  Future<List<OpportunityStage>> opportunityStages() => _call(() => SeedData.opportunityStages);

  @override
  Future<List<FormTemplate>> formTemplates() => _call(() => SeedData.formTemplates);

  // ------------------------------------------------------------------ customers

  @override
  Future<List<Customer>> customers({String? query}) => _call(() {
        final all = _customers.values.toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        if (query == null || query.trim().isEmpty) return all;
        final q = query.toLowerCase();
        return all.where((c) => c.name.toLowerCase().contains(q)).toList();
      });

  @override
  Future<Customer> customer(String id) => _call(() {
        final found = _customers[id];
        if (found == null) throw ApiException('Customer not found');
        return found;
      });

  @override
  Future<Customer360> customerSummary(String id) => _call(() {
        final c = _customers[id];
        if (c == null) throw ApiException('Customer not found');

        final visits = _visits.values.where((v) => v.customerId == id).toList();
        final sales = _salesHistory[id] ?? const [];
        final cutoff = DateTime.now().subtract(const Duration(days: 365));
        final open = _opportunities.values.where((o) =>
            o.customerId == id &&
            (SeedData.stageByCode(o.stageCode)?.isOpen ?? true) &&
            o.closedAt == null);

        return Customer360(
          customerId: id,
          name: c.name,
          lifecycleStatus: c.lifecycleStatus,
          category: c.category,
          siteCount: c.sites.length,
          lastVisitAt: visits.isEmpty
              ? null
              : visits.map((v) => v.checkInAt).reduce((a, b) => a.isAfter(b) ? a : b),
          visits90d: visits
              .where((v) => v.checkInAt.isAfter(DateTime.now().subtract(const Duration(days: 90))))
              .length,
          sales12m: sales
              .where((s) => s.documentDate.isAfter(cutoff) && s.documentType == 'ORDER')
              .fold(0.0, (sum, s) => sum + s.amount),
          lastOrderDate: sales.isEmpty
              ? null
              : sales.map((s) => s.documentDate).reduce((a, b) => a.isAfter(b) ? a : b),
          openOpportunities: open.length,
          openPipelineValue: open.fold(0.0, (sum, o) => sum + (o.estimatedValue ?? 0)),
          salesAsOf: DateTime.now().subtract(const Duration(hours: 3)),
        );
      });

  @override
  Future<List<SalesHistoryItem>> salesHistory(String customerId) => _call(() {
        final list = List<SalesHistoryItem>.from(_salesHistory[customerId] ?? const [])
          ..sort((a, b) => b.documentDate.compareTo(a.documentDate));
        return list;
      });

  @override
  Future<List<Visit>> customerVisits(String customerId) => _call(() {
        final list = _visits.values.where((v) => v.customerId == customerId).toList()
          ..sort((a, b) => b.checkInAt.compareTo(a.checkInAt));
        return list;
      });

  @override
  Future<Customer> proposeCustomer(Customer draft) => _call(() {
        if (draft.name.trim().isEmpty) {
          throw ApiException('Customer name is required', fieldErrors: {'name': 'Required'});
        }
        // The local id never changes when XInfo approves — only xinfoId is filled in —
        // so visits recorded against a prospect stay attached with no id rewriting.
        final created = draft.copyWith(lifecycleStatus: AccountLifecycle.prospect);
        _customers[created.id] = created;
        return created;
      });

  @override
  Future<CustomerSite> addSite(CustomerSite site) => _call(() {
        final customer = _customers[site.customerId];
        if (customer == null) throw ApiException('Customer not found');
        _customers[customer.id] = customer.copyWith(sites: [...customer.sites, site]);
        return site;
      });

  @override
  Future<CustomerContact> addContact(CustomerContact contact) => _call(() {
        final customer = _customers[contact.customerId];
        if (customer == null) throw ApiException('Customer not found');
        _customers[customer.id] = customer.copyWith(contacts: [...customer.contacts, contact]);
        return contact;
      });

  @override
  Future<CustomerSite> captureSiteLocation(String siteId, GeoPoint point, {int? radiusM}) =>
      _call(() {
        for (final customer in _customers.values) {
          final index = customer.sites.indexWhere((s) => s.id == siteId);
          if (index < 0) continue;

          // Field capture supersedes a geocode: the rep is standing there.
          final updated = customer.sites[index].copyWith(
            point: point,
            geoSource: GeoSource.fieldCaptured,
            geofenceRadiusM: radiusM,
          );
          final sites = [...customer.sites]..[index] = updated;
          _customers[customer.id] = customer.copyWith(sites: sites);
          return updated;
        }
        throw ApiException('Site not found');
      });

  // ------------------------------------------------------------------ opportunities

  @override
  Future<List<Opportunity>> opportunities({String? customerId, bool openOnly = true}) =>
      _call(() {
        var list = _opportunities.values.toList();
        if (customerId != null) list = list.where((o) => o.customerId == customerId).toList();
        if (openOnly) {
          list = list
              .where((o) => o.closedAt == null && (SeedData.stageByCode(o.stageCode)?.isOpen ?? true))
              .toList();
        }
        list.sort((a, b) {
          final aDate = a.expectedCloseDate ?? DateTime(2100);
          final bDate = b.expectedCloseDate ?? DateTime(2100);
          return aDate.compareTo(bDate);
        });
        return list;
      });

  @override
  Future<Opportunity> createOpportunity(Opportunity draft) => _call(() {
        if (draft.title.trim().isEmpty) {
          throw ApiException('Give the opportunity a title', fieldErrors: {'title': 'Required'});
        }
        final created = draft.copyWith(repFieldsUpdatedAt: DateTime.now());
        _opportunities[created.id] = created;
        _opportunityHistory[created.id] = [
          OpportunityStageChange(
            toStage: created.stageCode,
            changedAt: DateTime.now(),
            valueAfter: created.estimatedValue,
            reason: 'Created in the field',
          ),
        ];
        return created;
      });

  @override
  Future<Opportunity> updateOpportunity(Opportunity updated, {String? visitId, String? reason}) =>
      _call(() {
        final existing = _opportunities[updated.id];
        if (existing == null) throw ApiException('Opportunity not found');

        final stage = SeedData.stageByCode(updated.stageCode);
        if (stage != null && stage.requiresReason && (reason == null || reason.trim().isEmpty)) {
          throw ApiException('A reason is required to move to ${stage.name}',
              fieldErrors: {'reason': 'Required'});
        }

        final closing = stage != null && !stage.isOpen;
        final saved = updated.copyWith(
          repFieldsUpdatedAt: DateTime.now(),
          closedAt: closing ? (updated.closedAt ?? DateTime.now()) : null,
        );
        _opportunities[saved.id] = saved;

        if (existing.stageCode != saved.stageCode ||
            existing.estimatedValue != saved.estimatedValue) {
          (_opportunityHistory[saved.id] ??= []).add(OpportunityStageChange(
            fromStage: existing.stageCode,
            toStage: saved.stageCode,
            changedAt: DateTime.now(),
            visitId: visitId,
            valueBefore: existing.estimatedValue,
            valueAfter: saved.estimatedValue,
            reason: reason,
          ));
        }
        return saved;
      });

  @override
  Future<List<OpportunityStageChange>> opportunityHistory(String opportunityId) => _call(() {
        final list = List<OpportunityStageChange>.from(_opportunityHistory[opportunityId] ?? const [])
          ..sort((a, b) => b.changedAt.compareTo(a.changedAt));
        return list;
      });

  // ------------------------------------------------------------------ planning

  @override
  Future<List<Tour>> tours() => _call(() {
        final list = _tours.values.toList()
          ..sort((a, b) => b.plannedStartDate.compareTo(a.plannedStartDate));
        return list;
      });

  @override
  Future<Tour> tour(String id) => _call(() {
        final found = _tours[id];
        if (found == null) throw ApiException('Tour not found');
        return found;
      });

  @override
  Future<Tour> saveTour(Tour tour) => _call(() {
        if (tour.title.trim().isEmpty) {
          throw ApiException('Give the tour a title', fieldErrors: {'title': 'Required'});
        }
        if (tour.plannedEndDate.isBefore(tour.plannedStartDate)) {
          throw ApiException('End date cannot be before the start date',
              fieldErrors: {'plannedEndDate': 'Must be on or after the start date'});
        }
        _tours[tour.id] = tour;
        return tour;
      });

  @override
  Future<Tour> startTour(String id) => _call(() {
        final tour = _tours[id];
        if (tour == null) throw ApiException('Tour not found');

        // At most one tour in progress: the invariant from docs/02 §2.1.
        final other = _tours.values
            .where((t) => t.id != id && t.status == TourStatus.inProgress)
            .toList();
        if (other.isNotEmpty) {
          throw ApiException('"${other.first.title}" is still in progress. Finish it first.');
        }

        final started = tour.copyWith(status: TourStatus.inProgress, actualStartAt: DateTime.now());
        _tours[id] = started;
        _trackingActive = true;
        return started;
      });

  @override
  Future<Tour> completeTour(String id) => _call(() {
        final tour = _tours[id];
        if (tour == null) throw ApiException('Tour not found');

        final openVisit = _visits.values.firstWhereOrNull((v) => v.tourId == id && v.isOpen);
        if (openVisit != null) {
          throw ApiException('Check out of ${openVisit.customerName} before finishing the tour');
        }

        final done = tour.copyWith(status: TourStatus.completed, actualEndAt: DateTime.now());
        _tours[id] = done;
        return done;
      });

  @override
  Future<List<VisitPlan>> visitPlans({DateTime? from, DateTime? to, String? tourId}) => _call(() {
        var list = _plans.values.toList();
        if (tourId != null) list = list.where((p) => p.tourId == tourId).toList();
        if (from != null) {
          list = list.where((p) => !p.plannedDate.isBefore(_dateOnly(from))).toList();
        }
        if (to != null) {
          list = list.where((p) => !p.plannedDate.isAfter(_dateOnly(to))).toList();
        }
        list.sort((a, b) {
          final byDate = a.plannedDate.compareTo(b.plannedDate);
          return byDate != 0 ? byDate : a.seq.compareTo(b.seq);
        });
        return list;
      });

  @override
  Future<VisitPlan> saveVisitPlan(VisitPlan plan) => _call(() {
        _plans[plan.id] = plan;
        return plan;
      });

  @override
  Future<VisitPlan> skipVisitPlan(String planId, String reasonCode, String? remark) => _call(() {
        final plan = _plans[planId];
        if (plan == null) throw ApiException('Plan not found');

        final reason = SeedData.reasonCodes
            .where((r) => r.domain == 'VISIT_SKIP' && r.code == reasonCode)
            .firstOrNull;
        if (reason == null) throw ApiException('Pick a reason');
        if (reason.requiresRemark && (remark == null || remark.trim().isEmpty)) {
          throw ApiException('${reason.name} needs a short explanation',
              fieldErrors: {'remark': 'Required'});
        }

        final skipped = plan.copyWith(
          status: PlanStatus.skipped,
          skipReasonCode: reasonCode,
          skipRemark: remark,
        );
        _plans[planId] = skipped;
        return skipped;
      });

  // ------------------------------------------------------------------ visits

  @override
  Future<List<Visit>> visits({DateTime? from, DateTime? to}) => _call(() {
        var list = _visits.values.toList();
        if (from != null) list = list.where((v) => !v.checkInAt.isBefore(from)).toList();
        if (to != null) list = list.where((v) => !v.checkInAt.isAfter(to)).toList();
        list.sort((a, b) => b.checkInAt.compareTo(a.checkInAt));
        return list;
      });

  @override
  Future<Visit> checkIn(Visit visit) => _call(() {
        final open = _visits.values.where((v) => v.isOpen).toList();
        if (open.isNotEmpty) {
          throw ApiException('You are still checked in at ${open.first.customerName}');
        }

        // Out-of-geofence check-in is allowed but must be explained — it is flagged for
        // the manager, never refused (docs/02 §2.2).
        if (visit.isOutOfGeofence &&
            (visit.outOfFenceReasonCode == null || visit.outOfFenceReasonCode!.isEmpty)) {
          throw ApiException(
            'You are outside the customer location — choose a reason to continue',
            fieldErrors: {'outOfFenceReasonCode': 'Required'},
          );
        }

        _visits[visit.id] = visit;
        if (visit.visitPlanId != null && _plans.containsKey(visit.visitPlanId)) {
          _plans[visit.visitPlanId!] =
              _plans[visit.visitPlanId!]!.copyWith(status: PlanStatus.completed);
        }

        _journeyEvents[_id()] = JourneyEvent(
          id: _id(),
          type: JourneyEventType.arriveCustomer,
          occurredAt: visit.checkInAt,
          status: EventStatus.confirmed,
          point: visit.checkInPoint,
          placeName: visit.siteName,
          customerId: visit.customerId,
          method: 'CHECKIN',
        );
        return visit;
      });

  @override
  Future<Visit> checkOut(String visitId, DateTime at, GeoPoint? point) => _call(() {
        final visit = _visits[visitId];
        if (visit == null) throw ApiException('Visit not found');
        if (at.isBefore(visit.checkInAt)) {
          throw ApiException('Check-out cannot be before check-in',
              fieldErrors: {'checkOutAt': 'Must be after check-in'});
        }

        final closed = visit.copyWith(
          status: VisitStatus.checkedOut,
          checkOutAt: at,
          checkOutPoint: point,
        );
        _visits[visitId] = closed;

        _journeyEvents[_id()] = JourneyEvent(
          id: _id(),
          type: JourneyEventType.departCustomer,
          occurredAt: at,
          status: EventStatus.confirmed,
          point: point,
          placeName: visit.siteName,
          customerId: visit.customerId,
          method: 'CHECKIN',
        );
        return closed;
      });

  @override
  Future<VisitReport?> visitReport(String visitId) => _call(() => _reports[visitId]);

  @override
  Future<VisitReport> saveVisitReport(VisitReport report, {required bool submit}) => _call(() {
        final existing = _reports[report.visitId];
        if (existing != null && !existing.isDraft) {
          // Submitted reports are immutable; corrections go through an amendment.
          throw ApiException('This report was already submitted. Use "Amend" to change it.');
        }
        if (submit) {
          if (report.outcomeCode == null || report.outcomeCode!.isEmpty) {
            throw ApiException('Choose an outcome before submitting',
                fieldErrors: {'outcomeCode': 'Required'});
          }
          if ((report.summary ?? '').trim().length < 5) {
            throw ApiException('Add a short summary of the discussion',
                fieldErrors: {'summary': 'Required'});
          }
          final outcome = SeedData.visitOutcomes
              .where((o) => o.code == report.outcomeCode)
              .firstOrNull;
          if (outcome != null && outcome.requiresFollowUp && report.followUpDate == null) {
            throw ApiException('"${outcome.name}" needs a follow-up date',
                fieldErrors: {'followUpDate': 'Required'});
          }
        }

        final saved = report.copyWith(
          isDraft: !submit,
          submittedAt: submit ? DateTime.now() : null,
        );
        _reports[report.visitId] = saved;

        if (submit && _visits.containsKey(report.visitId)) {
          _visits[report.visitId] =
              _visits[report.visitId]!.copyWith(status: VisitStatus.reportSubmitted);
        }
        return saved;
      });

  @override
  Future<void> linkVisitOpportunities(String visitId, List<String> opportunityIds) =>
      _call(() => _visitOpportunities[visitId] = opportunityIds);

  @override
  Future<List<String>> visitOpportunityIds(String visitId) =>
      _call(() => _visitOpportunities[visitId] ?? const []);

  // ------------------------------------------------------------------ expenses

  @override
  Future<List<Expense>> expenses({DateTime? from, DateTime? to}) => _call(() {
        var list = _expenses.values.toList();
        if (from != null) {
          list = list.where((e) => !e.expenseDate.isBefore(_dateOnly(from))).toList();
        }
        if (to != null) list = list.where((e) => !e.expenseDate.isAfter(_dateOnly(to))).toList();
        list.sort((a, b) => b.expenseDate.compareTo(a.expenseDate));
        return list;
      });

  @override
  Future<Expense> saveExpense(Expense expense, {required bool submit}) => _call(() {
        final existing = _expenses[expense.id];
        if (existing != null && !existing.status.isEditable) {
          throw ApiException(
              'This expense has gone to XInfo and can no longer be edited. Add a new entry instead.');
        }

        final category = SeedData.expenseCategories
            .where((c) => c.code == expense.categoryCode)
            .firstOrNull;
        if (category == null) {
          throw ApiException('Choose a category', fieldErrors: {'categoryCode': 'Required'});
        }
        if (expense.amount <= 0) {
          throw ApiException('Enter an amount', fieldErrors: {'amount': 'Must be more than zero'});
        }
        if (expense.expenseDate.isAfter(DateTime.now().add(const Duration(days: 1)))) {
          throw ApiException('Expense date cannot be in the future',
              fieldErrors: {'expenseDate': 'Cannot be in the future'});
        }

        if (submit) {
          if (category.receiptRequiredFor(expense.amount) && expense.attachmentIds.isEmpty) {
            throw ApiException('${category.name} needs a receipt above ₹${category.receiptThreshold?.toStringAsFixed(0) ?? '0'}',
                fieldErrors: {'attachments': 'Receipt required'});
          }
          if (category.requiresRoute &&
              ((expense.fromPlace ?? '').isEmpty || (expense.toPlace ?? '').isEmpty)) {
            throw ApiException('Enter the from and to places',
                fieldErrors: {'fromPlace': 'Required', 'toPlace': 'Required'});
          }
          if (category.requiresTour && expense.tourId == null) {
            throw ApiException('Link this expense to a tour',
                fieldErrors: {'tourId': 'Required'});
          }
          if (xinfoDown) {
            // Online but XInfo unreachable: the outbox holds it and retries. Different
            // failure, different message — and no data is lost either way.
            _expenses[expense.id] = expense.copyWith(status: ExpenseStatus.pushFailed);
            throw ApiException('Saved, but XInfo is unreachable. It will be sent automatically.');
          }
        }

        final saved = expense.copyWith(
          status: submit ? ExpenseStatus.submitted : ExpenseStatus.draft,
          submittedAt: submit ? DateTime.now() : null,
        );
        _expenses[saved.id] = saved;
        return saved;
      });

  @override
  Future<void> deleteExpense(String id) => _call(() {
        final expense = _expenses[id];
        if (expense == null) return;
        if (!expense.status.isEditable) {
          throw ApiException('Sent expenses cannot be deleted');
        }
        _expenses.remove(id);
      });

  @override
  Future<List<Expense>> duplicateCandidates(Expense expense) => _call(() {
        // Same rule as expense.fn_find_duplicates: same amount within a couple of days.
        return _expenses.values.where((e) {
          if (e.id == expense.id) return false;
          if (e.amount != expense.amount) return false;
          final days = e.expenseDate.difference(expense.expenseDate).inDays.abs();
          return days <= 2;
        }).toList();
      });

  @override
  Future<MileageSuggestion?> mileageSuggestion(DateTime date, {String? tourId}) => _call(() {
        final travel = _segments.values.where((s) =>
            s.isTravel &&
            _sameDay(s.startedAt, date) &&
            (s.travelMode == TravelMode.car || s.travelMode == TravelMode.twoWheeler));
        if (travel.isEmpty) return null;

        final metres = travel.fold<int>(0, (sum, s) => sum + s.distanceM);
        final estimated = travel.where((s) => s.isEstimated).fold<int>(0, (s2, s) => s2 + s.distanceM);
        final mode = travel.first.travelMode;
        final rate = mode == TravelMode.car ? 9.0 : 3.5;

        return MileageSuggestion(
          distanceKm: metres / 1000,
          estimatedPortionKm: estimated / 1000,
          travelMode: mode,
          ratePerKm: rate,
          suggestedAmount: (metres / 1000) * rate,
        );
      });

  @override
  Future<List<ShareInboxItem>> shareInbox() => _call(() {
        final list = _shareInbox.values.where((i) => i.status == 'PENDING').toList()
          ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
        return list;
      });

  @override
  Future<ShareInboxItem> simulateSharedFile({
    required String fileName,
    required String sourceApp,
  }) async {
    await Future<void>.delayed(latency);

    // Stands in for the Android share sheet / iOS share extension until the plugin is
    // wired. On-device OCR runs offline, so this path deliberately works while offline.
    final isPdf = fileName.toLowerCase().endsWith('.pdf');
    final attachment = Attachment(
      id: _id(),
      fileName: fileName,
      mimeType: isPdf ? 'application/pdf' : 'image/jpeg',
      sizeBytes: isPdf ? 284112 : 184320,
      captureSource: CaptureSource.shareIntent,
      sourceApp: sourceApp,
      capturedAt: DateTime.now(),
    );
    _attachments[attachment.id] = attachment;

    final ocr = _fakeOcr(sourceApp, isPdf);
    final item = ShareInboxItem(
      id: _id(),
      receivedAt: DateTime.now(),
      attachment: attachment,
      sourceApp: sourceApp,
      ocr: ocr,
      suggestedCategoryCode: isPdf ? 'TRAVEL_RAIL' : _categoryForMerchant(ocr.merchantName),
    );
    _shareInbox[item.id] = item;
    return item;
  }

  OcrResult _fakeOcr(String sourceApp, bool isPdf) {
    final merchants = ['IRCTC', 'Ola Cabs', 'Hotel Centre Point', 'Indian Oil', 'Cafe Madras'];
    final rng = math.Random(sourceApp.hashCode ^ _shareInbox.length);
    final merchant = isPdf ? 'IRCTC' : merchants[rng.nextInt(merchants.length)];
    final amount = isPdf ? 2450.0 : (rng.nextInt(180) + 20) * 10.0;

    return OcrResult(
      docType: isPdf ? 'TICKET_PDF' : 'UPI_SCREENSHOT',
      amount: amount,
      txnDate: DateTime.now().subtract(Duration(hours: rng.nextInt(30))),
      merchantName: merchant,
      paymentRef: '4213${rng.nextInt(9000) + 1000}9910',
      paymentMode: isPdf ? 'NETBANKING' : 'UPI',
      confidence: 0.72 + rng.nextDouble() * 0.25,
    );
  }

  String _categoryForMerchant(String? merchant) => switch (merchant) {
        'Ola Cabs' => 'TRAVEL_TAXI',
        'Hotel Centre Point' => 'LODGING',
        'Indian Oil' => 'FUEL',
        'Cafe Madras' => 'MEALS',
        _ => 'MISC',
      };

  @override
  Future<void> dismissShareInboxItem(String id) => _call(() {
        final item = _shareInbox[id];
        if (item == null) return;
        _shareInbox[id] = ShareInboxItem(
          id: item.id,
          receivedAt: item.receivedAt,
          attachment: item.attachment,
          sourceApp: item.sourceApp,
          sharedText: item.sharedText,
          ocr: item.ocr,
          suggestedCategoryCode: item.suggestedCategoryCode,
          status: 'DISMISSED',
        );
      });

  @override
  Future<Attachment> addAttachment(Attachment attachment) => _call(() {
        _attachments[attachment.id] = attachment;
        return attachment;
      });

  @override
  Future<List<Attachment>> attachments() => _call(() => _attachments.values.toList());

  // ------------------------------------------------------------------ journey

  @override
  Future<List<JourneyEvent>> journeyEvents({required DateTime from, required DateTime to}) =>
      _call(() {
        final list = _journeyEvents.values
            .where((e) => !e.occurredAt.isBefore(from) && !e.occurredAt.isAfter(to))
            .toList()
          ..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
        return list;
      });

  @override
  Future<List<JourneySegment>> journeySegments({required DateTime from, required DateTime to}) =>
      _call(() {
        final list = _segments.values
            .where((s) => !s.startedAt.isBefore(from) && !s.startedAt.isAfter(to))
            .toList()
          ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
        return list;
      });

  @override
  Future<List<DaySummary>> daySummaries({required DateTime from, required DateTime to}) =>
      _call(() {
        final days = <DateTime, DaySummary>{};
        for (var d = _dateOnly(from);
            !d.isAfter(_dateOnly(to));
            d = d.add(const Duration(days: 1))) {
          final events = _journeyEvents.values.where((e) => _sameDay(e.occurredAt, d)).toList();
          final segs = _segments.values.where((s) => _sameDay(s.startedAt, d)).toList();
          final visitsToday = _visits.values.where((v) => _sameDay(v.checkInAt, d)).toList();
          final plansToday = _plans.values.where((p) => _sameDay(p.plannedDate, d)).toList();

          if (events.isEmpty && segs.isEmpty && visitsToday.isEmpty && plansToday.isEmpty) {
            continue;
          }

          days[d] = DaySummary(
            localDate: d,
            firstDepartureAt: events
                .where((e) => e.type == JourneyEventType.departHome)
                .map((e) => e.occurredAt)
                .firstOrNull,
            lastArrivalAt: events
                .where((e) => e.type == JourneyEventType.arriveHome)
                .map((e) => e.occurredAt)
                .lastOrNull,
            totalDistanceM: segs.fold(0, (sum, s) => sum + s.distanceM),
            travelTimeS: segs
                .where((s) => s.isTravel)
                .fold(0, (sum, s) => sum + (s.duration?.inSeconds ?? 0)),
            customerTimeS: visitsToday.fold(
                0, (sum, v) => sum + (v.duration?.inSeconds ?? 0)),
            visitsPlanned: plansToday.length,
            visitsCompleted: visitsToday.length,
            trackingCoveragePct: segs.isEmpty ? null : 92,
            attendanceStatus: segs.any((s) => s.isTravel) ? 'TRAVEL' : 'WORKING',
          );
        }
        return days.values.toList()..sort((a, b) => b.localDate.compareTo(a.localDate));
      });

  @override
  Future<JourneyEvent> addManualJourneyEvent(JourneyEvent event) => _call(() {
        // A manual entry is an anchor: the engine rebuilds around it and never overwrites it.
        final saved = event.copyWith(status: EventStatus.confirmed, isManual: true, confidence: 1.0);
        _journeyEvents[saved.id] = saved;
        return saved;
      });

  @override
  Future<JourneyEvent> correctJourneyEvent(String eventId, DateTime occurredAt, String reason) =>
      _call(() {
        final event = _journeyEvents[eventId];
        if (event == null) throw ApiException('Event not found');
        if (reason.trim().isEmpty) {
          throw ApiException('Say why you are changing this', fieldErrors: {'reason': 'Required'});
        }

        // The original detection is preserved: without it you cannot audit the correction
        // or improve the algorithm.
        final corrected = event.copyWith(
          occurredAt: occurredAt,
          status: EventStatus.confirmed,
          isManual: true,
          confidence: 1.0,
          originalOccurredAt: event.originalOccurredAt ?? event.occurredAt,
        );
        _journeyEvents[eventId] = corrected;
        return corrected;
      });

  @override
  Future<JourneyEvent> confirmJourneyEvent(String eventId) => _call(() {
        final event = _journeyEvents[eventId];
        if (event == null) throw ApiException('Event not found');
        final confirmed = event.copyWith(status: EventStatus.confirmed, confidence: 1.0);
        _journeyEvents[eventId] = confirmed;
        return confirmed;
      });

  @override
  Future<TrackingHealth> trackingHealth() => _call(() => _health);

  @override
  Future<TrackingHealth> updateTrackingHealth(TrackingHealth health) => _call(() {
        _health = health;
        return _health;
      });

  @override
  Future<bool> isTrackingActive() => _call(() => _trackingActive);

  @override
  Future<void> setTrackingActive(bool active, {String? pauseReasonCode}) => _call(() {
        if (!active && (pauseReasonCode == null || pauseReasonCode.isEmpty)) {
          throw ApiException('Choose a reason for pausing',
              fieldErrors: {'reasonCode': 'Required'});
        }
        _trackingActive = active;
      });

  // ------------------------------------------------------------------ seed

  void _seed() {
    _home = SeedData.homeLocation;
    _user = SeedData.user(_home);
    _health = SeedData.trackingHealth;

    for (final customer in SeedData.customers) {
      _customers[customer.id] = customer;
    }
    for (final entry in SeedData.salesHistory.entries) {
      _salesHistory[entry.key] = entry.value;
    }
    for (final opportunity in SeedData.opportunities) {
      _opportunities[opportunity.id] = opportunity;
      _opportunityHistory[opportunity.id] = [
        OpportunityStageChange(
          toStage: opportunity.stageCode,
          changedAt: DateTime.now().subtract(const Duration(days: 12)),
          valueAfter: opportunity.estimatedValue,
        ),
      ];
    }
    for (final tour in SeedData.tours) {
      _tours[tour.id] = tour;
    }
    for (final plan in SeedData.visitPlans) {
      _plans[plan.id] = plan;
    }
    for (final visit in SeedData.visits) {
      _visits[visit.id] = visit;
    }
    for (final expense in SeedData.expenses) {
      _expenses[expense.id] = expense;
    }
    for (final event in SeedData.journeyEvents) {
      _journeyEvents[event.id] = event;
    }
    for (final segment in SeedData.journeySegments) {
      _segments[segment.id] = segment;
    }
  }
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
