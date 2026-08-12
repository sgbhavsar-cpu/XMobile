import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/state/providers.dart';
import '../core/ui/common.dart';

/// The five tabs a rep lives in. The offline banner sits above them so its state is
/// visible from every screen rather than buried in settings.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.state, required this.child});

  final GoRouterState state;
  final Widget child;

  static const _tabs = [
    (path: '/today', icon: Icons.today_outlined, selected: Icons.today, label: 'Today'),
    (path: '/tours', icon: Icons.route_outlined, selected: Icons.route, label: 'Tours'),
    (path: '/customers', icon: Icons.store_outlined, selected: Icons.store, label: 'Customers'),
    (path: '/expenses', icon: Icons.receipt_long_outlined, selected: Icons.receipt_long, label: 'Expenses'),
    (path: '/more', icon: Icons.more_horiz_outlined, selected: Icons.more_horiz, label: 'More'),
  ];

  int get _currentIndex {
    final location = state.matchedLocation;
    final index = _tabs.indexWhere((tab) => location.startsWith(tab.path));
    return index < 0 ? 0 : index;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingSyncCountProvider);

    return Scaffold(
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(child: child),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => context.go(_tabs[index].path),
        destinations: [
          for (final tab in _tabs)
            NavigationDestination(
              icon: tab.label == 'More' && pending > 0
                  ? Badge(label: Text('$pending'), child: Icon(tab.icon))
                  : Icon(tab.icon),
              selectedIcon: Icon(tab.selected),
              label: tab.label,
            ),
        ],
      ),
    );
  }
}
