-- =====================================================================
-- XMobile — 04 Tracking: raw evidence, inference output, anomalies
-- Raw evidence is append-only. Derived rows are rebuildable (docs/03 §7).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tracking sessions: one per continuous tracking period on one device
-- ---------------------------------------------------------------------
CREATE TABLE tracking.tracking_session (
    id              uuid PRIMARY KEY,                   -- client-generated UUIDv7
    user_id         uuid NOT NULL REFERENCES identity.app_user(id),
    device_id       uuid NOT NULL REFERENCES identity.device(id),
    tour_id         uuid REFERENCES planning.tour(id),
    started_at      timestamptz NOT NULL,
    ended_at        timestamptz,
    start_reason    text NOT NULL CHECK (start_reason IN ('SCHEDULE','TOUR_START','MANUAL','GEOFENCE','REBOOT')),
    end_reason      text CHECK (end_reason IN ('SCHEDULE','TOUR_END','MANUAL','APP_KILLED','PERMISSION_LOST','TIMEOUT')),
    status          tracking.session_status NOT NULL DEFAULT 'ACTIVE',
    app_version     text,
    os_version      text,
    ping_count      integer NOT NULL DEFAULT 0,
    row_version     bigint NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_session_user   ON tracking.tracking_session (user_id, started_at DESC);
CREATE INDEX ix_session_active ON tracking.tracking_session (user_id) WHERE status = 'ACTIVE';

CREATE TABLE tracking.tracking_pause (
    id            uuid PRIMARY KEY,
    session_id    uuid NOT NULL REFERENCES tracking.tracking_session(id) ON DELETE CASCADE,
    user_id       uuid NOT NULL REFERENCES identity.app_user(id),
    paused_at     timestamptz NOT NULL,
    resumed_at    timestamptz,
    reason_code   text NOT NULL,          -- config.reason_code(domain='TRACKING_PAUSE')
    reason_text   text,
    auto_resumed  boolean NOT NULL DEFAULT false,
    resumed_by    text CHECK (resumed_by IN ('USER','AUTO_TIMEOUT','SESSION_END')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_pause_period CHECK (resumed_at IS NULL OR resumed_at >= paused_at)
);
CREATE INDEX ix_pause_user ON tracking.tracking_pause (user_id, paused_at DESC);

-- ---------------------------------------------------------------------
-- Location pings — highest volume table, RANGE partitioned by month.
-- PK includes the partition key as Postgres requires.
-- ---------------------------------------------------------------------
CREATE TABLE tracking.location_ping (
    id               uuid        NOT NULL,        -- client-generated; dedupe key with user_id
    user_id          uuid        NOT NULL,
    device_id        uuid        NOT NULL,
    session_id       uuid,
    recorded_at      timestamptz NOT NULL,        -- device clock
    received_at      timestamptz NOT NULL DEFAULT now(),
    corrected_at     timestamptz,                 -- recorded_at adjusted for device clock skew
    geog             geography(Point,4326) NOT NULL,
    accuracy_m       real,
    altitude_m       real,
    speed_mps        real,
    speed_accuracy   real,
    heading_deg      real,
    activity_type    text,                        -- still / walking / running / on_bicycle / in_vehicle / unknown
    activity_conf    smallint,
    is_moving        boolean,
    battery_pct      smallint,
    is_charging      boolean,
    provider         text,                        -- gps / fused / network / passive
    is_mock          boolean NOT NULL DEFAULT false,
    source           tracking.ping_source NOT NULL DEFAULT 'FG_SERVICE',
    is_off_window    boolean NOT NULL DEFAULT false,   -- arrived outside the tracking window
    seq              bigint,                      -- client monotonic counter, gap detection
    device_tz        text,
    tz_offset_min    smallint,
    created_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, recorded_at)
) PARTITION BY RANGE (recorded_at);

-- Partition helper: create months on demand (a scheduled job calls this ahead of time).
CREATE OR REPLACE FUNCTION tracking.fn_ensure_ping_partition(p_month date)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_start date := date_trunc('month', p_month)::date;
    v_end   date := (date_trunc('month', p_month) + interval '1 month')::date;
    v_name  text := format('location_ping_%s', to_char(v_start, 'YYYYMM'));
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'tracking' AND c.relname = v_name) THEN
        EXECUTE format(
            'CREATE TABLE tracking.%I PARTITION OF tracking.location_ping FOR VALUES FROM (%L) TO (%L)',
            v_name, v_start, v_end);
        EXECUTE format('CREATE INDEX %I ON tracking.%I (user_id, recorded_at)', 'ix_'||v_name||'_user', v_name);
        EXECUTE format('CREATE INDEX %I ON tracking.%I USING gist (geog)',      'ix_'||v_name||'_geog', v_name);
        EXECUTE format('CREATE INDEX %I ON tracking.%I (session_id)',           'ix_'||v_name||'_sess', v_name);
    END IF;
    RETURN v_name;
