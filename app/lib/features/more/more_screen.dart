import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final user = session.user;
    final pending = ref.watch(pendingSyncCountProvider);
    final health = ref.watch(trackingHealthProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          if (user != null)
            FormSectionCard(
              title: user.fullName,
              subtitle: '${user.employeeCode}${user.orgUnitName != null ? ' · ${user.orgUnitName}' : ''}',
              children: [
                if (user.managerName != null)
                  DetailRow(label: 'Reports to', value: user.managerName!, icon: Icons.person),
                if (user.phone != null)
                  DetailRow(label: 'Phone', value: user.phone!, icon: Icons.phone),
                if (user.homeLocation != null)
                  DetailRow(
                    label: 'Home',
                    value: '${user.homeLocation!.city ?? ''} '
                        '(${user.homeLocation!.geofenceRadiusM} m fence)',
                    icon: Icons.home,
                  ),
              ],
            ),
          ListTile(
            leading: const Icon(Icons.timeline),
            title: const Text('My journey'),
            subtitle: const Text('Where you went, and correct anything wrong'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/journey'),
          ),
          ListTile(
            leading: health.valueOrNull != null && health.value!.score >= 80
                ? const Icon(Icons.health_and_safety, color: Colors.green)
                : const Icon(Icons.health_and_safety_outlined, color: Colors.orange),
            title: const Text('Tracking health'),
            subtitle: Text(health.valueOrNull == null
                ? 'Check your tracking setup'
                : '${health.value!.score}/100 · ${health.value!.issues.length} to fix'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/tracking-health'),
          ),
          ListTile(
            leading: Badge(
              isLabelVisible: pending > 0,
              label: Text('$pending'),
              child: const Icon(Icons.sync),
            ),
            title: const Text('Sync'),
            subtitle: Text(pending == 0
                ? 'Everything is up to date'
                : '$pending change${pending == 1 ? '' : 's'} waiting on this device'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/sync'),
          ),
          ListTile(
            leading: const Icon(Icons.trending_up),
            title: const Text('Opportunities'),
            subtitle: const Text('Your pipeline'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/opportunities'),
          ),
          ListTile(
            leading: const Icon(Icons.inbox),
            title: const Text('Shared receipts'),
            subtitle: const Text('Files shared into XMobile from other apps'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/share-inbox'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.science_outlined),
            title: const Text('Developer'),
            subtitle: const Text('Simulate offline, XInfo outages and seed data'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/developer'),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () async {
              final ok = await confirm(
                context,
                title: 'Sign out?',
                message: 'Anything not yet synced stays on this device until you sign in again.',
                confirmLabel: 'Sign out',
              );
              if (!ok || !context.mounted) return;
              ref.read(sessionProvider.notifier).signOut();
              context.go('/sign-in');
            },
          ),
          const SizedBox(height: 24),
          Center(
            child: Text('XMobile 0.1.0 — demo build',
                style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
