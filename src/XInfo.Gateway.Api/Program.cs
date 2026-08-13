using Microsoft.Extensions.Options;
using XInfo.Gateway.Api.Endpoints;
using XInfo.Gateway.Api.Infrastructure;
using XInfo.Gateway.Data.Repositories;
using XInfo.Gateway.Data.Sql;

var builder = WebApplication.CreateBuilder(args);

builder.Services.Configure<XInfoSqlOptions>(
    builder.Configuration.GetSection(XInfoSqlOptions.SectionName));

builder.Services.Configure<GatewayOptions>(
    builder.Configuration.GetSection(GatewayOptions.SectionName));

builder.Services.AddSingleton<ISqlExecutor, SqlExecutor>();
builder.Services.AddScoped<IPullRepository, SqlPullRepository>();
builder.Services.AddScoped<IPushRepository, SqlPushRepository>();

builder.Services.AddHttpContextAccessor();
builder.Services.AddHealthChecks().AddCheck<XInfoHealthCheck>("xinfo-sql");

// Only the XMobile backend calls this service — never a device, never a browser. A shared
// secret between two services on the same network is proportionate; anything token-based
// would need an issuer this deployment does not have.
builder.Services.AddAuthentication(ApiKeyAuthentication.SchemeName)
    .AddScheme<ApiKeyOptions, ApiKeyAuthenticationHandler>(ApiKeyAuthentication.SchemeName, _ => { });
builder.Services.AddAuthorization();

var app = builder.Build();

app.UseGatewayExceptionHandling();
app.UseAuthentication();
app.UseAuthorization();

// Authorisation is applied on the route groups themselves, so a new endpoint added to a
// group inherits it rather than relying on someone remembering.
app.MapPullEndpoints();
app.MapPushEndpoints();
app.MapOperationsEndpoints();

app.MapHealthChecks("/health/live");
app.MapHealthChecks("/health/ready");

// Fail loudly at startup if XInfo is missing procedures we depend on. A gateway that starts
// happily and then breaks at 6am when a rep submits an expense is worse than one that
// refuses to start.
var options = app.Services.GetRequiredService<IOptions<GatewayOptions>>().Value;
if (options.VerifyProceduresOnStartup)
{
    await app.VerifyXInfoProceduresAsync();
}

app.Run();

/// <summary>Exposed so the test host can boot the same pipeline.</summary>
public partial class Program;
