-- =====================================================================
-- XMobile — 00 Extensions, schemas, enum types, shared functions
-- PostgreSQL 16 + PostGIS 3.4
-- Run files in filename order.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS btree_gist;    -- exclusion constraints mixing scalar + range
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- customer name search

-- ---------------------------------------------------------------------
-- Schemas (one per module; no cross-schema FKs except to identity/customer)
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS identity;
CREATE SCHEMA IF NOT EXISTS customer;
CREATE SCHEMA IF NOT EXISTS planning;
CREATE SCHEMA IF NOT EXISTS tracking;
CREATE SCHEMA IF NOT EXISTS visit;
CREATE SCHEMA IF NOT EXISTS expense;
CREATE SCHEMA IF NOT EXISTS sync;
CREATE SCHEMA IF NOT EXISTS integration;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS config;

-- ---------------------------------------------------------------------
-- Enum types (stable: changing them changes code)
-- ---------------------------------------------------------------------
CREATE TYPE identity.user_status       AS ENUM ('ACTIVE','INACTIVE','SUSPENDED');
CREATE TYPE identity.device_platform   AS ENUM ('ANDROID','IOS');

CREATE TYPE customer.geo_source        AS ENUM ('NONE','GEOCODED','IMPORTED','FIELD_CAPTURED','VERIFIED');

CREATE TYPE planning.tour_status       AS ENUM ('DRAFT','PLANNED','IN_PROGRESS','COMPLETED','CANCELLED','ABANDONED');
CREATE TYPE planning.day_activity      AS ENUM ('TRAVEL','VISITS','MIXED','REST','LEAVE');
CREATE TYPE planning.plan_status       AS ENUM ('PLANNED','COMPLETED','SKIPPED','RESCHEDULED','CANCELLED');

CREATE TYPE tracking.journey_state     AS ENUM ('AT_HOME','OUTBOUND_TRANSIT','AT_CUSTOMER','INTER_TRANSIT',
                                                'OVERNIGHT_STOP','RETURN_TRANSIT','PAUSED','UNKNOWN');
CREATE TYPE tracking.journey_event_type AS ENUM ('DEPART_HOME','ARRIVE_CUSTOMER','DEPART_CUSTOMER',
                                                'START_RETURN','ARRIVE_HOME','OVERNIGHT_STOP_START',
                                                'OVERNIGHT_STOP_END','TRANSIT_START','TRANSIT_END',
                                                'PAUSE_START','PAUSE_END','GAP_START','GAP_END');
CREATE TYPE tracking.segment_type      AS ENUM ('OUTBOUND_TRAVEL','INTER_TRAVEL','RETURN_TRAVEL',
                                                'AT_CUSTOMER','AT_HOME','OVERNIGHT_STOP','GAP','PAUSED');
CREATE TYPE tracking.travel_mode       AS ENUM ('WALK','TWO_WHEELER','CAR','BUS','RAIL','AIR','BOAT','UNKNOWN');
CREATE TYPE tracking.detection_method  AS ENUM ('GEOFENCE','DWELL','PING_CLUSTER','IOS_VISIT','ACTIVITY',
                                                'MANUAL','INFERRED_FROM_GAP','CHECKIN','SYSTEM');
CREATE TYPE tracking.event_status      AS ENUM ('DETECTED','NEEDS_REVIEW','CONFIRMED','REJECTED','SUPERSEDED');
CREATE TYPE tracking.ping_source       AS ENUM ('FG_SERVICE','GEOFENCE','SIGNIFICANT_CHANGE','IOS_VISIT',
                                                'MOTION','MANUAL','HEARTBEAT');
CREATE TYPE tracking.session_status    AS ENUM ('ACTIVE','PAUSED','ENDED');

CREATE TYPE visit.visit_status         AS ENUM ('CHECKED_IN','CHECKED_OUT','REPORT_SUBMITTED','VOIDED');
CREATE TYPE visit.checkin_method       AS ENUM ('GEOFENCE','MANUAL','QR','NFC','REMOTE');
CREATE TYPE visit.template_status      AS ENUM ('DRAFT','PUBLISHED','RETIRED');

