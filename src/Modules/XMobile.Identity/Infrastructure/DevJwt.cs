using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using Microsoft.IdentityModel.Tokens;
using XMobile.Identity.Domain;

namespace XMobile.Identity.Infrastructure;

/// <summary>
/// Dev-mode bearer token, stands in for Keycloak until it is deployed (docs/06-security-identity.md
/// §1). Issuing (here) and validating (XMobile.Api's JwtBearer registration) both read this same
/// options class, so swapping in real Keycloak JWKS validation later only changes where the
/// signing key/issuer come from — the claims and every downstream `ICurrentUser` consumer stay
/// unchanged.
/// </summary>
public sealed class DevJwtOptions
{
    public const string SectionName = "DevJwt";

    /// <summary>HS256 signing key. Injected via configuration, never committed.</summary>
    public string SigningKey { get; set; } = string.Empty;

    public string Issuer { get; set; } = "xmobile-dev";
    public string Audience { get; set; } = "xmobile-api";
    public int AccessTokenMinutes { get; set; } = 15;

    public SymmetricSecurityKey Key => new(Encoding.UTF8.GetBytes(SigningKey));
}

/// <summary>Claim type names shared by the issuer and the validator.</summary>
public static class XMobileClaims
{
    public const string EmployeeCode = "employee_code";
    public const string Role = "role";
}

public interface IDevTokenIssuer
{
    string IssueToken(AppUser user, IReadOnlyList<string> roles);
}

public sealed class DevTokenIssuer(Microsoft.Extensions.Options.IOptions<DevJwtOptions> options) : IDevTokenIssuer
{
    public string IssueToken(AppUser user, IReadOnlyList<string> roles)
    {
        var opts = options.Value;
        if (string.IsNullOrWhiteSpace(opts.SigningKey))
        {
            throw new InvalidOperationException(
                $"{DevJwtOptions.SectionName}:SigningKey is not configured; refusing to issue tokens.");
        }

        var claims = new List<Claim>
        {
            new(JwtRegisteredClaimNames.Sub, user.Id.ToString()),
            new(XMobileClaims.EmployeeCode, user.EmployeeCode),
        };
        claims.AddRange(roles.Select(role => new Claim(XMobileClaims.Role, role)));

        var token = new JwtSecurityToken(
            issuer: opts.Issuer,
            audience: opts.Audience,
            claims: claims,
            expires: DateTime.UtcNow.AddMinutes(opts.AccessTokenMinutes),
            signingCredentials: new SigningCredentials(opts.Key, SecurityAlgorithms.HmacSha256));

        return new JwtSecurityTokenHandler().WriteToken(token);
    }
}
