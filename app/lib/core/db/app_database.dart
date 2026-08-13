// The local persistence layer docs/07-flutter-app.md §5 and docs/04-offline-sync.md §6
// describe: a Drift (SQLite) database mirroring the sync outbox. Only the outbox table exists
// this pass — see the plan's scope decisions in docs/10-roadmap.md §6 for why the full
// per-entity schema (customers/tours/visits/etc., mirroring MockApiClient's in-memory world)
// isn't built yet, and why this DB isn't SQLCipher-encrypted.

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../models/enums.dart';
import '../models/models.dart';

part 'app_database.g.dart';

/// Mirrors `OutboxEntry` (models.dart) plus the two protocol fields docs/04 §6 specifies
/// (`payload`, `baseVersion`) that no caller populates yet — added now so the real sync engine
/// doesn't need a migration the moment it lands.
@DataClassName('OutboxRow')
class OutboxEntries extends Table {
  TextColumn get id => text()();
  TextColumn get entity => text()();
  TextColumn get entityId => text()();
  TextColumn get operation => text()();
  TextColumn get description => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  TextColumn get state => text()();
  TextColumn get payload => text().nullable()();
  IntColumn get baseVersion => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [OutboxEntries])
class AppDatabase extends _$AppDatabase {
  /// Defaults to a real on-device file (via drift_flutter's platform-path lookup); tests pass
  /// `NativeDatabase.memory()` the same way `HttpApiClient` tests inject a fake `http.Client`.
  AppDatabase([QueryExecutor? executor]) : super(executor ?? driftDatabase(name: 'xmobile'));

  @override
  int get schemaVersion => 1;

  Stream<List<OutboxEntry>> watchOutboxEntries() =>
      select(outboxEntries).watch().map((rows) => rows.map(_toModel).toList());

  Future<void> insertOutboxEntry(OutboxEntry entry) => into(outboxEntries).insert(
        OutboxEntriesCompanion.insert(
          id: entry.id,
          entity: entry.entity,
          entityId: entry.entityId,
          operation: entry.operation,
          description: entry.description,
          createdAt: entry.createdAt,
          attempts: Value(entry.attempts),
          lastError: Value(entry.lastError),
          state: entry.state.wire,
        ),
      );

  /// Read-then-write inside the DB rather than trusting a caller-supplied snapshot: `enqueue`'s
  /// insert is fire-and-forget, so a `markSynced`/`markFailed` called immediately after could
  /// otherwise race a Riverpod-side cache that hasn't caught up with the stream yet.
  Future<void> markOutboxSynced(String id) =>
      (update(outboxEntries)..where((t) => t.id.equals(id)))
          .write(OutboxEntriesCompanion(state: Value(SyncState.synced.wire)));

  Future<void> markOutboxFailed(String id, String error) async {
    final row = await (select(outboxEntries)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;

    await (update(outboxEntries)..where((t) => t.id.equals(id))).write(OutboxEntriesCompanion(
      state: Value(SyncState.failed.wire),
      attempts: Value(row.attempts + 1),
      lastError: Value(error),
    ));
  }

  Future<void> deleteOutboxEntry(String id) =>
      (delete(outboxEntries)..where((t) => t.id.equals(id))).go();

  Future<void> deleteSyncedOutboxEntries() =>
      (delete(outboxEntries)..where((t) => t.state.equals(SyncState.synced.wire))).go();

  static OutboxEntry _toModel(OutboxRow row) => OutboxEntry(
        id: row.id,
        entity: row.entity,
        entityId: row.entityId,
        operation: row.operation,
        description: row.description,
        createdAt: row.createdAt,
        attempts: row.attempts,
        lastError: row.lastError,
        state: SyncState.values.firstWhere((s) => s.wire == row.state,
            orElse: () => SyncState.pending),
      );
}
