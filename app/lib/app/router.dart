import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/state/providers.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/customers/customer_detail_screen.dart';
import '../features/customers/customer_form_screen.dart';
import '../features/customers/customers_screen.dart';
import '../features/customers/site_form_screen.dart';
import '../features/developer/developer_screen.dart';
import '../features/expenses/expense_form_screen.dart';
import '../features/expenses/expenses_screen.dart';
import '../features/expenses/share_inbox_screen.dart';
import '../features/home/today_screen.dart';
import '../features/journey/journey_screen.dart';
import '../features/journey/manual_event_screen.dart';
import '../features/more/more_screen.dart';
import '../features/opportunities/opportunities_screen.dart';
import '../features/opportunities/opportunity_form_screen.dart';
import '../features/settings/tracking_health_screen.dart';
import '../features/sync/sync_screen.dart';
import '../features/tours/tour_detail_screen.dart';
import '../features/tours/tour_form_screen.dart';
import '../features/tours/tours_screen.dart';
import '../features/tours/visit_plan_form_screen.dart';
import '../features/visits/check_in_screen.dart';
import '../features/visits/visit_detail_screen.dart';
import '../features/visits/visit_report_screen.dart';
import 'shell.dart';

final _rootKey = GlobalKey<NavigatorState>();
final _shellKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/today',
    redirect: (context, state) {
      final signedIn = ref.read(sessionProvider).isSignedIn;
      final atSignIn = state.matchedLocation == '/sign-in';

      if (!signedIn && !atSignIn) return '/sign-in';
      if (signedIn && atSignIn) return '/today';
      return null;
    },
    routes: [
      GoRoute(path: '/sign-in', builder: (_, __) => const SignInScreen()),

      // The five tabs a rep works from. Everything else pushes over them.
      ShellRoute(
        navigatorKey: _shellKey,
        builder: (context, state, child) => AppShell(state: state, child: child),
        routes: [
          GoRoute(path: '/today', builder: (_, __) => const TodayScreen()),
          GoRoute(path: '/tours', builder: (_, __) => const ToursScreen()),
          GoRoute(path: '/customers', builder: (_, __) => const CustomersScreen()),
          GoRoute(path: '/expenses', builder: (_, __) => const ExpensesScreen()),
          GoRoute(path: '/more', builder: (_, __) => const MoreScreen()),
        ],
      ),

      // --- tours & planning ---
      GoRoute(
        path: '/tours/new',
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const TourFormScreen(),
      ),
      GoRoute(
        path: '/tours/:id',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => TourDetailScreen(tourId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/tours/:id/edit',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => TourFormScreen(tourId: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/plans/new',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => VisitPlanFormScreen(
          tourId: state.uri.queryParameters['tourId'],
          date: DateTime.tryParse(state.uri.queryParameters['date'] ?? ''),
        ),
      ),

      // --- visits ---
      GoRoute(
        path: '/check-in',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => CheckInScreen(
          planId: state.uri.queryParameters['planId'],
          customerId: state.uri.queryParameters['customerId'],
          siteId: state.uri.queryParameters['siteId'],
        ),
      ),
      GoRoute(
        path: '/visits/:id',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => VisitDetailScreen(visitId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/visits/:id/report',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => VisitReportScreen(visitId: state.pathParameters['id']!),
      ),

      // --- customers ---
      GoRoute(
        path: '/customers/new',
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const CustomerFormScreen(),
      ),
      GoRoute(
        path: '/customers/:id',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => CustomerDetailScreen(customerId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/customers/:id/sites/new',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => SiteFormScreen(customerId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/customers/:id/sites/:siteId/location',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => SiteFormScreen(
          customerId: state.pathParameters['id']!,
          siteId: state.pathParameters['siteId'],
        ),
      ),

      // --- opportunities ---
      GoRoute(
        path: '/opportunities',
        parentNavigatorKey: _rootKey,
        builder: (_, state) =>
            OpportunitiesScreen(customerId: state.uri.queryParameters['customerId']),
      ),
      GoRoute(
        path: '/opportunities/new',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => OpportunityFormScreen(
          customerId: state.uri.queryParameters['customerId'],
          visitId: state.uri.queryParameters['visitId'],
        ),
      ),
      GoRoute(
        path: '/opportunities/:id',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => OpportunityFormScreen(
          opportunityId: state.pathParameters['id'],
          visitId: state.uri.queryParameters['visitId'],
        ),
      ),

      // --- expenses ---
      GoRoute(
        path: '/expenses/new',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => ExpenseFormScreen(
          shareInboxItemId: state.uri.queryParameters['fromInbox'],
          tourId: state.uri.queryParameters['tourId'],
        ),
      ),
      GoRoute(
        path: '/expenses/:id',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => ExpenseFormScreen(expenseId: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/share-inbox',
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const ShareInboxScreen(),
      ),

      // --- journey & tracking ---
      GoRoute(
        path: '/journey',
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const JourneyScreen(),
      ),
      GoRoute(
        path: '/journey/manual',
        parentNavigatorKey: _rootKey,
        builder: (_, state) => ManualEventScreen(eventId: state.uri.queryParameters['eventId']),
      ),
      GoRoute(
        path: '/tracking-health',
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const TrackingHealthScreen(),
      ),

      // --- sync & developer ---
      GoRoute(
        path: '/sync',
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const SyncScreen(),
      ),
      GoRoute(
        path: '/developer',
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const DeveloperScreen(),
      ),
    ],
  );
});
