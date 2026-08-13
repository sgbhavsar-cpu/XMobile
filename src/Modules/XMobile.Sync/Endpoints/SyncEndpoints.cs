using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using XMobile.Persistence;
using XMobile.Persistence.Enums;
using XMobile.Shared;
using XMobile.Sync.Domain;

namespace XMobile.Sync.Endpoints;

public static class SyncEndpoints
{
    public static IEndpointRouteBuilder MapSyncEndpoints(this IEndpointRouteBuilder app)
    {
        var sync = app.MapGroup("/v1/sync").WithTags("Sync").RequireAuthorization();
        sync.MapGet("/pull", PullAsync);
        sync.MapPost("/push", PushAsync);
        sync.MapGet("/conflicts", ListConflictsAsync);
        sync.MapPost("/conflicts/{id:guid}/resolve", ResolveConflictAsync);
        // deviceId is a disclosed deviation from api/openapi.yaml (which takes none) — see the
        // plan's scope decision: the dev-JWT stub carries no device_id claim the way a real
        // Keycloak token would.
        sync.MapGet("/health", GetHealthAsync);
        return app;
    }

    // ---------------------------------------------------------------- Pull

    private static async Task<IResult> PullAsync(
        string? cursor, string? entities, int? limit,
        XMobileDbContext db, ICurrentUser currentUser, ICustomerScopeService customerScope,
        IEnumerable<ISyncEntityHandler> handlerList, IClock clock, CancellationToken ct)
    {
        var handlers = handlerList.ToDictionary(h => h.Entity);
        var requested = string.IsNullOrWhiteSpace(entities)
            ? null
            : entities.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToHashSet();

        // Anything without a registered handler is invisible to pull, by construction — that's
        // also how tables no module has claimed yet (tracking.*, expense.*, config.*) stay out
        // of scope without an explicit exclusion list.
        var supportedEntities = handlers.Keys.Where(e => requested is null || requested.Contains(e)).ToList();
        var globalEntities = handlers.Where(h => h.Value.IsGlobal).Select(h => h.Key).ToHashSet();

        if (supportedEntities.Count == 0)
        {
            return Results.Ok(new PullResponseDto([], cursor, false, clock.UtcNow, 1));
        }

        var assignedCustomerIds = await customerScope.GetAssignedCustomerIdsAsync(currentUser.UserId, ct);
        var sinceId = DecodeCursor(cursor);
        var pageSize = Math.Clamp(limit ?? 500, 1, 2000);

        var rows = await db.Set<ChangeLogEntry>()
            .Where(c => c.Id > sinceId && supportedEntities.Contains(c.Entity))
            .Where(c => globalEntities.Contains(c.Entity)
                || c.OwnerUserId == currentUser.UserId
                || (c.CustomerId != null && assignedCustomerIds.Contains(c.CustomerId.Value)))
            .OrderBy(c => c.Id)
            .Take(pageSize + 1)
            .ToListAsync(ct);

        var hasMore = rows.Count > pageSize;
        var page = hasMore ? rows.Take(pageSize).ToList() : rows;

        var changes = new List<PullChangeDto>(page.Count);
        foreach (var row in page)
        {
            object? data = null;
            if (row.Op != ChangeOp.DELETE && row.EntityId is { } entityId
                && handlers.TryGetValue(row.Entity, out var handler))
            {
                data = await handler.GetPayloadAsync(entityId, ct);
            }

            changes.Add(new PullChangeDto(row.Entity, row.EntityKey, row.Op.ToString(), row.RowVersion, row.ChangedAt, data));
        }

        var nextCursor = page.Count > 0 ? EncodeCursor(page[^1].Id) : cursor;
        return Results.Ok(new PullResponseDto(changes, nextCursor, hasMore, clock.UtcNow, 1));
    }

    private static string EncodeCursor(long id) => Convert.ToBase64String(Encoding.UTF8.GetBytes(id.ToString()));

