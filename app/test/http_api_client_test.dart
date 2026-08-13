import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xmobile/core/api/api_client.dart';
import 'package:xmobile/core/api/http_api_client.dart';

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

      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client);
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

  group('error mapping', () {
    test('a problem+json 409 becomes an ApiException with the server detail', () async {
      final client = MockClient((request) async => _problem('Stale version', status: 409));
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client);

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
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client);

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
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client);

      await expectLater(api.tours(), throwsA(isA<OfflineException>()));
    });

    test('a method with no backend support throws a catchable ApiException, not UnimplementedError',
        () async {
      final client = MockClient((request) async => http.Response('should not be called', 500));
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client);

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
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client);

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
      final api = HttpApiClient(baseUrl: 'https://xmobile.test', httpClient: client);

      final plans = await api.visitPlans(tourId: 't1');

      expect(plans, hasLength(1));
      expect(plans.single.id, 'p1');
      expect(plansEndpointCalled, isFalse);
    });
  });
}
