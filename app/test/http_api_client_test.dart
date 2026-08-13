import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xmobile/core/api/api_client.dart';
import 'package:xmobile/core/api/http_api_client.dart';
import 'package:xmobile/core/api/token_store.dart';
import 'package:xmobile/core/models/enums.dart';
import 'package:xmobile/core/models/models.dart';

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

http.Response _problem(String detail, {int status = 409, Map<String, List<String>>? errors}) => http.Response(
      jsonEncode({'title': 'Failed', 'detail': detail, if (errors != null) 'errors': errors}),
      status,
      headers: {'content-type': 'application/problem+json'},
    );

void main() {
  group('signIn', () {
    test('stores the bearer token and registers a device before returning the user', () async {
      final calls = <http.Request>[];
      final client = MockClient((request) async {
        calls.add(request);
        if (request.method == 'POST' && request.url.path == '/v1/auth/dev/login') {
          return _json({
            'accessToken': 'tok-123',
            'userId': 'u1',
            'employeeCode': 'E100',
            'roles': ['SALES_REP'],
          });
        }
        if (request.method == 'POST' && request.url.path == '/v1/auth/device') {
          return _json({'deviceId': 'd1', 'syncPolicy': [], 'policyVersion': 1, 'settings': {}});
        }
        if (request.method == 'GET' && request.url.path == '/v1/auth/me') {
          return _json({
            'userId': 'u1',
            'employeeCode': 'E100',
            'fullName': 'Test Rep',
            'roles': ['SALES_REP'],
            'shiftStart': '09:00',
            'shiftEnd': '18:00',
            'workingDays': [1, 2, 3, 4, 5, 6],
            'consentRequired': false,
          });
        }
        return http.Response('not found', 404);
      });

      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());
      final user = await api.signIn(employeeCode: 'E100', password: 'ignored');

      expect(user.id, 'u1');
      expect(user.employeeCode, 'E100');
      expect(user.fullName, 'Test Rep');

      final paths = calls.map((c) => '${c.method} ${c.url.path}').toList();
      expect(paths, ['POST /v1/auth/dev/login', 'POST /v1/auth/device', 'GET /v1/auth/me']);

      // The two calls after login must carry the token dev-login returned.
      expect(calls[1].headers['Authorization'], 'Bearer tok-123');
      expect(calls[2].headers['Authorization'], 'Bearer tok-123');
    });
  });

  group('token persistence', () {
    test('signIn writes the token into the injected TokenStore', () async {
      final client = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/v1/auth/dev/login') {
          return _json({
            'accessToken': 'tok-456',
            'userId': 'u1',
            'employeeCode': 'E100',
            'roles': ['SALES_REP'],
          });
        }
        if (request.method == 'POST' && request.url.path == '/v1/auth/device') {
          return _json({'deviceId': 'd1', 'syncPolicy': [], 'policyVersion': 1, 'settings': {}});
        }
        if (request.method == 'GET' && request.url.path == '/v1/auth/me') {
          return _json({
            'userId': 'u1',
            'employeeCode': 'E100',
            'fullName': 'Test Rep',
            'roles': ['SALES_REP'],
            'shiftStart': '09:00',
            'shiftEnd': '18:00',
            'workingDays': [1, 2, 3, 4, 5, 6],
            'consentRequired': false,
          });
        }
        return http.Response('not found', 404);
      });
      final store = InMemoryTokenStore();
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: store);

      await api.signIn(employeeCode: 'E100', password: 'ignored');

      expect(await store.readToken(), 'tok-456');
    });

    test('a device id already in the TokenStore is reused rather than regenerated', () async {
      final store = InMemoryTokenStore(initialDeviceId: 'stable-device-1');
      String? registeredDeviceId;
      final client = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/v1/auth/dev/login') {
          return _json({
            'accessToken': 'tok-789',
            'userId': 'u1',
            'employeeCode': 'E100',
            'roles': ['SALES_REP'],
          });
        }
        if (request.method == 'POST' && request.url.path == '/v1/auth/device') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          registeredDeviceId = body['deviceId'] as String;
          return _json({'deviceId': registeredDeviceId, 'syncPolicy': [], 'policyVersion': 1, 'settings': {}});
        }
        if (request.method == 'GET' && request.url.path == '/v1/auth/me') {
          return _json({
            'userId': 'u1',
            'employeeCode': 'E100',
            'fullName': 'Test Rep',
            'roles': ['SALES_REP'],
            'shiftStart': '09:00',
            'shiftEnd': '18:00',
            'workingDays': [1, 2, 3, 4, 5, 6],
            'consentRequired': false,
          });
        }
        return http.Response('not found', 404);
      });
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: store);

      await api.signIn(employeeCode: 'E100', password: 'ignored');

      expect(registeredDeviceId, 'stable-device-1');
    });
  });

  group('error mapping', () {
    test('a problem+json 409 becomes an ApiException with the server detail', () async {
      final client = MockClient((request) async => _problem('Stale version', status: 409));
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      await expectLater(
        api.startTour('t1'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Stale version')),
      );
    });

    test('field errors from a 400 response come through in fieldErrors', () async {
      final client = MockClient((request) async => _problem(
            'Checking in outside the geofence needs a reason',
            status: 400,
            errors: {
              'outOfFenceReasonCode': ['required outside the geofence'],
            },
          ));
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      await expectLater(
        api.startTour('t1'),
        throwsA(isA<ApiException>().having(
          (e) => e.fieldErrors['outOfFenceReasonCode'],
          'fieldErrors',
          'required outside the geofence',
        )),
      );
    });

    test('a network failure surfaces as OfflineException, not a crash', () async {
      final client = MockClient((request) async => throw const SocketException('no route'));
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      await expectLater(api.tours(), throwsA(isA<OfflineException>()));
    });

    test('a method with no backend support throws a catchable ApiException, not UnimplementedError',
        () async {
      final client = MockClient((request) async => http.Response('should not be called', 500));
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      // _notSupported() throws synchronously (Never), before a Future exists to await — so this
      // needs the tear-off form (throwsA calls it itself, inside its own try/catch) rather than
      // expectLater(api.opportunities(), ...), which would already have thrown while building
      // that expression, crashing the test instead of being matched.
      expect(api.opportunities, throwsA(isA<ApiException>()));
    });
  });

  group('tour mapping', () {
    test('tour(id) drops the detail response\'s plans and visits, keeping its days', () async {
      final client = MockClient((request) async => _json({
            'id': 't1',
            'userId': 'u1',
            'title': 'Pune day',
            'plannedStartDate': '2026-08-13',
            'plannedEndDate': '2026-08-13',
            'status': 'PLANNED',
            'totalDistanceM': 0,
            'totalVisits': 0,
            'totalExpenseAmount': 0,
            'rowVersion': 0,
            'days': [
              {
                'id': 'd1',
                'planDate': '2026-08-13',
                'daySeq': 1,
                'activityType': 'VISITS',
              },
            ],
            'plans': [
              {'id': 'p1', 'customerId': 'c1', 'siteId': 's1', 'visitTypeCode': 'SALES_CALL', 'plannedDate': '2026-08-13', 'status': 'PLANNED'},
            ],
            'visits': [
              {'id': 'v1', 'customerId': 'c1', 'siteId': 's1', 'visitTypeCode': 'SALES_CALL', 'localDate': '2026-08-13', 'checkInAt': '2026-08-13T10:00:00Z', 'status': 'CHECKED_IN'},
            ],
          }));
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      final tour = await api.tour('t1');

      expect(tour.id, 't1');
      expect(tour.days, hasLength(1));
      expect(tour.days.single.id, 'd1');
      expect(tour.days.single.tourId, 't1');
      expect(tour.rowVersion, 0);
    });

    test('visitPlans(tourId: ...) fetches the tour detail rather than /v1/plans', () async {
      var plansEndpointCalled = false;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/plans') plansEndpointCalled = true;
        return _json({
          'id': 't1',
          'userId': 'u1',
          'title': 'Pune day',
          'plannedStartDate': '2026-08-13',
          'plannedEndDate': '2026-08-13',
          'status': 'PLANNED',
          'totalDistanceM': 0,
          'totalVisits': 0,
          'totalExpenseAmount': 0,
          'rowVersion': 0,
          'days': const [],
          'plans': [
            {
              'id': 'p1',
              'customerId': 'c1',
              'siteId': 's1',
              'visitTypeCode': 'SALES_CALL',
              'plannedDate': '2026-08-13',
              'status': 'PLANNED',
            },
          ],
          'visits': const [],
        });
      });
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      final plans = await api.visitPlans(tourId: 't1');

      expect(plans, hasLength(1));
      expect(plans.single.id, 'p1');
      expect(plansEndpointCalled, isFalse);
    });
  });

  group('journey/tracking', () {
    Map<String, dynamic> journeyTimelineJson() => {
          'userId': 'u1',
          'from': '2026-08-13T00:00:00Z',
          'to': '2026-08-13T23:59:59Z',
          'events': [
            {
              'id': 'e1',
              'type': 'ARRIVE_CUSTOMER',
              'occurredAt': '2026-08-13T09:30:00Z',
              'localDate': '2026-08-13',
              'point': {'lat': 18.52, 'lon': 73.85},
              'refType': 'CUSTOMER_SITE',
              'refId': 's1',
              'siteId': 's1',
              'detectionMethod': 'GEOFENCE',
              'confidence': 0.9,
              'status': 'CONFIRMED',
              'isEstimated': false,
              'rowVersion': 0,
            },
          ],
          'segments': [
            {
              'id': 'seg1',
              'type': 'OUTBOUND_TRAVEL',
              'startedAt': '2026-08-13T09:00:00Z',
              'endedAt': '2026-08-13T09:30:00Z',
              'durationS': 1800,
              'localDate': '2026-08-13',
              'distanceM': 1750,
              'travelMode': 'CAR',
              'isEstimated': false,
              'isProvisional': false,
              'rowVersion': 0,
            },
          ],
          'anomalies': const [],
          'daily': [
            {
              'localDate': '2026-08-13',
              'firstDepartureAt': '2026-08-13T09:00:00Z',
              'lastArrivalAt': null,
              'totalDistanceM': 1750,
              'travelTimeS': 1800,
              'customerTimeS': 3600,
              'gapTimeS': 0,
            },
          ],
        };

    test('journeyEvents parses the events slice of GET /v1/tracking/journey', () async {
      final client = MockClient((request) async => _json(journeyTimelineJson()));
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      final events = await api.journeyEvents(
          from: DateTime.utc(2026, 8, 13), to: DateTime.utc(2026, 8, 13, 23, 59, 59));

      expect(events, hasLength(1));
      expect(events.single.id, 'e1');
      expect(events.single.type, JourneyEventType.arriveCustomer);
      expect(events.single.status, EventStatus.confirmed);
      expect(events.single.point?.lat, 18.52);
    });

    test('journeySegments parses the segments slice of the same endpoint', () async {
      final client = MockClient((request) async => _json(journeyTimelineJson()));
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      final segments = await api.journeySegments(
          from: DateTime.utc(2026, 8, 13), to: DateTime.utc(2026, 8, 13, 23, 59, 59));

      expect(segments, hasLength(1));
      expect(segments.single.type, 'OUTBOUND_TRAVEL');
      expect(segments.single.distanceM, 1750);
      expect(segments.single.travelMode, TravelMode.car);
    });

    test('daySummaries parses the daily slice, leaving fields the backend doesn\'t compute at their defaults',
        () async {
      final client = MockClient((request) async => _json(journeyTimelineJson()));
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      final daily = await api.daySummaries(
          from: DateTime.utc(2026, 8, 13), to: DateTime.utc(2026, 8, 13, 23, 59, 59));

      expect(daily, hasLength(1));
      expect(daily.single.totalDistanceM, 1750);
      expect(daily.single.travelTimeS, 1800);
      // Not in DailySummaryDto — the backend deliberately skips the Planning/Visits cross-calls.
      expect(daily.single.visitsPlanned, 0);
      expect(daily.single.attendanceStatus, isNull);
    });

    test('correctJourneyEvent posts occurredAt/reason and returns the updated event', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _json({
          'id': 'e1',
          'type': 'ARRIVE_CUSTOMER',
          'occurredAt': '2026-08-13T09:28:00Z',
          'localDate': '2026-08-13',
          'detectionMethod': 'GEOFENCE',
          'confidence': 0.9,
          'status': 'CONFIRMED',
          'isEstimated': false,
          'originalOccurredAt': '2026-08-13T09:30:00Z',
          'rowVersion': 1,
        });
      });
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      final updated = await api.correctJourneyEvent(
          'e1', DateTime.utc(2026, 8, 13, 9, 28), 'GPS lag — arrived earlier');

      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/v1/tracking/events/e1/override');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['reason'], 'GPS lag — arrived earlier');
      expect(updated.originalOccurredAt, DateTime.utc(2026, 8, 13, 9, 30));
    });

    test('confirmJourneyEvent posts no body and returns the updated event', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return _json({
          'id': 'e1',
          'type': 'ARRIVE_CUSTOMER',
          'occurredAt': '2026-08-13T09:30:00Z',
          'localDate': '2026-08-13',
          'detectionMethod': 'GEOFENCE',
          'confidence': 0.9,
          'status': 'CONFIRMED',
          'isEstimated': false,
          'rowVersion': 1,
        });
      });
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      final updated = await api.confirmJourneyEvent('e1');

      expect(captured!.url.path, '/v1/tracking/events/e1/confirm');
      expect(captured!.body, isEmpty);
      expect(updated.status, EventStatus.confirmed);
    });

    test('addManualJourneyEvent(startReturn) posts to heading-home then reads the created event back',
        () async {
      final calls = <http.Request>[];
      final occurredAt = DateTime.utc(2026, 8, 13, 17, 0);
      final client = MockClient((request) async {
        calls.add(request);
        if (request.url.path == '/v1/tracking/heading-home') {
          return http.Response('', 200);
        }
        // The follow-up read-back query.
        return _json({
          'userId': 'u1',
          'from': '2026-08-13T16:59:00Z',
          'to': '2026-08-13T17:01:00Z',
          'events': [
            {
              'id': 'e-return',
              'type': 'START_RETURN',
              'occurredAt': occurredAt.toIso8601String(),
              'localDate': '2026-08-13',
              'detectionMethod': 'MANUAL',
              'confidence': 1.0,
              'status': 'CONFIRMED',
              'isEstimated': false,
              'rowVersion': 0,
            },
          ],
          'segments': const [],
          'anomalies': const [],
          'daily': const [],
        });
      });
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      final created = await api.addManualJourneyEvent(JourneyEvent(
        id: 'ignored-client-side',
        type: JourneyEventType.startReturn,
        occurredAt: occurredAt,
        status: EventStatus.confirmed,
      ));

      expect(calls.first.url.path, '/v1/tracking/heading-home');
      expect(created.id, 'e-return');
      expect(created.isManual, isTrue);
    });

    test('addManualJourneyEvent for any other type throws without calling the network', () async {
      var callCount = 0;
      final client = MockClient((request) async {
        callCount++;
        return http.Response('should not be called', 500);
      });
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      await expectLater(
        api.addManualJourneyEvent(JourneyEvent(
          id: 'ignored',
          type: JourneyEventType.arriveCustomer,
          occurredAt: DateTime.utc(2026, 8, 13, 9, 30),
          status: EventStatus.confirmed,
        )),
        throwsA(isA<ApiException>()),
      );
      expect(callCount, 0);
    });

    test('trackingHealth and friends stay unsupported — no backend counterpart exists', () async {
      final client = MockClient((request) async => http.Response('should not be called', 500));
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client, tokenStore: InMemoryTokenStore());

      expect(api.trackingHealth, throwsA(isA<ApiException>()));
      expect(api.isTrackingActive, throwsA(isA<ApiException>()));
    });
  });
}
