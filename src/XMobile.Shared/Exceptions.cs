namespace XMobile.Shared;

/// <summary>The requested resource does not exist, or is outside the caller's visibility scope.</summary>
public sealed class NotFoundException(string message) : Exception(message);

/// <summary>Request failed FluentValidation or an application-level invariant.</summary>
public sealed class DomainValidationException(string message, IReadOnlyDictionary<string, string[]>? errors = null)
    : Exception(message)
{
    public IReadOnlyDictionary<string, string[]> Errors { get; } = errors ?? new Dictionary<string, string[]>();
}

/// <summary>
/// A write was rejected because the caller's <c>baseVersion</c> is stale, or the target row is in
/// an immutable state (e.g. a submitted visit report). Maps to 409 so the client's sync layer can
/// treat it the same way it will treat a `/v1/sync/push` CONFLICT once that exists.
/// </summary>
public sealed class StateConflictException(string message) : Exception(message);

/// <summary>The caller is authenticated but not permitted to act on this resource.</summary>
public sealed class ForbiddenException(string message) : Exception(message);
