using System.Text.Json;

namespace XMobile.Shared;

// The sync pull/push protocol (docs/04-offline-sync.md) is generic over entity type, but
// XMobile.Sync — the module that implements the protocol machinery — must not reference every
// entity-owning module (that would make it depend on all of Identity/Customers/Planning/Visits,
// and grow with every module added afterwards). Instead each owning module registers one
// ISyncEntityHandler per syncable table it exposes into DI; XMobile.Sync consumes the whole
// IEnumerable<ISyncEntityHandler> and dispatches on Entity — same DIP shape as IVisitLookup et al.

public enum SyncApplyOutcome
{
    Applied,
    Conflict,
    Rejected,
    Deferred,
}

/// <summary>One mutation out of a `POST /v1/sync/push` batch, already stripped of the envelope
/// fields (clientMutationId/entity are handled by XMobile.Sync itself before dispatch).</summary>
public sealed record SyncMutationContext(
    Guid EntityId,
    string Op,
    long? BaseVersion,
    DateTimeOffset? OccurredAt,
    JsonElement Data,
    Guid UserId,
    Guid DeviceId);

public sealed record SyncApplyResult(
    SyncApplyOutcome Outcome,
    long? RowVersion = null,
    string? Reason = null,
    object? ServerData = null,
    IReadOnlyList<string>? Errors = null);

/// <summary>Implemented once per syncable table by the module that owns it (e.g.
/// XMobile.Planning implements one for `planning.tour`); consumed by XMobile.Sync.</summary>
public interface ISyncEntityHandler
{
    /// <summary>Matches `sync.change_log.entity` exactly, e.g. "planning.tour".</summary>
    string Entity { get; }

    /// <summary>True for reference-like data every device gets regardless of scope (e.g.
    /// `visit.form_template`) — see the pull scope predicate in XMobile.Sync.</summary>
    bool IsGlobal { get; }

    /// <summary>Current row, shaped as its normal read DTO, for a pull response's `data` field.
    /// Null if the row no longer exists (the caller already knows to send `op: DELETE` from
    /// `sync.change_log` in that case).</summary>
    Task<object?> GetPayloadAsync(Guid id, CancellationToken ct);

    /// <summary>Applies one push mutation. `ctx.BaseVersion == null` means "forced" — used when
    /// resolving a conflict as KEEP_CLIENT/MERGED, where the caller has already decided to
    /// override whatever is on the server.</summary>
    Task<SyncApplyResult> ApplyAsync(SyncMutationContext ctx, CancellationToken ct);
}

/// <summary>Implemented by XMobile.Customers; consumed by XMobile.Sync to scope pull to the
/// rep's assigned customers (docs/04 §4's `customer_id IN (...)` scope predicate).</summary>
public interface ICustomerScopeService
{
    Task<IReadOnlyList<Guid>> GetAssignedCustomerIdsAsync(Guid userId, CancellationToken ct);
}