CREATE TYPE expense.expense_status     AS ENUM ('DRAFT','SUBMITTED','PUSHED','ACKNOWLEDGED','PUSH_FAILED','VOIDED');
CREATE TYPE expense.attachment_status  AS ENUM ('PENDING_UPLOAD','UPLOADING','UPLOADED','SCANNED','QUARANTINED','FAILED');
CREATE TYPE expense.capture_source     AS ENUM ('MANUAL','SHARE_INTENT','CAMERA','GALLERY','FILE','AUTO_MILEAGE');

CREATE TYPE sync.change_op            AS ENUM ('UPSERT','DELETE','SCOPE_REMOVE');
CREATE TYPE sync.mutation_op          AS ENUM ('INSERT','UPDATE','DELETE');
CREATE TYPE sync.mutation_status      AS ENUM ('APPLIED','DUPLICATE','CONFLICT','REJECTED','DEFERRED');

CREATE TYPE integration.outbox_status AS ENUM ('PENDING','IN_FLIGHT','SENT','FAILED','DEAD');
CREATE TYPE integration.run_status    AS ENUM ('RUNNING','SUCCESS','PARTIAL','FAILED');

-- ---------------------------------------------------------------------
-- Shared functions
-- ---------------------------------------------------------------------

-- Bump row_version and updated_at on every UPDATE of a syncable table.
CREATE OR REPLACE FUNCTION config.fn_touch_row()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at  := now();
    NEW.row_version := COALESCE(OLD.row_version, 0) + 1;
    RETURN NEW;
END $$;

-- Global monotonic change feed consumed by /v1/sync/pull.
-- Every syncable table gets an AFTER trigger writing here.
CREATE TABLE sync.change_log (
    id           bigserial   PRIMARY KEY,
    entity       text        NOT NULL,
    entity_id    uuid,                   -- set for uuid-keyed tables
    entity_key   text        NOT NULL,   -- text form of the PK; always set (reference tables use a code PK)
    op           sync.change_op NOT NULL,
    row_version  bigint      NOT NULL DEFAULT 0,
    owner_user_id uuid,                 -- scoping hint: whose working set this belongs to
    customer_id  uuid,                  -- scoping hint for customer-derived visibility
    changed_at   timestamptz NOT NULL DEFAULT now(),
    changed_by   uuid
);
CREATE INDEX ix_change_log_entity        ON sync.change_log (entity, id);
CREATE INDEX ix_change_log_owner         ON sync.change_log (owner_user_id, id);
CREATE INDEX ix_change_log_customer      ON sync.change_log (customer_id, id) WHERE customer_id IS NOT NULL;

-- Generic change-feed trigger.
-- Args: [0] = owner column name (or '-'), [1] = customer column name (or '-'),
--       [2] = primary-key column (default 'id'; reference tables pass 'code').
CREATE OR REPLACE FUNCTION config.fn_change_log()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_owner_col    text := COALESCE(TG_ARGV[0], '-');
    v_customer_col text := COALESCE(TG_ARGV[1], '-');
    v_key_col      text := COALESCE(TG_ARGV[2], 'id');
    v_row          jsonb;
    v_owner        uuid;
    v_customer     uuid;
    v_op           sync.change_op;
    v_key          text;
    v_id           uuid;
    v_version      bigint;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_row := to_jsonb(OLD); v_op := 'DELETE';
    ELSE
        v_row := to_jsonb(NEW);
        v_op  := CASE WHEN (v_row ? 'deleted_at') AND (v_row->>'deleted_at') IS NOT NULL
                      THEN 'DELETE' ELSE 'UPSERT' END;
    END IF;

    -- Composite-key reference tables (e.g. config.reason_code) pass 'domain||code'.
    v_key := (SELECT string_agg(v_row->>c, '|')
              FROM unnest(string_to_array(v_key_col, '||')) AS c);
    BEGIN
        v_id := v_key::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        v_id := NULL;                       -- text-keyed reference table
    END;

    v_version := COALESCE((v_row->>'row_version')::bigint, 0);
    IF v_owner_col    <> '-' THEN v_owner    := NULLIF(v_row->>v_owner_col, '')::uuid;    END IF;
    IF v_customer_col <> '-' THEN v_customer := NULLIF(v_row->>v_customer_col, '')::uuid; END IF;

    INSERT INTO sync.change_log (entity, entity_id, entity_key, op, row_version,
                                 owner_user_id, customer_id, changed_by)
    VALUES (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_id, v_key, v_op, v_version, v_owner, v_customer,
            NULLIF(current_setting('xmobile.actor_id', true), '')::uuid);
    RETURN NULL;
