using Microsoft.EntityFrameworkCore;
using Npgsql;
using Npgsql.NameTranslation;
using XMobile.Persistence.Enums;

namespace XMobile.Persistence;

/// <summary>
/// Wires the Npgsql provider to the enum types and PostGIS geography columns already defined by
/// db/schema/*.sql (schema-first — see XMobile.Persistence.csproj). An `NpgsqlDataSource` is
/// built once (per connection string) with every enum registered, then handed to
/// `UseNpgsql(dataSource)`; `RegisterEnumTypes` mirrors the same list onto the EF model so query
/// translation knows about them too.
/// </summary>
public static class XMobilePostgres
{
    // Exact-name translator: our C# enum members are spelled identically to the Postgres labels
    // (see Enums.cs), so no snake_case/camelCase translation should happen in either direction.
    private static readonly INpgsqlNameTranslator NoOpNameTranslator = new NpgsqlNullNameTranslator();

    public static NpgsqlDataSource BuildDataSource(string connectionString)
    {
        var builder = new NpgsqlDataSourceBuilder(connectionString);
        builder.UseNetTopologySuite();

        builder.MapEnum<UserStatus>("identity.user_status", NoOpNameTranslator);
        builder.MapEnum<DevicePlatform>("identity.device_platform", NoOpNameTranslator);
        builder.MapEnum<GeoSource>("customer.geo_source", NoOpNameTranslator);
        builder.MapEnum<AccountLifecycle>("customer.account_lifecycle", NoOpNameTranslator);
        builder.MapEnum<TourStatus>("planning.tour_status", NoOpNameTranslator);
        builder.MapEnum<DayActivity>("planning.day_activity", NoOpNameTranslator);
        builder.MapEnum<PlanStatus>("planning.plan_status", NoOpNameTranslator);
        builder.MapEnum<TravelMode>("tracking.travel_mode", NoOpNameTranslator);
        builder.MapEnum<VisitStatus>("visit.visit_status", NoOpNameTranslator);
        builder.MapEnum<CheckinMethod>("visit.checkin_method", NoOpNameTranslator);
        builder.MapEnum<TemplateStatus>("visit.template_status", NoOpNameTranslator);
        builder.MapEnum<ChangeOp>("sync.change_op", NoOpNameTranslator);
        builder.MapEnum<MutationOp>("sync.mutation_op", NoOpNameTranslator);
        builder.MapEnum<MutationStatus>("sync.mutation_status", NoOpNameTranslator);

        return builder.Build();
    }

    public static void RegisterEnumTypes(ModelBuilder modelBuilder)
    {
        modelBuilder.HasPostgresExtension("postgis");

        modelBuilder.HasPostgresEnum<UserStatus>("identity", "user_status", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<DevicePlatform>("identity", "device_platform", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<GeoSource>("customer", "geo_source", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<AccountLifecycle>("customer", "account_lifecycle", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<TourStatus>("planning", "tour_status", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<DayActivity>("planning", "day_activity", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<PlanStatus>("planning", "plan_status", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<TravelMode>("tracking", "travel_mode", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<VisitStatus>("visit", "visit_status", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<CheckinMethod>("visit", "checkin_method", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<TemplateStatus>("visit", "template_status", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<ChangeOp>("sync", "change_op", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<MutationOp>("sync", "mutation_op", NoOpNameTranslator);
        modelBuilder.HasPostgresEnum<MutationStatus>("sync", "mutation_status", NoOpNameTranslator);
    }
}
