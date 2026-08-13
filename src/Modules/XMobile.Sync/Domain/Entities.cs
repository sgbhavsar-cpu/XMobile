using XMobile.Persistence.Enums;

namespace XMobile.Sync.Domain;

/// <summary>Read-only from the app's side — every row is written by `config.fn_change_log`
/// triggers, never by application code (db/schema/00_extensions.sql).</summary>
public sealed class ChangeLogEntry
{
    public long Id { get; set; }
    public required string Entity { get; set; }
    public Guid? EntityId { get; set; }
    public required string EntityKey { get; set; }
    public ChangeOp Op { get; set; }
    public long RowVersion { get; set; }
    public Guid? OwnerUserId { get; set; }
    public Guid? CustomerId { get; set; }
    public DateTimeOffset ChangedAt { get; set; }
    public Guid? ChangedBy { get; set; }
}

/// <summary>The idempotency ledger for `POST /v1/sync/push` — PK is device-generated
/// (`client_mutation_id`), not server-generated, so replays are detectable.</summary>
public sealed class ClientMutation
{
    public Guid ClientMutationId { get; set; }
    public Guid DeviceId { get; set; }
    public Guid UserId { get; set; }
    public required string Entity { get; set; }
    public Guid EntityId { get; set; }
    public MutationOp Op { get; set; }
    public long? BaseVersion { get; set; }
    public DateTimeOffset? OccurredAt { get; set; }
    public DateTimeOffset ReceivedAt { get; set; }
    public MutationStatus Status { get; set; }
    public long? AppliedVersion { get; set; }
    public Guid? ConflictId { get; set; }
    public string? ErrorCode { get; set; }
    public string? ErrorDetail { get; set; }
    public string? PayloadHash { get; set; }
    public Guid? BatchId { get; set; }
}

public sealed class SyncConflict
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public Guid? DeviceId { get; set; }
    public required string Entity { get; set; }
    public Guid EntityId { get; set; }
    public Guid? ClientMutationId { get; set; }
    public required string Reason { get; set; }
    public required string Resolution { get; set; }
    public required string ClientPayload { get; set; }
    public string? ServerPayload { get; set; }
    public string? MergedPayload { get; set; }
    public DateTimeOffset DetectedAt { get; set; }
    public DateTimeOffset? AcknowledgedAt { get; set; }
    public DateTimeOffset? ResolvedAt { get; set; }
    public Guid? ResolvedBy { get; set; }
    public long RowVersion { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}
