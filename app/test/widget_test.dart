import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xmobile/core/api/mock_api_client.dart';
import 'package:xmobile/core/models/models.dart';
import 'package:xmobile/core/state/providers.dart';
import 'package:xmobile/core/ui/common.dart';
import 'package:xmobile/features/customers/customers_screen.dart';
import 'package:xmobile/features/expenses/expenses_screen.dart';
import 'package:xmobile/features/home/today_screen.dart';
import 'package:xmobile/features/settings/tracking_health_screen.dart';
import 'package:xmobile/features/visits/dynamic_form.dart';

/// Renders real screens against the in-memory backend, so the forms are exercised rather
/// than assumed. No device, no emulator.
void main() {
  late MockApiClient api;

  setUp(() => api = MockApiClient(latency: Duration.zero));

  Widget host(Widget child) => ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: MaterialApp(home: child),
      );

  group('Today', () {
    testWidgets('shows the plan, tracking state and the running tour', (tester) async {
      await tester.pumpWidget(host(const TodayScreen()));
      await tester.pumpAndSettle();

      expect(find.text("Today's plan"), findsOneWidget);
      expect(find.text('Nagpur Distributors Pvt Ltd'), findsWidgets);

      // Tracking state is the first thing on the screen, never buried in settings.
      expect(find.textContaining('Tracking is'), findsOneWidget);
      expect(find.text('Nagpur — distributor review'), findsOneWidget);
      expect(find.text('Check in'), findsWidgets);
    });

    testWidgets('offers an unplanned visit and an expense without leaving the screen',
        (tester) async {
      await tester.pumpWidget(host(const TodayScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Unplanned visit'), findsOneWidget);
      expect(find.text('Add expense'), findsOneWidget);
    });
  });

  group('Customers', () {
    testWidgets('lists customers and marks a field-created prospect', (tester) async {
      await tester.pumpWidget(host(const CustomersScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Kothrud Hardware Stores'), findsOneWidget);
      expect(find.text('Vidarbha Traders'), findsOneWidget);
      expect(find.text('Awaiting approval'), findsOneWidget);
    });

    testWidgets('search narrows the list', (tester) async {
      await tester.pumpWidget(host(const CustomersScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'kothrud');
      await tester.pumpAndSettle();

      expect(find.text('Kothrud Hardware Stores'), findsOneWidget);
      expect(find.text('Nagpur Distributors Pvt Ltd'), findsNothing);
    });
  });

  group('Expenses', () {
    testWidgets('lists expenses with their XInfo status', (tester) async {
      await tester.pumpWidget(host(const ExpensesScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Rail travel'), findsOneWidget);
      expect(find.textContaining('XInfo: PENDING'), findsOneWidget);
      expect(find.text('Sent to XInfo'), findsOneWidget);
    });

    testWidgets('surfaces waiting shared receipts', (tester) async {
      // runAsync, because testWidgets runs in a fake-async zone: an ordinary `await` on a
      // real Future before the first pump waits on a clock that never advances.
      await tester.runAsync(
        () => api.simulateSharedFile(fileName: 'upi.jpg', sourceApp: 'upi'),
      );

      await tester.pumpWidget(host(const ExpensesScreen()));
      await tester.pumpAndSettle();

      expect(find.text('1 shared receipt waiting'), findsOneWidget);
      expect(find.text('Tap to turn them into expenses'), findsOneWidget);
    });
  });

  group('Tracking health', () {
    testWidgets('shows a score and a fixable checklist', (tester) async {
      await tester.pumpWidget(host(const TrackingHealthScreen()));
      await tester.pumpAndSettle();

      // The seed is deliberately imperfect, so the fix flow is visible.
      expect(find.textContaining('to fix'), findsWidgets);
      expect(find.text('Set to Always'), findsOneWidget);
      expect(find.text('Enable autostart'), findsOneWidget);
    });

    testWidgets('fixing an item updates the score', (tester) async {
      await tester.pumpWidget(host(const TrackingHealthScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Location permission'), findsOneWidget);
      await tester.tap(find.text('Set to Always'));
      await tester.pumpAndSettle();

      expect(find.text('Set to Always'), findsNothing);
      expect(find.textContaining('Set to Always — correct'), findsOneWidget);
    });
  });

  group('dynamic form engine', () {
    final section = FormSection.fromJson(const {
      'key': 'stock',
      'title': 'Stock check',
      'fields': [
        {'key': 'stock_checked', 'type': 'bool', 'label': 'Stock checked?', 'required': true},
        {
          'key': 'closing_qty',
          'type': 'number',
          'label': 'Closing quantity',
          'min': 0,
          'required': true,
          'visibleIf': {'field': 'stock_checked', 'eq': true}
        },
        {
          'key': 'price_feedback',
          'type': 'choice',
          'label': 'Price feedback',
          'options': ['Competitive', 'Too high']
        },
        {'key': 'future_type', 'type': 'hologram', 'label': 'From a newer server'},
      ],
    });

    testWidgets('renders fields from the template and honours visibleIf', (tester) async {
      var answers = <String, dynamic>{};

      await tester.pumpWidget(host(StatefulBuilder(
        builder: (context, setState) => Scaffold(
          body: SingleChildScrollView(
            child: DynamicFormSection(
              section: section,
              answers: answers,
              onChanged: (key, value) => setState(() => answers[key] = value),
            ),
          ),
        ),
      )));
      await tester.pumpAndSettle();

      expect(find.text('Stock checked?'), findsOneWidget);
      expect(find.text('Closing quantity'), findsNothing);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // The conditional field appears only once its condition is met.
      expect(find.text('Closing quantity *'), findsOneWidget);
    });

    testWidgets('an unknown field type degrades instead of crashing', (tester) async {
      // An app one version behind the server must not be bricked by a new question type.
      await tester.pumpWidget(host(Scaffold(
        body: SingleChildScrollView(
          child: DynamicFormSection(
            section: section,
            answers: const {},
            onChanged: (_, __) {},
          ),
        ),
      )));
      await tester.pumpAndSettle();

      expect(find.text('From a newer server'), findsOneWidget);
      expect(find.textContaining('needs a newer version'), findsOneWidget);
    });

    test('validation matches what the server would say', () {
      // Hidden required fields must not block submission.
      expect(validateDynamicAnswers([section], {}), {'stock_checked': 'Stock checked? is required'});

      // Once visible, the conditional field is required too.
      final errors = validateDynamicAnswers([section], {'stock_checked': true});
      expect(errors.keys, contains('closing_qty'));

      // Range checks.
      expect(
        validateDynamicAnswers([section], {'stock_checked': true, 'closing_qty': -5}),
        containsPair('closing_qty', 'Closing quantity must be at least 0'),
      );

      expect(
        validateDynamicAnswers([section], {'stock_checked': true, 'closing_qty': 140}),
        isEmpty,
      );
    });
  });

  group('offline behaviour in the UI', () {
    testWidgets('a failed load explains itself instead of showing an empty list',
        (tester) async {
      api.offline = true;

      await tester.pumpWidget(host(const CustomersScreen()));
      await tester.pumpAndSettle();

      // "No customers" and "no network" must never look the same.
      expect(find.text('You are offline'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('the banner reports queued work rather than hiding it', (tester) async {
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      container.read(outboxProvider.notifier).enqueue(
            entity: 'expense',
            entityId: 'e1',
            operation: 'INSERT',
            description: 'Meals ₹260',
          );

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: OfflineBanner())),
      ));
      await tester.pumpAndSettle();

      // A rep must always be able to tell whether their day has left the device.
      expect(find.textContaining('waiting to sync'), findsOneWidget);
    });
  });
}
