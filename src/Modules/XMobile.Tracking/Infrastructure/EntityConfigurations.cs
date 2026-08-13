using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using XMobile.Persistence;
using XMobile.Tracking.Domain;

namespace XMobile.Tracking.Infrastructure;

// None of the plain `DEFAULT now()` timestamp columns here are trigger-maintained (unlike the
// syncable entities' created_at/updated_at), so they're left as ordinary properties the
// application sets explicitly via IClock rather than configured as DB-generated — simpler than
// teaching EF about a default it would otherwise have to read back on every insert.

public sealed class TrackingSessionConfig : IEntityTypeConfiguration<TrackingSession>
{
    public void Configure(EntityTypeBuilder<TrackingSession> builder)
    {
        builder.ToTable("tracking_session", "tracking");
        builder.HasKey(e => e.Id);
        builder.HasClientGeneratedKey();
    }
}

public sealed class TrackingPauseConfig : IEntityTypeConfiguration<TrackingPause>
{
    public void Configure(EntityTypeBuilder<TrackingPause> builder)
    {
        builder.ToTable("tracking_pause", "tracking");
        builder.HasKey(e => e.Id);
        builder.HasClientGeneratedKey();
    }
}

public sealed class LocationPingConfig : IEntityTypeConfiguration<LocationPing>
{
    public void Configure(EntityTypeBuilder<LocationPing> builder)
    {
        builder.ToTable("location_ping", "tracking");
        // Composite PK: Postgres requires the partition key (recorded_at) in every unique
        // constraint on a partitioned table.
        builder.HasKey(e => new { e.Id, e.RecordedAt });
        builder.Property(e => e.Id).ValueGeneratedNever();
        builder.Property(e => e.Geog).HasColumnType("geography(Point,4326)");
    }
}

public sealed class GeofenceEventConfig : IEntityTypeConfiguration<GeofenceEvent>
{
    public void Configure(EntityTypeBuilder<GeofenceEvent> builder)
    {
        builder.ToTable("geofence_event", "tracking");
        builder.HasKey(e => e.Id);
        builder.HasClientGeneratedKey();
        builder.Property(e => e.Geog).HasColumnType("geography(Point,4326)");
    }
}

public sealed class StayDetectionConfig : IEntityTypeConfiguration<StayDetection>
{
    public void Configure(EntityTypeBuilder<StayDetection> builder)
    {
        builder.ToTable("stay_detection", "tracking");
        builder.HasKey(e => e.Id);
        builder.HasClientGeneratedKey();
        builder.Property(e => e.Geog).HasColumnType("geography(Point,4326)");
    }
}

public sealed class DeviceHeartbeatConfig : IEntityTypeConfiguration<DeviceHeartbeat>
{
    public void Configure(EntityTypeBuilder<DeviceHeartbeat> builder)
    {
        builder.ToTable("device_heartbeat", "tracking");
        builder.HasKey(e => e.Id);
        builder.HasClientGeneratedKey();
        builder.Property(e => e.Details).HasColumnType("jsonb");
    }
}

public sealed class JourneyEventConfig : IEntityTypeConfiguration<JourneyEvent>
{
    public void Configure(EntityTypeBuilder<JourneyEvent> builder)
    {
        builder.ToTable("journey_event", "tracking");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.Property(e => e.Geog).HasColumnType("geography(Point,4326)");
        builder.Property(e => e.Evidence).HasColumnType("jsonb");
    }
}

public sealed class JourneySegmentConfig : IEntityTypeConfiguration<JourneySegment>
{
    public void Configure(EntityTypeBuilder<JourneySegment> builder)
    {
        builder.ToTable("journey_segment", "tracking");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.Property(e => e.Path).HasColumnType("geography(LineString,4326)");
        // DB-computed (`GENERATED ALWAYS AS ... STORED`) from started_at/ended_at.
        builder.Property(e => e.DurationS).ValueGeneratedOnAddOrUpdate();
    }
}

public sealed class TrackingAnomalyConfig : IEntityTypeConfiguration<TrackingAnomaly>
{
    public void Configure(EntityTypeBuilder<TrackingAnomaly> builder)
    {
        builder.ToTable("tracking_anomaly", "tracking");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.ConfigureSyncable();
        builder.Property(e => e.Details).HasColumnType("jsonb");
    }
}

public sealed class InferenceRunConfig : IEntityTypeConfiguration<InferenceRun>
{
    public void Configure(EntityTypeBuilder<InferenceRun> builder)
    {
        builder.ToTable("inference_run", "tracking");
        builder.HasKey(e => e.Id);
        builder.Property(e => e.Id).HasDefaultValueSql("gen_random_uuid()");
        builder.Property(e => e.ConfigSnapshot).HasColumnType("jsonb");
    }
}

public sealed class UserJourneyStateConfig : IEntityTypeConfiguration<UserJourneyState>
{
    public void Configure(EntityTypeBuilder<UserJourneyState> builder)
    {
        builder.ToTable("user_journey_state", "tracking");
        builder.HasKey(e => e.UserId);
        builder.Property(e => e.UserId).ValueGeneratedNever();
        builder.Property(e => e.LastPingGeog).HasColumnType("geography(Point,4326)");
    }
}
