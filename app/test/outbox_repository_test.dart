import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xmobile/core/db/app_database.dart';
import 'package:xmobile/core/models/enums.dart';
import 'package:xmobile/core/state/outbox.dart';

/// `OutboxNotifier` now writes through to a Drift table instead of holding its list purely in
/// memory (app/lib/core/state/outbox.dart) — these tests exercise it against a real (in-memory)
/// database, the same "construct directly, exercise, assert" style flows_test.dart uses for
/// MockApiClient, rather than mocking Drift away.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('enqueue is visible on the notifier and marked pending by default', () async {
    final outbox = OutboxNotifier(db);
    addTearDown(outbox.dispose);

    final entry = outbox.enqueue(
      entity: 'expense',
      entityId: 'e1',
      operation: 'INSERT',
      description: 'Meals ₹260',
    );

    await pumpEventQueue();

    expect(outbox.state.map((e) => e.id), contains(entry.id));
    expect(entry.state, SyncState.pending);
    expect(outbox.hasPendingFor('e1'), isTrue);
    expect(outbox.pendingCount, 1);
  });

  test('markSynced moves an entry out of the pending count', () async {
    final outbox = OutboxNotifier(db);
    addTearDown(outbox.dispose);

    final entry = outbox.enqueue(
      entity: 'visit', entityId: 'v1', operation: 'INSERT', description: 'Check-in');
    await pumpEventQueue();

    outbox.markSynced(entry.id);
    await pumpEventQueue();

    expect(outbox.state.singleWhere((e) => e.id == entry.id).state, SyncState.synced);
    expect(outbox.pendingCount, 0);
  });

  test('markFailed records the error and increments attempts', () async {
    final outbox = OutboxNotifier(db);
    addTearDown(outbox.dispose);

    final entry = outbox.enqueue(
      entity: 'visit_plan', entityId: 'p1', operation: 'INSERT', description: 'Plan a visit');
    await pumpEventQueue();

    outbox.markFailed(entry.id, 'Network error');
    await pumpEventQueue();

    final updated = outbox.state.singleWhere((e) => e.id == entry.id);
    expect(updated.state, SyncState.failed);
    expect(updated.attempts, 1);
    expect(updated.lastError, 'Network error');
  });

  test('remove deletes a single entry; clearSynced deletes only synced ones', () async {
    final outbox = OutboxNotifier(db);
    addTearDown(outbox.dispose);

    final synced = outbox.enqueue(
      entity: 'tour', entityId: 't1', operation: 'INSERT', description: 'Tour');
    final pending = outbox.enqueue(
      entity: 'tour', entityId: 't2', operation: 'INSERT', description: 'Tour 2');
    await pumpEventQueue();

    outbox.markSynced(synced.id);
    await pumpEventQueue();

    outbox.clearSynced();
    await pumpEventQueue();

    expect(outbox.state.map((e) => e.id), [pending.id]);

    outbox.remove(pending.id);
    await pumpEventQueue();

    expect(outbox.state, isEmpty);
  });

  test('a mutation queued by one notifier is durable — a second notifier over the same '
      'database sees it, proving this is real storage, not an in-memory illusion', () async {
    final first = OutboxNotifier(db);
    addTearDown(first.dispose);

    first.enqueue(entity: 'expense', entityId: 'e9', operation: 'INSERT', description: 'Fuel');
    await pumpEventQueue();

    final second = OutboxNotifier(db);
    addTearDown(second.dispose);
    await pumpEventQueue();

    expect(second.state.map((e) => e.entityId), contains('e9'));
  });
}
