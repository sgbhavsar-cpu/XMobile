import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
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
///
/// Backed by a Drift table (`app/lib/core/db/app_database.dart`) so the queue survives an app
/// restart — `state` is a live projection of a `watchOutboxEntries()` stream, not the source of
/// truth itself; every mutating method below writes through to the database, and the stream
/// subscription is what updates `state` afterward. The public API is unchanged from the
/// in-memory version this replaces, so none of its callers needed to change.
class OutboxNotifier extends StateNotifier<List<OutboxEntry>> {
  OutboxNotifier(this._db) : super(const []) {
    _subscription = _db.watchOutboxEntries().listen((entries) => state = entries);
  }

  final AppDatabase _db;
  late final StreamSubscription<List<OutboxEntry>> _subscription;

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
    unawaited(_db.insertOutboxEntry(entry));
    return entry;
  }

  /// Called when a queued mutation reaches the server.
  void markSynced(String id) => unawaited(_db.markOutboxSynced(id));

  void markFailed(String id, String error) => unawaited(_db.markOutboxFailed(id, error));

  void remove(String id) => unawaited(_db.deleteOutboxEntry(id));

  void clearSynced() => unawaited(_db.deleteSyncedOutboxEntries());

  /// Whether this exact entity already has work queued — used to avoid double-queueing
  /// when a rep taps save twice on a slow link.
  bool hasPendingFor(String entityId) =>
      state.any((e) => e.entityId == entityId && e.state == SyncState.pending);

  int get pendingCount => state.where((e) => e.state == SyncState.pending).length;

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
