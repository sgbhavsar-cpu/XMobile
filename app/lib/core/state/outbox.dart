import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/enums.dart';
import '../models/models.dart';

/// The queue of work waiting to reach the server.
///
/// Two properties matter more than anything else here, and both come straight from
/// docs/04:
///
///  * **Nothing user-facing blocks on the network.** A save that cannot reach the server
///    is still a save — it lands here and the rep carries on.
///  * **The id is generated once.** A regenerated id on retry creates duplicate expenses,
///    which is the most expensive bug this whole design exists to prevent.
class OutboxNotifier extends StateNotifier<List<OutboxEntry>> {
  OutboxNotifier() : super(const []);

  static const _uuid = Uuid();

  /// Queues a mutation. Returns the entry so callers can show a pending badge.
  OutboxEntry enqueue({
    required String entity,
    required String entityId,
    required String operation,
    required String description,
  }) {
    final entry = OutboxEntry(
      id: _uuid.v4(),
      entity: entity,
      entityId: entityId,
      operation: operation,
      description: description,
      createdAt: DateTime.now(),
    );
    state = [...state, entry];
    return entry;
  }

  /// Called when a queued mutation reaches the server.
  void markSynced(String id) {
    state = state.map((e) => e.id == id ? e.copyWith(state: SyncState.synced) : e).toList();
  }

  void markFailed(String id, String error) {
    state = state
        .map((e) => e.id == id
            ? e.copyWith(state: SyncState.failed, attempts: e.attempts + 1, lastError: error)
            : e)
        .toList();
  }

  void remove(String id) => state = state.where((e) => e.id != id).toList();

  void clearSynced() =>
      state = state.where((e) => e.state != SyncState.synced).toList();

  /// Whether this exact entity already has work queued — used to avoid double-queueing
  /// when a rep taps save twice on a slow link.
  bool hasPendingFor(String entityId) =>
      state.any((e) => e.entityId == entityId && e.state == SyncState.pending);

  int get pendingCount => state.where((e) => e.state == SyncState.pending).length;
}