END $$;

-- Convenience: attach both triggers to a syncable table.
-- p_key_col: PK column name; use 'a||b' for a composite key.
CREATE OR REPLACE FUNCTION config.fn_make_syncable(p_table regclass, p_owner_col text, p_customer_col text,
                                                   p_key_col text DEFAULT 'id')
RETURNS void LANGUAGE plpgsql AS $$
DECLARE t text := p_table::text;
        n text := replace(replace(t, '.', '_'), '"', '');
BEGIN
    EXECUTE format('CREATE TRIGGER tg_%s_touch BEFORE UPDATE ON %s
                    FOR EACH ROW EXECUTE FUNCTION config.fn_touch_row()', n, t);
    EXECUTE format('CREATE TRIGGER tg_%s_changelog AFTER INSERT OR UPDATE OR DELETE ON %s
                    FOR EACH ROW EXECUTE FUNCTION config.fn_change_log(%L, %L, %L)',
                   n, t, p_owner_col, p_customer_col, p_key_col);
END $$;

-- Metres between two geographies (thin wrapper for readability in queries).
CREATE OR REPLACE FUNCTION config.fn_distance_m(a geography, b geography)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT ST_Distance(a, b) $$;

-- ---------------------------------------------------------------------
-- Runtime configuration (admin-tunable; see docs/03 §9)
-- ---------------------------------------------------------------------
CREATE TABLE config.app_setting (
    key         text PRIMARY KEY,
    value       jsonb       NOT NULL,
    data_type   text        NOT NULL CHECK (data_type IN ('int','decimal','bool','string','time','json')),
    description text,
    scope       text        NOT NULL DEFAULT 'GLOBAL' CHECK (scope IN ('GLOBAL','ROLE','ORG_UNIT','USER')),
    scope_ref   uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid
);
CREATE UNIQUE INDEX ux_app_setting_scope ON config.app_setting (key, scope, COALESCE(scope_ref, '00000000-0000-0000-0000-000000000000'::uuid));

CREATE TABLE config.feature_flag (
    code        text PRIMARY KEY,
    enabled     boolean     NOT NULL DEFAULT false,
    rollout_pct smallint    NOT NULL DEFAULT 0 CHECK (rollout_pct BETWEEN 0 AND 100),
    description text,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Reference/lookup data (tables, not enums: operations edit these without a release)
-- ---------------------------------------------------------------------
CREATE TABLE config.visit_type (
    code             text PRIMARY KEY,
    name             text NOT NULL,
    default_duration_min smallint NOT NULL DEFAULT 45,
    requires_selfie  boolean NOT NULL DEFAULT false,
    requires_signature boolean NOT NULL DEFAULT false,
    allows_remote    boolean NOT NULL DEFAULT false,   -- phone/online visit, no geo expected
    default_template_code text,
    sort_order       smallint NOT NULL DEFAULT 0,
    is_active        boolean NOT NULL DEFAULT true,
    row_version      bigint NOT NULL DEFAULT 0,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE config.visit_outcome (
    code        text PRIMARY KEY,
    name        text NOT NULL,
    is_positive boolean NOT NULL DEFAULT true,
    requires_follow_up boolean NOT NULL DEFAULT false,
    sort_order  smallint NOT NULL DEFAULT 0,
    is_active   boolean NOT NULL DEFAULT true,
    row_version bigint NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE config.reason_code (
    domain      text NOT NULL,          -- VISIT_SKIP / TRACKING_PAUSE / OUT_OF_GEOFENCE / TOUR_ABANDON
    code        text NOT NULL,
    name        text NOT NULL,
    requires_remark boolean NOT NULL DEFAULT false,
    sort_order  smallint NOT NULL DEFAULT 0,
    is_active   boolean NOT NULL DEFAULT true,
    row_version bigint NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (domain, code)
);

-- Reference data is part of the offline working set, so it rides the change feed too.
SELECT config.fn_make_syncable('config.visit_type',    '-', '-', 'code');
SELECT config.fn_make_syncable('config.visit_outcome', '-', '-', 'code');
SELECT config.fn_make_syncable('config.reason_code',   '-', '-', 'domain||code');
