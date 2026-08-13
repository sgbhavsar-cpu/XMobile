namespace XMobile.Shared;

/// <summary>
/// The authenticated caller, resolved once per request from the bearer token's claims.
/// Implemented in XMobile.Api against HttpContext; consumed by every module (repository scope
/// predicates) and by XMobile.Persistence (the `xmobile.actor_id` write-path setting).
/// </summary>
public interface ICurrentUser
{
    Guid UserId { get; }
    string EmployeeCode { get; }
    IReadOnlyList<string> Roles { get; }
    bool IsInRole(string role) => Roles.Contains(role, StringComparer.OrdinalIgnoreCase);
}