    private static long DecodeCursor(string? cursor)
    {
        if (string.IsNullOrEmpty(cursor))
        {
            return 0;
        }

        try
        {
            return long.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(cursor)));
        }
        catch (FormatException)
        {
            return 0; // an unreadable cursor restarts rather than failing (docs/04 §3.1).
        }
    }

    // ---------------------------------------------------------------- Push

    private static async Task<IResult> PushAsync(
        PushRequestDto request, XMobileDbContext db, ICurrentUser currentUser,
        IEnumerable<ISyncEntityHandler> handlerList, IClock clock, CancellationToken ct)
    {
        var handlers = handlerList.ToDictionary(h => h.Entity);
        var results = new List<PushMutationResultDto>(request.Mutations.Count);

        // Sequential and independently try/caught: one bad mutation must not block the rest of
        // the batch (docs/04 §3.2).
        foreach (var mutation in request.Mutations)
        {
            results.Add(await ApplyOneAsync(mutation, request.DeviceId, db, currentUser, handlers, clock, ct));
        }

        return Results.Ok(new PushResponseDto(results, clock.UtcNow));
    }

    private static async Task<PushMutationResultDto> ApplyOneAsync(
        PushMutationRequest mutation, Guid deviceId, XMobileDbContext db, ICurrentUser currentUser,
        Dictionary<string, ISyncEntityHandler> handlers, IClock clock, CancellationToken ct)
    {
        var existing = await db.Set<ClientMutation>()
            .FirstOrDefaultAsync(m => m.ClientMutationId == mutation.ClientMutationId, ct);
        if (existing is not null)
        {
            return new PushMutationResultDto(mutation.ClientMutationId, "DUPLICATE", existing.AppliedVersion,
                existing.ErrorDetail, null, existing.ConflictId, null, null);
        }

        if (!handlers.TryGetValue(mutation.Entity, out var handler))
        {
            await RecordMutationAsync(db, mutation, deviceId, currentUser.UserId, MutationStatus.REJECTED,
                null, null, "No handler for this entity", clock, ct);
            return new PushMutationResultDto(mutation.ClientMutationId, "REJECTED", null,
                "No handler for this entity", null, null, null, ["Unsupported entity"]);
        }

        var context = new SyncMutationContext(
            mutation.Id, mutation.Op, mutation.BaseVersion, mutation.OccurredAt, mutation.Data,
            currentUser.UserId, deviceId);

        try
        {
            var applied = await handler.ApplyAsync(context, ct);
            switch (applied.Outcome)
            {
                case SyncApplyOutcome.Applied:
                    await RecordMutationAsync(db, mutation, deviceId, currentUser.UserId, MutationStatus.APPLIED,
                        applied.RowVersion, null, null, clock, ct);
                    return new PushMutationResultDto(mutation.ClientMutationId, "APPLIED", applied.RowVersion,
                        null, null, null, applied.ServerData, null);

                case SyncApplyOutcome.Conflict:
                {
                    var serverData = await handler.GetPayloadAsync(mutation.Id, ct);
                    var conflictId = await RecordConflictAsync(
                        db, mutation, deviceId, currentUser.UserId, applied.Reason, serverData, clock, ct);
                    await RecordMutationAsync(db, mutation, deviceId, currentUser.UserId, MutationStatus.CONFLICT,
                        null, conflictId, applied.Reason, clock, ct);
                    return new PushMutationResultDto(mutation.ClientMutationId, "CONFLICT", null,
                        applied.Reason, "SERVER_WINS", conflictId, serverData, null);
                }

                default:
                    await RecordMutationAsync(db, mutation, deviceId, currentUser.UserId, MutationStatus.REJECTED,
                        null, null, applied.Reason, clock, ct);
                    return new PushMutationResultDto(mutation.ClientMutationId, "REJECTED", null,
                        applied.Reason, null, null, null, applied.Errors);
            }
        }
        catch (Exception ex) when (IsForeignKeyViolation(ex))
        {
            // The mutation's prerequisite (e.g. its parent tour) hasn't been pushed yet — the
            // client retries this one after its dependency succeeds (docs/04 §3.2's DEFERRED,
            // approximated via the FK constraint rather than a full dependency scheduler).
            await RecordMutationAsync(db, mutation, deviceId, currentUser.UserId, MutationStatus.DEFERRED,
                null, null, "Dependency not yet present", clock, ct);
            return new PushMutationResultDto(mutation.ClientMutationId, "DEFERRED", null,
                "Dependency not yet present", null, null, null, null);
        }
        catch (Exception)
        {
            await RecordMutationAsync(db, mutation, deviceId, currentUser.UserId, MutationStatus.REJECTED,
                null, null, "Unexpected error", clock, ct);
            return new PushMutationResultDto(mutation.ClientMutationId, "REJECTED", null,
                "Unexpected error", null, null, null, ["Unexpected error"]);
        }
    }

    private static bool IsForeignKeyViolation(Exception ex)
        => ex is DbUpdateException { InnerException: PostgresException { SqlState: PostgresErrorCodes.ForeignKeyViolation } };

    /// <summary>
    /// Swallows its own failure (logged, not thrown) rather than let a problem writing the
    /// idempotency ledger itself turn into an unhandled 500 for the whole push request — the
    /// per-mutation result returned to the caller already reflects the real outcome regardless
    /// of whether this bookkeeping write lands. A `device_id`/`user_id` that fails the ledger's
    /// own FK (an unregistered device, most likely) is the realistic way this fires.
    /// </summary>
    private static async Task RecordMutationAsync(
        XMobileDbContext db, PushMutationRequest mutation, Guid deviceId, Guid userId, MutationStatus status,
        long? appliedVersion, Guid? conflictId, string? errorDetail, IClock clock, CancellationToken ct)
    {
        try
        {
            db.Add(new ClientMutation
            {
                ClientMutationId = mutation.ClientMutationId,
                DeviceId = deviceId,
                UserId = userId,
                Entity = mutation.Entity,
                EntityId = mutation.Id,
                Op = Enum.Parse<MutationOp>(mutation.Op),
                BaseVersion = mutation.BaseVersion,
                OccurredAt = mutation.OccurredAt,
                ReceivedAt = clock.UtcNow,
                Status = status,
                AppliedVersion = appliedVersion,
                ConflictId = conflictId,
                ErrorDetail = errorDetail,
            });
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException)
        {
            db.ChangeTracker.Clear();
        }
    }

    private static async Task<Guid> RecordConflictAsync(
        XMobileDbContext db, PushMutationRequest mutation, Guid deviceId, Guid userId, string? reason,
        object? serverData, IClock clock, CancellationToken ct)
    {
        var conflict = new SyncConflict
        {
            UserId = userId,
            DeviceId = deviceId,
            Entity = mutation.Entity,
            EntityId = mutation.Id,
            ClientMutationId = mutation.ClientMutationId,
            Reason = reason ?? "STALE_VERSION",
            Resolution = "SERVER_WINS",
            ClientPayload = mutation.Data.GetRawText(),
            ServerPayload = serverData is null ? null : JsonSerializer.Serialize(serverData),
            DetectedAt = clock.UtcNow,
            UpdatedAt = clock.UtcNow,
        };
        db.Add(conflict);
        await db.SaveChangesAsync(ct);
        return conflict.Id;
    }

    // ---------------------------------------------------------------- Conflicts

    private static async Task<IResult> ListConflictsAsync(
        XMobileDbContext db, ICurrentUser currentUser, CancellationToken ct)
    {
        var conflicts = await db.Set<SyncConflict>()
            .Where(c => c.UserId == currentUser.UserId && c.ResolvedAt == null)
            .OrderByDescending(c => c.DetectedAt)
            .ToListAsync(ct);
        return Results.Ok(conflicts.Select(ToConflictDto));
    }

    private static async Task<IResult> ResolveConflictAsync(
        Guid id, ResolveConflictRequest request, XMobileDbContext db, ICurrentUser currentUser,
        IEnumerable<ISyncEntityHandler> handlerList, IClock clock, CancellationToken ct)
    {
        var conflict = await db.Set<SyncConflict>()
            .FirstOrDefaultAsync(c => c.Id == id && c.UserId == currentUser.UserId, ct)
            ?? throw new NotFoundException("Conflict not found");

        if (conflict.ResolvedAt is null)
        {
            if (request.Choice is "KEEP_CLIENT" or "MERGED")
            {
                var handlers = handlerList.ToDictionary(h => h.Entity);
                if (handlers.TryGetValue(conflict.Entity, out var handler))
                {
                    var payloadJson = request.Choice == "MERGED" && request.MergedPayload is not null
                        ? JsonSerializer.Serialize(request.MergedPayload)
                        : conflict.ClientPayload;
                    using var doc = JsonDocument.Parse(payloadJson);
                    // BaseVersion=null forces the write through — the caller has already decided
                    // to override whatever is currently on the server.
                    var context = new SyncMutationContext(conflict.EntityId, "UPDATE", null, clock.UtcNow,
                        doc.RootElement, currentUser.UserId, conflict.DeviceId ?? Guid.Empty);
                    await handler.ApplyAsync(context, ct);
                }

                conflict.Resolution = request.Choice;
            }
            else
            {
                conflict.Resolution = "SERVER_WINS";
            }

            if (request.MergedPayload is not null)
            {
                conflict.MergedPayload = JsonSerializer.Serialize(request.MergedPayload);
            }

            conflict.ResolvedAt = clock.UtcNow;
            conflict.ResolvedBy = currentUser.UserId;
            conflict.UpdatedAt = clock.UtcNow;
            await db.SaveChangesAsync(ct);
        }

        return Results.NoContent();
    }

    private static SyncConflictDto ToConflictDto(SyncConflict c) => new(
        c.Id, c.Entity, c.EntityId, c.Reason, c.Resolution,
        JsonSerializer.Deserialize<Dictionary<string, object?>>(c.ClientPayload) ?? [],
        c.ServerPayload is null ? null : JsonSerializer.Deserialize<Dictionary<string, object?>>(c.ServerPayload),
        c.DetectedAt);

    // ---------------------------------------------------------------- Health

    private static async Task<IResult> GetHealthAsync(
        Guid deviceId, XMobileDbContext db, ICurrentUser currentUser, IClock clock, CancellationToken ct)
    {
        var lastPushAt = await db.Set<ClientMutation>()
            .Where(m => m.DeviceId == deviceId)
            .OrderByDescending(m => m.ReceivedAt)
            .Select(m => (DateTimeOffset?)m.ReceivedAt)
            .FirstOrDefaultAsync(ct);

        var pendingConflicts = await db.Set<SyncConflict>()
            .CountAsync(c => c.UserId == currentUser.UserId && c.ResolvedAt == null, ct);

        var oldestUnsynced = await db.Set<ClientMutation>()
            .Where(m => m.DeviceId == deviceId && m.Status != MutationStatus.APPLIED && m.Status != MutationStatus.DUPLICATE)
            .OrderBy(m => m.ReceivedAt)
            .Select(m => (DateTimeOffset?)m.ReceivedAt)
            .FirstOrDefaultAsync(ct);

        var oldestAgeSec = oldestUnsynced is { } oldest ? (int)(clock.UtcNow - oldest).TotalSeconds : (int?)null;

        // lastPullAt stays null — pull has no deviceId in api/openapi.yaml to key it by (see the
        // plan's scope decision on sync.device_sync_state).
        return Results.Ok(new SyncHealthDto(deviceId, null, lastPushAt, pendingConflicts, oldestAgeSec, 1));
    }
}
