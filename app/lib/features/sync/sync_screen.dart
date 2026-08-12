import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/enums.dart';
import '../../core/state/providers.dart';
import '../../core/ui/common.dart';
import '../../core/ui/form_fields.dart';

/// What is still on the device and what has left it.
///
/// This screen exists because "offline" and "did nothing" look identical otherwise —
/// to the rep and to their manager. A visible queue is what makes a lost day
/// distinguishable from a quiet one.
class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  bool _syncing = false;

  Future<void> _syncNow() async {
    setState(() => _syncing = true);

    final outbox = ref.read(outboxProvider);
    final notifier = ref.read(outboxProvider.notifier);
    final online = ref.read(mockApiProvider)?.offline != true;

    for (final entry in outbox.where((e) => e.state != SyncState.synced)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (online) {
        notifier.markSynced(entry.id);
      } else {
        notifier.markFailed(entry.id, 'No connection');
      }
    }

    ref.read(connectivityProvider.notifier).state = online;
    bumpRefreshFrom(ref);

    if (mounted) {
      setState(() => _syncing = false);
      showSuccess(context, online ? 'Everything is synced' : 'Still offline — nothing sent');
    }
  }

  @override
  Widget build(BuildContext context) {
    final outbox = ref.watch(outboxProvider);
    final online = ref.watch(connectivityProvider);
    final pending = outbox.where((e) => e.state != SyncState.synced).toList();
    final synced = outbox.where((e) => e.state == SyncState.synced).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync'),
        actions: [
          if (synced.isNotEmpty)
            TextButton(
              onPressed: () => ref.read(outboxProvider.notifier).clearSynced(),
              child: const Text('Clear done'),
            ),
        ],
      ),
      bottomNavigationBar: SubmitBar(
        label: pending.isEmpty ? 'Everything is up to date' : 'Sync ${pending.length} now',
        busy: _syncing,
        onSubmit: pending.isEmpty ? null : _syncNow,
      ),
      body: ListView(
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: ListTile(
              leading: Icon(online ? Icons.cloud_done : Icons.cloud_off,
                  color: online ? Colors.green : Theme.of(context).colorScheme.error),
              title: Text(online ? 'Online' : 'Offline'),
              subtitle: Text(
                pending.isEmpty
                    ? 'Nothing waiting. Everything you have entered is on the server.'
                    : '${pending.length} change${pending.length == 1 ? '' : 's'} still on '
                        'this device. Nothing is lost — they will go up when there is a signal.',
              ),
            ),
          ),
          if (pending.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Waiting to sync',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final entry in pending)
              Card(
                margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: ListTile(
                  leading: Icon(
                    entry.state == SyncState.failed ? Icons.error_outline : Icons.schedule,
                    color: entry.state == SyncState.failed
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                  title: Text(entry.description),
                  subtitle: Text(
                    '${entry.entity} · ${dateTimeFormat.format(entry.createdAt)}'
                    '${entry.attempts > 0 ? ' · ${entry.attempts} attempt${entry.attempts == 1 ? '' : 's'}' : ''}'
                    '${entry.lastError != null ? '\n${entry.lastError}' : ''}',
                  ),
                  isThreeLine: entry.lastError != null,
                  trailing: StatusChip(
                    label: entry.state.label,
                    color: entry.state == SyncState.failed
                        ? Theme.of(context).colorScheme.error
                        : Colors.orange,
                  ),
                ),
              ),
          ],
          if (synced.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Sent', style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final entry in synced.take(20))
              ListTile(
                dense: true,
                leading: const Icon(Icons.check_circle, color: Colors.green, size: 20),
                title: Text(entry.description),
                subtitle: Text(dateTimeFormat.format(entry.createdAt)),
              ),
          ],
          if (outbox.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: EmptyState(
                icon: Icons.cloud_done,
                title: 'Nothing waiting',
                message: 'Everything you have entered has reached the server.',
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
