// The first real ApiClient implementation, talking to the ASP.NET Core backend built over
// several sessions (src/XMobile.Api). Not the default provider yet — see api/api_client.dart and
// app/README.md's swap mechanism. Opportunities, expenses/attachments, and most reference data
// still have no backend at all; those throw a clear ApiException rather than pretending to work.
// See docs/10-roadmap.md §6 for the up-to-date list of what's backed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/enums.dart';
import '../models/models.dart';
import 'api_client.dart';
import 'token_store.dart';

/// "yyyy-MM-dd" — how the backend's `DateOnly` query params/fields expect dates.
String _dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class HttpApiClient implements ApiClient {
  HttpApiClient({required this.baseUrl, http.Client? httpClient, TokenStore? tokenStore})
      : _http = httpClient ?? http.Client(),
        _tokenStore = tokenStore ?? SecureTokenStore();

  /// No trailing slash, e.g. `https://xmobile.internal/api`.
  final String baseUrl;
  final http.Client _http;
  final TokenStore _tokenStore;

  /// Cached after the first resolution — see `_resolveDeviceId`/`_ensureTokenLoaded` below,
  /// which lazily pull the persisted values out of `_tokenStore` (a real device keeps both
  /// stable across restarts now; see token_store.dart).
  String? _deviceId;
  String? _accessToken;
  bool _tokenLoaded = false;

  static const _timeout = Duration(seconds: 20);

  // ---------------------------------------------------------------- request plumbing

  Future<String> _resolveDeviceId() async => _deviceId ??= await _tokenStore.deviceId();

  /// Loads the persisted token (if any) exactly once per client instance — a client constructed
  /// against an already-signed-in device picks the session back up without a fresh `signIn`.
  Future<void> _ensureTokenLoaded() async {
    if (_tokenLoaded) return;
    _accessToken = await _tokenStore.readToken();
    _tokenLoaded = true;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final clean = {...?query}..removeWhere((_, v) => v.isEmpty);
    return Uri.parse('$baseUrl$path').replace(queryParameters: clean.isEmpty ? null : clean);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      };

  /// Centralises auth headers, JSON encode/decode and error mapping for every call below.
  /// `notFoundAsNull` is for the one endpoint (`visitReport`) whose "nothing here yet" is a
  /// normal, non-exceptional outcome rather than a real error.
  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool notFoundAsNull = false,
  }) async {
    await _ensureTokenLoaded();
    final uri = _uri(path, query);
    final encodedBody = body == null ? null : jsonEncode(body);
    http.Response response;
    try {
      switch (method) {
        case 'GET':
          response = await _http.get(uri, headers: _headers).timeout(_timeout);
        case 'POST':
          response = await _http.post(uri, headers: _headers, body: encodedBody).timeout(_timeout);
        case 'PUT':
          response = await _http.put(uri, headers: _headers, body: encodedBody).timeout(_timeout);
        case 'PATCH':
          response = await _http.patch(uri, headers: _headers, body: encodedBody).timeout(_timeout);
        default:
          throw ArgumentError('Unsupported HTTP method: $method');
      }
    } on SocketException {
      throw const OfflineException();
    } on TimeoutException {
      throw const OfflineException();
    } on http.ClientException {
      throw const OfflineException();
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      return jsonDecode(response.body);
    }

    if (notFoundAsNull && response.statusCode == 404) {
      return null;
    }

    throw _errorFor(response);
  }

  /// The server's RFC 9457 `application/problem+json` shape
  /// (`{title, detail, errors: {field: [messages]}}`) — see ApiExceptionHandling.cs.
  ApiException _errorFor(http.Response response) {
    Map<String, dynamic>? problem;
    if (response.body.isNotEmpty) {
      try {
        problem = jsonDecode(response.body) as Map<String, dynamic>;
      } on FormatException {
        problem = null;
      }
    }

    final fieldErrors = <String, String>{};
    (problem?['errors'] as Map<String, dynamic>?)?.forEach((key, value) {
      if (value is List && value.isNotEmpty) fieldErrors[key] = value.first.toString();
    });

    final message = (problem?['detail'] as String?) ??
        (problem?['title'] as String?) ??
        'Request failed (${response.statusCode})';
    return ApiException(message, fieldErrors: fieldErrors);
  }

  Never _notSupported() => throw ApiException('Not yet available in the live backend');

  // ---------------------------------------------------------------- auth

  @override
  Future<AppUser> signIn({required String employeeCode, required String password}) async {
    // Dev-login only needs employeeCode (see XMobile.Identity.Contracts.DevLoginRequest) — a
    // real Keycloak PKCE flow will replace this call entirely, so `password` is accepted for
    // interface compatibility but ignored rather than changing the shared ApiClient signature.
    final login =
        await _send('POST', '/v1/auth/dev/login', body: {'employeeCode': employeeCode})
            as Map<String, dynamic>;
    _accessToken = login['accessToken'] as String;
    _tokenLoaded = true;
    await _tokenStore.writeToken(_accessToken);

    // ApiClient has no separate device-registration method, so it's folded in here. The device
    // id is stable across restarts (see _resolveDeviceId) and RegisterDeviceAsync upserts by id
    // (src/Modules/XMobile.Identity/Endpoints/AuthEndpoints.cs), so re-registering the same id
    // on every sign-in is safe — it just refreshes LastSeenAt etc., never duplicates.
    await _send('POST', '/v1/auth/device', body: {
      'deviceId': await _resolveDeviceId(),
      'platform': Platform.isIOS ? 'IOS' : 'ANDROID',
    });

    return currentUser();
  }

  @override
  Future<AppUser> currentUser() async {
    final json = await _send('GET', '/v1/auth/me') as Map<String, dynamic>;
    return AppUser.fromJson(json);
  }

  @override
  Future<void> updateHomeLocation(HomeLocation home) async {
    await _send('PUT', '/v1/auth/home', body: home.toJson());
  }

  // ---------------------------------------------------------------- reference data

  @override
  Future<List<VisitType>> visitTypes() => _notSupported();

  @override
  Future<List<VisitOutcome>> visitOutcomes() => _notSupported();

  @override
  Future<List<ReasonCode>> reasonCodes(String domain) => _notSupported();

  @override
  Future<List<ExpenseCategory>> expenseCategories() => _notSupported();

  @override
  Future<List<OpportunityStage>> opportunityStages() => _notSupported();

  @override
  Future<List<FormTemplate>> formTemplates() async {
    final json = await _send('GET', '/v1/form-templates') as List;
    return json.map((e) => FormTemplate.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ---------------------------------------------------------------- customers

  @override
  Future<List<Customer>> customers({String? query}) async {
    final json = await _send('GET', '/v1/customers', query: {if (query != null) 'q': query}) as List;
    return json.map((e) => Customer.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<Customer> customer(String id) async {
    final json = await _send('GET', '/v1/customers/$id') as Map<String, dynamic>;
    return Customer.fromJson(json);
  }

  @override
  Future<Customer360> customerSummary(String id) async {
    final json = await _send('GET', '/v1/customers/$id/summary') as Map<String, dynamic>;
    return Customer360.fromJson(json);
  }

  @override
  Future<List<SalesHistoryItem>> salesHistory(String customerId) async {
    final json = await _send('GET', '/v1/customers/$customerId/history') as Map<String, dynamic>;
    return (json['sales'] as List).map((e) => SalesHistoryItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<Visit>> customerVisits(String customerId) async {
    final json = await _send('GET', '/v1/customers/$customerId/history') as Map<String, dynamic>;
    return (json['visits'] as List).map((e) => Visit.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<Customer> proposeCustomer(Customer draft) => _notSupported();

  @override
  Future<CustomerSite> addSite(CustomerSite site) => _notSupported();

  @override
  Future<CustomerContact> addContact(CustomerContact contact) => _notSupported();

  @override
  Future<CustomerSite> captureSiteLocation(String siteId, GeoPoint point, {int? radiusM}) => _notSupported();

  // ---------------------------------------------------------------- opportunities

  @override
  Future<List<Opportunity>> opportunities({String? customerId, bool openOnly = false}) => _notSupported();

  @override
  Future<Opportunity> createOpportunity(Opportunity draft) => _notSupported();

  @override
  Future<Opportunity> updateOpportunity(Opportunity updated, {String? visitId, String? reason}) =>
      _notSupported();

  @override
  Future<List<OpportunityStageChange>> opportunityHistory(String opportunityId) => _notSupported();

  // ---------------------------------------------------------------- planning

  @override
  Future<List<Tour>> tours() async {
    final json = await _send('GET', '/v1/tours') as List;
    return json.map((e) => Tour.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<Tour> tour(String id) async {
    final json = await _send('GET', '/v1/tours/$id') as Map<String, dynamic>;
    return Tour.fromJson(json);
  }

  @override
  Future<Tour> saveTour(Tour tour) async {
    final body = {
      'id': tour.id,
      'title': tour.title,
      'plannedStartDate': _dateOnly(tour.plannedStartDate),
      'plannedEndDate': _dateOnly(tour.plannedEndDate),
      if (tour.purpose != null) 'purpose': tour.purpose,
      if (tour.destinationCity != null) 'destinationCity': tour.destinationCity,
    };

    if (tour.rowVersion == null) {
      await _send('POST', '/v1/tours', body: body);
    } else {
      await _send('PATCH', '/v1/tours/${tour.id}', body: {...body, 'baseVersion': tour.rowVersion});
    }

    // POST returns TourDto (no days) and PATCH doesn't touch days at all — re-fetch so the
    // caller always gets the authoritative TourDetail, including server-generated day rows.
    return this.tour(tour.id);
  }

  @override
  Future<Tour> startTour(String id) async {
    await _send('POST', '/v1/tours/$id/start');
    return tour(id);
  }

  @override
  Future<Tour> completeTour(String id) async {
    await _send('POST', '/v1/tours/$id/complete');
    return tour(id);
  }

  @override
  Future<List<VisitPlan>> visitPlans({DateTime? from, DateTime? to, String? tourId}) async {
    if (tourId != null) {
      // GET /v1/plans has no tourId filter — a tour's plans come back nested in its detail.
      final json = await _send('GET', '/v1/tours/$tourId') as Map<String, dynamic>;
      return (json['plans'] as List).map((e) => VisitPlan.fromJson(e as Map<String, dynamic>)).toList();
    }

    final effectiveFrom = from ?? DateTime.now().subtract(const Duration(days: 30));
    final effectiveTo = to ?? DateTime.now().add(const Duration(days: 30));
    final json = await _send('GET', '/v1/plans',
        query: {'from': _dateOnly(effectiveFrom), 'to': _dateOnly(effectiveTo)}) as List;
    return json.map((e) => VisitPlan.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<VisitPlan> saveVisitPlan(VisitPlan plan) async {
    if (plan.rowVersion != null) {
      throw ApiException('Updating an existing visit plan is not yet available in the live backend');
    }
    if (plan.tourId == null || plan.tourDayId == null) {
      throw ApiException('A visit plan needs a tour and a tour day to be created on the live backend');
    }

    final json = await _send('POST', '/v1/tours/${plan.tourId}/days/${plan.tourDayId}/plans', body: {
      'id': plan.id,
      'customerId': plan.customerId,
      'siteId': plan.siteId,
      if (plan.contactId != null) 'contactId': plan.contactId,
      'visitTypeCode': plan.visitTypeCode,
      'plannedDate': _dateOnly(plan.plannedDate),
      if (plan.plannedStartTime != null) 'plannedStartTime': plan.plannedStartTime,
      'seq': plan.seq,
      if (plan.objective != null) 'objective': plan.objective,
    }) as Map<String, dynamic>;
    return VisitPlan.fromJson(json);
  }

  @override
  Future<VisitPlan> skipVisitPlan(String planId, String reasonCode, String? remark) async {
    await _send('POST', '/v1/plans/$planId/skip', body: {
      'reasonCode': reasonCode,
      if (remark != null) 'remark': remark,
    });
    // Not in api/openapi.yaml — added so this call has something to return; see
    // GetPlanAsync in TourEndpoints.cs.
    final json = await _send('GET', '/v1/plans/$planId') as Map<String, dynamic>;
    return VisitPlan.fromJson(json);
  }

  // ---------------------------------------------------------------- visits

  @override
  Future<List<Visit>> visits({DateTime? from, DateTime? to}) async {
    final json = await _send('GET', '/v1/visits', query: {
      if (from != null) 'from': _dateOnly(from),
      if (to != null) 'to': _dateOnly(to),
    }) as List;
    return json.map((e) => Visit.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<Visit> checkIn(Visit visit) async {
    final point = visit.checkInPoint;
    if (point == null) {
      throw ApiException('A location is required to check in', fieldErrors: const {'point': 'required'});
    }

    final json = await _send('POST', '/v1/visits/check-in', body: {
      'visitId': visit.id,
      if (visit.visitPlanId != null) 'visitPlanId': visit.visitPlanId,
      if (visit.tourId != null) 'tourId': visit.tourId,
      'siteId': visit.siteId,
      if (visit.contactId != null) 'contactId': visit.contactId,
      'visitTypeCode': visit.visitTypeCode,
      'checkInAt': visit.checkInAt.toUtc().toIso8601String(),
      'point': point.toJson(),
      'method': visit.checkInMethod.wire,
      if (visit.outOfFenceReasonCode != null) 'outOfFenceReasonCode': visit.outOfFenceReasonCode,
      if (visit.outOfFenceRemark != null) 'outOfFenceRemark': visit.outOfFenceRemark,
    }) as Map<String, dynamic>;
    return Visit.fromJson(json);
  }

  @override
  Future<Visit> checkOut(String visitId, DateTime at, GeoPoint? point) async {
    final json = await _send('POST', '/v1/visits/$visitId/check-out', body: {
      'checkOutAt': at.toUtc().toIso8601String(),
      if (point != null) 'point': point.toJson(),
    }) as Map<String, dynamic>;
    return Visit.fromJson(json);
  }

  @override
  Future<VisitReport?> visitReport(String visitId) async {
    final json =
        await _send('GET', '/v1/visits/$visitId/report', notFoundAsNull: true) as Map<String, dynamic>?;
    return json == null ? null : VisitReport.fromJson(json);
  }

  @override
  Future<VisitReport> saveVisitReport(VisitReport report, {required bool submit}) async {
    final json = await _send('PUT', '/v1/visits/${report.visitId}/report',
        body: report.toJson(submit: submit)) as Map<String, dynamic>;
    return VisitReport.fromJson(json);
  }

  @override
  Future<void> linkVisitOpportunities(String visitId, List<String> opportunityIds) => _notSupported();

  @override
  Future<List<String>> visitOpportunityIds(String visitId) => _notSupported();

  // ---------------------------------------------------------------- expenses

  @override
  Future<List<Expense>> expenses({DateTime? from, DateTime? to}) => _notSupported();

  @override
  Future<Expense> saveExpense(Expense expense, {required bool submit}) => _notSupported();

  @override
  Future<void> deleteExpense(String id) => _notSupported();

  @override
  Future<List<Expense>> duplicateCandidates(Expense expense) => _notSupported();

  @override
  Future<MileageSuggestion?> mileageSuggestion(DateTime date, {String? tourId}) => _notSupported();

  @override
  Future<List<ShareInboxItem>> shareInbox() => _notSupported();

  @override
  Future<ShareInboxItem> simulateSharedFile({required String fileName, required String sourceApp}) =>
      _notSupported();

  @override
  Future<void> dismissShareInboxItem(String id) => _notSupported();

  @override
  Future<Attachment> addAttachment(Attachment attachment) => _notSupported();

  @override
  Future<List<Attachment>> attachments() => _notSupported();

  // ---------------------------------------------------------------- journey / tracking

  /// `GET /v1/tracking/journey` returns events/segments/daily summaries together — the three
  /// methods below each call this and pick their slice. That means two providers watching (say)
  /// both `journeyEvents` and `journeySegments` fire two identical requests; a known, disclosed
  /// inefficiency rather than a caching layer this pass — see docs/10-roadmap.md §6.
  Future<Map<String, dynamic>> _journeyTimeline(DateTime from, DateTime to) async =>
      await _send('GET', '/v1/tracking/journey', query: {
        'from': from.toUtc().toIso8601String(),
        'to': to.toUtc().toIso8601String(),
      }) as Map<String, dynamic>;

  @override
  Future<List<JourneyEvent>> journeyEvents({required DateTime from, required DateTime to}) async {
    final json = await _journeyTimeline(from, to);
    return (json['events'] as List).map((e) => JourneyEvent.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<JourneySegment>> journeySegments({required DateTime from, required DateTime to}) async {
    final json = await _journeyTimeline(from, to);
    return (json['segments'] as List).map((e) => JourneySegment.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<DaySummary>> daySummaries({required DateTime from, required DateTime to}) async {
    final json = await _journeyTimeline(from, to);
    return (json['daily'] as List).map((e) => DaySummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<JourneyEvent> addManualJourneyEvent(JourneyEvent event) async {
    // POST /v1/tracking/heading-home is the only manual-creation endpoint the backend exposes —
    // it always creates a START_RETURN event. The other 5 types a rep can pick in the UI
    // (JourneyEventType.manualEntryTypes) have no backend endpoint to create them at all yet.
    if (event.type != JourneyEventType.startReturn) {
      throw ApiException('Recording "${event.type.label}" manually isn\'t available against the '
          'live backend yet — only "${JourneyEventType.startReturn.label}" is supported so far');
    }

    await _send('POST', '/v1/tracking/heading-home',
        body: {'occurredAt': event.occurredAt.toUtc().toIso8601String()});

    // heading-home returns 200 with no body, so the event it created is located with a narrow
    // follow-up query rather than trusting a synthesized client-side echo (the server, not the
    // client, assigns the id).
    final window = await _journeyTimeline(
      event.occurredAt.subtract(const Duration(minutes: 1)),
      event.occurredAt.add(const Duration(minutes: 1)),
    );
    final created = (window['events'] as List)
        .map((e) => JourneyEvent.fromJson(e as Map<String, dynamic>))
        .where((e) => e.type == JourneyEventType.startReturn)
        .toList();
    if (created.isEmpty) {
      throw ApiException('The event was recorded but could not be read back');
    }

    return created.reduce((a, b) =>
        (a.occurredAt.difference(event.occurredAt)).abs() <= (b.occurredAt.difference(event.occurredAt)).abs()
            ? a
            : b);
  }

  @override
  Future<JourneyEvent> correctJourneyEvent(String eventId, DateTime occurredAt, String reason) async {
    final json = await _send('POST', '/v1/tracking/events/$eventId/override',
        body: {'occurredAt': occurredAt.toUtc().toIso8601String(), 'reason': reason}) as Map<String, dynamic>;
    return JourneyEvent.fromJson(json);
  }

  @override
  Future<JourneyEvent> confirmJourneyEvent(String eventId) async {
    final json = await _send('POST', '/v1/tracking/events/$eventId/confirm') as Map<String, dynamic>;
    return JourneyEvent.fromJson(json);
  }

  // GET/PUT /v1/tracking/health and GET/POST /v1/tracking/status resolve "the current device" /
  // "the current session" implicitly server-side — ApiClient carries no device or session id
  // here, matching the interface this pass wires against (see docs/10-roadmap.md §6).
  @override
  Future<TrackingHealth> trackingHealth() async {
    final json = await _send('GET', '/v1/tracking/health') as Map<String, dynamic>;
    return TrackingHealth.fromJson(json);
  }

  @override
  Future<TrackingHealth> updateTrackingHealth(TrackingHealth health) async {
    final json =
        await _send('PUT', '/v1/tracking/health', body: health.toJson()) as Map<String, dynamic>;
    return TrackingHealth.fromJson(json);
  }

  @override
  Future<bool> isTrackingActive() async {
    final json = await _send('GET', '/v1/tracking/status') as Map<String, dynamic>;
    return json['active'] as bool;
  }

  /// No client-side pre-validation of `pauseReasonCode` (unlike `MockApiClient`) — matching how
  /// every other real endpoint in this file works, the server's rejection comes back through the
  /// normal problem+json → ApiException path (`_errorFor`) rather than being duplicated here.
  @override
  Future<void> setTrackingActive(bool active, {String? pauseReasonCode}) async {
    await _send('POST', '/v1/tracking/status', body: {
      'active': active,
      if (pauseReasonCode != null) 'pauseReasonCode': pauseReasonCode,
    });
  }
}