END $$;

-- Bootstrap: current month ± 1
SELECT tracking.fn_ensure_ping_partition((CURRENT_DATE - interval '1 month')::date);
SELECT tracking.fn_ensure_ping_partition(CURRENT_DATE);
SELECT tracking.fn_ensure_ping_partition((CURRENT_DATE + interval '1 month')::date);

-- ---------------------------------------------------------------------
-- Geofence transitions reported by the OS (the highest-value evidence)
-- ---------------------------------------------------------------------
CREATE TABLE tracking.geofence_event (
    id             uuid PRIMARY KEY,                -- client-generated
    user_id        uuid NOT NULL REFERENCES identity.app_user(id),
    device_id      uuid NOT NULL REFERENCES identity.device(id),
    session_id     uuid REFERENCES tracking.tracking_session(id),
    geofence_id    uuid NOT NULL REFERENCES customer.geofence(id),
    event_type     text NOT NULL CHECK (event_type IN ('ENTER','EXIT','DWELL')),
    occurred_at    timestamptz NOT NULL,
    received_at    timestamptz NOT NULL DEFAULT now(),
    geog           geography(Point,4326),
    accuracy_m     real,
    dwell_sec      integer,
    os_confidence  smallint,
    is_mock        boolean NOT NULL DEFAULT false,
    processed_at   timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_gfe_user_time ON tracking.geofence_event (user_id, occurred_at);
CREATE INDEX ix_gfe_unprocessed ON tracking.geofence_event (user_id) WHERE processed_at IS NULL;

-- iOS CLVisit / Android stationary detections: strong dwell corroboration
CREATE TABLE tracking.stay_detection (
    id            uuid PRIMARY KEY,
    user_id       uuid NOT NULL REFERENCES identity.app_user(id),
    device_id     uuid NOT NULL REFERENCES identity.device(id),
    arrived_at    timestamptz NOT NULL,
    departed_at   timestamptz,
    geog          geography(Point,4326) NOT NULL,
    horizontal_accuracy_m real,
    source        text NOT NULL CHECK (source IN ('IOS_VISIT','ANDROID_STATIONARY','CLUSTER')),
    matched_ref_type text CHECK (matched_ref_type IN ('HOME','CUSTOMER_SITE','UNKNOWN')),
    matched_ref_id   uuid,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_stay_user ON tracking.stay_detection (user_id, arrived_at DESC);
CREATE INDEX ix_stay_geog ON tracking.stay_detection USING gist (geog);

-- Client heartbeat: tracking health even when no movement is happening
CREATE TABLE tracking.device_heartbeat (
    id                uuid PRIMARY KEY,
    device_id         uuid NOT NULL REFERENCES identity.device(id),
    user_id           uuid NOT NULL REFERENCES identity.app_user(id),
    reported_at       timestamptz NOT NULL,
    received_at       timestamptz NOT NULL DEFAULT now(),
    battery_pct       smallint,
    is_power_saving   boolean,
    location_enabled  boolean,
    permission_level  text,
    service_running   boolean,
    queued_pings      integer,
    queued_mutations  integer,
    network_type      text,
    app_version       text,
    clock_skew_sec    integer,
    details           jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX ix_heartbeat_device ON tracking.device_heartbeat (device_id, reported_at DESC);

-- ---------------------------------------------------------------------
-- Inference output: journey events (transitions)
-- ---------------------------------------------------------------------
CREATE TABLE tracking.journey_event (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            uuid NOT NULL REFERENCES identity.app_user(id),
    tour_id            uuid REFERENCES planning.tour(id),
    event_type         tracking.journey_event_type NOT NULL,
    occurred_at        timestamptz NOT NULL,
    detected_at        timestamptz NOT NULL DEFAULT now(),
    local_date         date NOT NULL,               -- device-local business date
    device_tz          text,
    geog               geography(Point,4326),
    ref_type           text CHECK (ref_type IN ('HOME','CUSTOMER_SITE','STAY','NONE')),
    ref_id             uuid,
    site_id            uuid REFERENCES customer.customer_site(id),
    detection_method   tracking.detection_method NOT NULL,
    confidence         numeric(3,2) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    status             tracking.event_status NOT NULL DEFAULT 'DETECTED',
    is_estimated       boolean NOT NULL DEFAULT false,
    evidence           jsonb NOT NULL DEFAULT '{}'::jsonb,   -- ping ids, geofence event ids, rule scores
    -- correction trail
    original_occurred_at timestamptz,
    overridden_by      uuid REFERENCES identity.app_user(id),
    overridden_at      timestamptz,
    override_reason    text,
    -- rebuild bookkeeping
    inference_run_id   uuid,
    superseded_by_id   uuid REFERENCES tracking.journey_event(id),
    row_version        bigint NOT NULL DEFAULT 0,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_je_user_time   ON tracking.journey_event (user_id, occurred_at DESC)
    WHERE status <> 'SUPERSEDED';
CREATE INDEX ix_je_tour        ON tracking.journey_event (tour_id, occurred_at);
CREATE INDEX ix_je_review      ON tracking.journey_event (user_id) WHERE status = 'NEEDS_REVIEW';
CREATE INDEX ix_je_date        ON tracking.journey_event (user_id, local_date);
CREATE INDEX ix_je_geog        ON tracking.journey_event USING gist (geog);

-- ---------------------------------------------------------------------
-- Inference output: journey segments (intervals between events)
-- ---------------------------------------------------------------------
CREATE TABLE tracking.journey_segment (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           uuid NOT NULL REFERENCES identity.app_user(id),
    tour_id           uuid REFERENCES planning.tour(id),
    segment_type      tracking.segment_type NOT NULL,
    from_event_id     uuid REFERENCES tracking.journey_event(id),
    to_event_id       uuid REFERENCES tracking.journey_event(id),
    started_at        timestamptz NOT NULL,
    ended_at          timestamptz,
    duration_s        integer GENERATED ALWAYS AS (
                          CASE WHEN ended_at IS NULL THEN NULL
                               ELSE EXTRACT(epoch FROM (ended_at - started_at))::integer END) STORED,
    local_date        date NOT NULL,
    ref_type          text CHECK (ref_type IN ('HOME','CUSTOMER_SITE','STAY','NONE')),
    ref_id            uuid,
    site_id           uuid REFERENCES customer.customer_site(id),
    distance_m        bigint,
    straight_line_m   bigint,
    travel_mode       tracking.travel_mode NOT NULL DEFAULT 'UNKNOWN',
    mode_confidence   numeric(3,2),
    mode_overridden_by uuid REFERENCES identity.app_user(id),
    path              geography(LineString,4326),      -- simplified, ~20 m tolerance
    ping_count        integer NOT NULL DEFAULT 0,
    is_estimated      boolean NOT NULL DEFAULT false,  -- reconstructed across a gap
    is_provisional    boolean NOT NULL DEFAULT false,  -- e.g. RETURN_TRAVEL before confirmation
    inference_run_id  uuid,
    superseded_by_id  uuid REFERENCES tracking.journey_segment(id),
    row_version       bigint NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_segment_period CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE INDEX ix_seg_user_time ON tracking.journey_segment (user_id, started_at DESC);
CREATE INDEX ix_seg_tour      ON tracking.journey_segment (tour_id, started_at);
CREATE INDEX ix_seg_date      ON tracking.journey_segment (user_id, local_date);
CREATE INDEX ix_seg_path      ON tracking.journey_segment USING gist (path);

-- ---------------------------------------------------------------------
-- Current state per user (cheap lookup for the live dashboard)
-- ---------------------------------------------------------------------
CREATE TABLE tracking.user_journey_state (
    user_id          uuid PRIMARY KEY REFERENCES identity.app_user(id),
    state            tracking.journey_state NOT NULL DEFAULT 'UNKNOWN',
    tour_id          uuid REFERENCES planning.tour(id),
    ref_type         text,
    ref_id           uuid,
    site_id          uuid REFERENCES customer.customer_site(id),
    since            timestamptz,
    last_ping_at     timestamptz,
    last_ping_geog   geography(Point,4326),
    last_evaluated_at timestamptz,
    tracking_active  boolean NOT NULL DEFAULT false,
    health_score     smallint,
    row_version      bigint NOT NULL DEFAULT 0,
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_ujs_state ON tracking.user_journey_state (state);

-- ---------------------------------------------------------------------
-- Inference runs (idempotent rebuilds — docs/03 §7)
-- ---------------------------------------------------------------------
CREATE TABLE tracking.inference_run (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        uuid NOT NULL REFERENCES identity.app_user(id),
    window_from    timestamptz NOT NULL,
    window_to      timestamptz NOT NULL,
    trigger_reason text NOT NULL,   -- NEW_EVIDENCE / LATE_EVIDENCE / OVERRIDE / GEO_CHANGED / NIGHTLY / MANUAL
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    events_created integer NOT NULL DEFAULT 0,
    events_superseded integer NOT NULL DEFAULT 0,
    segments_created integer NOT NULL DEFAULT 0,
    engine_version text NOT NULL,
    config_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
    status         text NOT NULL DEFAULT 'RUNNING' CHECK (status IN ('RUNNING','SUCCESS','FAILED')),
    error          text
);
CREATE INDEX ix_inference_user ON tracking.inference_run (user_id, started_at DESC);

-- ---------------------------------------------------------------------
-- Anomalies (gaps, tamper signals) — flags, never blocks (docs/03 §6)
-- ---------------------------------------------------------------------
CREATE TABLE tracking.tracking_anomaly (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid NOT NULL REFERENCES identity.app_user(id),
    device_id     uuid REFERENCES identity.device(id),
    tour_id       uuid REFERENCES planning.tour(id),
    anomaly_type  text NOT NULL,   -- GAP_UNEXPLAINED / APP_KILLED / PERMISSION_REVOKED / LOCATION_OFF /
                                   -- POWER_SAVE / NO_SIGNAL / DEVICE_OFF / MOCK_LOCATION / TELEPORT /
                                   -- CLOCK_SKEW / CHECKIN_OUT_OF_FENCE / LONG_PAUSE / REINSTALL
    severity      text NOT NULL DEFAULT 'MEDIUM' CHECK (severity IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    window_start  timestamptz NOT NULL,
    window_end    timestamptz,
    local_date    date NOT NULL,
    duration_s    integer,
    details       jsonb NOT NULL DEFAULT '{}'::jsonb,
    detected_at   timestamptz NOT NULL DEFAULT now(),
    acknowledged_by uuid REFERENCES identity.app_user(id),
    acknowledged_at timestamptz,
    rep_explanation text,
    manager_note  text,
    resolved_at   timestamptz,
    row_version   bigint NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_anomaly_user_date ON tracking.tracking_anomaly (user_id, local_date DESC);
CREATE INDEX ix_anomaly_open      ON tracking.tracking_anomaly (severity, detected_at DESC) WHERE resolved_at IS NULL;

-- ---------------------------------------------------------------------
-- Daily rollups (mileage claims, attendance, dashboards)
-- ---------------------------------------------------------------------
CREATE TABLE tracking.daily_journey_summary (
    user_id             uuid NOT NULL REFERENCES identity.app_user(id),
    local_date          date NOT NULL,
    tour_id             uuid REFERENCES planning.tour(id),
    first_departure_at  timestamptz,
    last_arrival_at     timestamptz,
    total_distance_m    bigint NOT NULL DEFAULT 0,
    distance_by_mode    jsonb  NOT NULL DEFAULT '{}'::jsonb,   -- {"CAR":42100,"RAIL":690000}
    estimated_distance_m bigint NOT NULL DEFAULT 0,            -- portion reconstructed across gaps
    travel_time_s       integer NOT NULL DEFAULT 0,
    customer_time_s     integer NOT NULL DEFAULT 0,
    idle_time_s         integer NOT NULL DEFAULT 0,
    gap_time_s          integer NOT NULL DEFAULT 0,
    visits_planned      smallint NOT NULL DEFAULT 0,
    visits_completed    smallint NOT NULL DEFAULT 0,
    visits_unplanned    smallint NOT NULL DEFAULT 0,
    anomaly_count       smallint NOT NULL DEFAULT 0,
    tracking_coverage_pct smallint,      -- share of the working window with usable evidence
    attendance_status   text,            -- WORKING / TRAVEL / LEAVE / HOLIDAY / WEEKLY_OFF / ABSENT
    computed_at         timestamptz NOT NULL DEFAULT now(),
    row_version         bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, local_date)
);
CREATE INDEX ix_daily_date ON tracking.daily_journey_summary (local_date);

SELECT config.fn_make_syncable('tracking.journey_event',   'user_id', '-');
SELECT config.fn_make_syncable('tracking.journey_segment', 'user_id', '-');
SELECT config.fn_make_syncable('tracking.tracking_anomaly','user_id', '-');
