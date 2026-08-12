import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// Switches for the conditions that are hard to produce on demand but decide whether the
/// app is any good in the field: no signal, and a backend that is up while XInfo is not.
///
/// These drive the real code paths — the same queueing, the same banners, the same
/// messages a rep would see in a basement in Nagpur.
class DeveloperScreen extends ConsumerStatefulWidget {
  const DeveloperScreen({super.key});

  @override
  ConsumerState<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends ConsumerState<DeveloperScreen> {
  @override
  Widget build(BuildContext context) {
    final mock = ref.watch(mockApiProvider);
    final outbox = ref.watch(outboxProvider);

    if (mock == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Developer')),
        body: const EmptyState(
          icon: Icons.cloud,
          title: 'Connected to a real backend',
          message: 'These simulations only apply to the in-memory demo backend.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Developer')),
      body: ListView(
        children: [
          FormSectionCard(
            title: 'Simulate conditions',
            subtitle: 'The two failures that matter most in the field.',
            children: [
              AppSwitchField(
                label: 'No connection',
                subtitle: 'Saves are queued on the device instead of failing. '
                    'Try checking in or adding an expense with this on.',
                value: mock.offline,
                onChanged: (value) {
                  setState(() => mock.offline = value);
                  ref.read(connectivityProvider.notifier).state = !value;
                  bumpRefreshFrom(ref);
                },
              ),
              AppSwitchField(
                label: 'XInfo unreachable',
                subtitle: 'Online, but the CRM is down. Submitting an expense saves it and '
                    'retries — a different failure from being offline, with a different message.',
                value: mock.xinfoDown,
                onChanged: (value) => setState(() => mock.xinfoDown = value),
              ),
            ],
          ),
          FormSectionCard(
            title: 'Outbox',
            subtitle: '${outbox.length} entries recorded this session',
            children: [
              Text(
                'Each queued change keeps the id it was created with. That is what stops a '
                'retry from creating a second expense — the most expensive bug this design '
                'exists to prevent.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: outbox.isEmpty
                    ? null
                    : () {
                        ref.read(outboxProvider.notifier).clearSynced();
                        showSuccess(context, 'Cleared synced entries');
                      },
                icon: const Icon(Icons.cleaning_services_outlined),
                label: const Text('Clear synced entries'),
              ),
            ],
          ),
          FormSectionCard(
            title: 'About this build',
            children: [
              const Text(
                'Every screen talks to an in-memory backend that implements the same '
                'ApiClient contract the HTTP client will. Connecting to the real API is an '
                'override of one provider — no screen or form changes.',
              ),
              const SizedBox(height: 8),
              Text(
                'Seeded with a Pune territory, a Nagpur tour in progress, four customers, '
                'three opportunities and a handful of expenses.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
