using System.Text.Json;

namespace XMobile.Sync;

// Wire DTOs mirror api/openapi.yaml component schemas (Sync section).

public sealed record PullChangeDto(
    string Entity, string Id, string Op, long RowVersion, DateTimeOffset UpdatedAt, object? Data);

public sealed record PullResponseDto(
    IReadOnlyList<PullChangeDto> Changes, string? NextCursor, bool HasMore,
    DateTimeOffset ServerTime, int PolicyVersion);

public sealed record PushMutationRequest(
    Guid ClientMutationId, string Entity, Guid Id, string Op, long? BaseVersion,
    DateTimeOffset? OccurredAt, JsonElement Data);

public sealed record PushRequestDto(Guid DeviceId, DateTimeOffset? DeviceTime, IReadOnlyList<PushMutationRequest> Mutations);

public sealed record PushMutationResultDto(
    Guid ClientMutationId, string Status, long? RowVersion, string? Reason, string? Resolution,
    Guid? ConflictId, object? ServerData, IReadOnlyList<string>? Errors);

public sealed record PushResponseDto(IReadOnlyList<PushMutationResultDto> Results, DateTimeOffset ServerTime);

public sealed record SyncConflictDto(
    Guid Id, string Entity, Guid EntityId, string Reason, string Resolution,
    Dictionary<string, object?> ClientPayload, Dictionary<string, object?>? ServerPayload, DateTimeOffset DetectedAt);

public sealed record ResolveConflictRequest(string Choice, Dictionary<string, object?>? MergedPayload);

public sealed record SyncHealthDto(
    Guid DeviceId, DateTimeOffset? LastPullAt, DateTimeOffset? LastPushAt, int PendingConflicts,
    int? OldestUnsyncedAgeSec, int PolicyVersion);
