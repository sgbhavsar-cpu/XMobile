using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;
using XMobile.Api.Infrastructure;
using XMobile.Customers;
using XMobile.Customers.Endpoints;
using XMobile.Identity;
using XMobile.Identity.Endpoints;
using XMobile.Identity.Infrastructure;
using XMobile.Persistence;
using XMobile.Planning;
using XMobile.Planning.Endpoints;
using XMobile.Shared;
using XMobile.Sync;
using XMobile.Sync.Endpoints;
using XMobile.Visits;
using XMobile.Visits.Endpoints;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddXMobilePersistence();

// Order doesn't matter for DI resolution (see PersistenceModelOptions), but Identity comes first
// because every other module consumes ICurrentUser/IUserScopeService, which it registers.
builder.Services.AddIdentityModule(builder.Configuration);
builder.Services.AddCustomersModule();
builder.Services.AddPlanningModule();
builder.Services.AddVisitsModule();
builder.Services.AddSyncModule();

builder.Services.AddSingleton<IClock, SystemClock>();

// See XMobile.Identity.Infrastructure.DevJwtOptions: the dev-mode bearer token stands in for
// Keycloak (docs/06-security-identity.md §1) until it is deployed. Swapping in real JWKS
// validation later only changes this block.
//
// JwtBearerOptions is configured via the DI-resolved IOptions<DevJwtOptions> (Configure<TDep>)
// rather than read directly off `builder.Configuration` here — reading it eagerly, before
// `builder.Build()`, would miss any configuration override applied at host-build time (as
// XMobile.Api.Tests' WebApplicationFactory does for the test signing key and connection string;
// see the AddXMobilePersistence remarks for the same reasoning).
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer();
builder.Services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
    .Configure<IOptions<DevJwtOptions>>((options, devJwt) =>
    {
        // Without this, JwtSecurityTokenHandler's legacy inbound claim map silently renames
        // "sub" to the long http://schemas.xmlsoap.org/.../nameidentifier URI on validation, so
        // every ICurrentUser.UserId lookup (which reads the literal "sub" claim type) resolves
        // to the Guid.Empty sentinel instead of the authenticated user.
        options.MapInboundClaims = false;
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = devJwt.Value.Issuer,
            ValidateAudience = true,
            ValidAudience = devJwt.Value.Audience,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            IssuerSigningKey = devJwt.Value.Key,
            RoleClaimType = XMobileClaims.Role,
        };
    });
builder.Services.AddAuthorization();

builder.Services.AddHealthChecks();

var app = builder.Build();

app.UseApiExceptionHandling();
app.UseAuthentication();
app.UseAuthorization();

app.MapAuthEndpoints();
app.MapCustomerEndpoints();
app.MapTourEndpoints();
app.MapVisitEndpoints();
app.MapSyncEndpoints();

app.MapHealthChecks("/health/live");
app.MapHealthChecks("/health/ready");

app.Run();

/// <summary>Exposed so the test host can boot the same pipeline.</summary>
public partial class Program;
