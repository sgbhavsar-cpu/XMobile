using Microsoft.AspNetCore.Http;
using XMobile.Shared;

namespace XMobile.Identity.Infrastructure;

/// <summary>
/// Reads the authenticated user off <see cref="HttpContext.User"/>. For the one anonymous
/// endpoint (dev-login) there is no principal yet, so this resolves to the
/// <see cref="Guid.Empty"/> sentinel rather than throwing — see XMobileDbContext.SaveChangesAsync.
/// </summary>
public sealed class HttpCurrentUser(IHttpContextAccessor accessor) : ICurrentUser
{
    private System.Security.Claims.ClaimsPrincipal? Principal => accessor.HttpContext?.User;

    public Guid UserId
    {
        get
        {
            var sub = Principal?.FindFirst(System.IdentityModel.Tokens.Jwt.JwtRegisteredClaimNames.Sub)?.Value;
            return sub is not null && Guid.TryParse(sub, out var id) ? id : Guid.Empty;
        }
    }

    public string EmployeeCode => Principal?.FindFirst(XMobileClaims.EmployeeCode)?.Value ?? string.Empty;

    public IReadOnlyList<string> Roles =>
        Principal?.FindAll(XMobileClaims.Role).Select(c => c.Value).ToArray() ?? [];
}
