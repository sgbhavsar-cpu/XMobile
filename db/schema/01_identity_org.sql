-- =====================================================================
-- XMobile — 01 Identity, organisation, devices, home locations
-- Users authenticate against AD/LDAP/OIDC; hierarchy is synced from XInfo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Org units (territory hierarchy), materialised path for cheap subtree reads
-- ---------------------------------------------------------------------
CREATE TABLE identity.org_unit (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    xinfo_id      text UNIQUE,
    code          text NOT NULL UNIQUE,
    name          text NOT NULL,
    unit_type     text NOT NULL CHECK (unit_type IN ('COMPANY','ZONE','REGION','AREA','TERRITORY')),
    parent_id     uuid REFERENCES identity.org_unit(id),
    path          text NOT NULL,                     -- '/company/zone-w/region-mh/area-pune'
    boundary      geography(MultiPolygon,4326),      -- optional territory polygon
    is_active     boolean NOT NULL DEFAULT true,
    row_version   bigint  NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz
);
CREATE INDEX ix_org_unit_parent   ON identity.org_unit (parent_id);
CREATE INDEX ix_org_unit_path     ON identity.org_unit (path text_pattern_ops);
CREATE INDEX ix_org_unit_boundary ON identity.org_unit USING gist (boundary);

-- ---------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------
CREATE TABLE identity.app_user (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    external_subject   text UNIQUE,                  -- OIDC 'sub'
    upn                text,                         -- AD userPrincipalName
    employee_code      text NOT NULL UNIQUE,         -- join key to XInfo
    xinfo_user_id      text UNIQUE,
    full_name          text NOT NULL,
    email              text,
    phone              text,
    grade              text,                         -- drives expense policy in XInfo
    designation        text,
    org_unit_id        uuid REFERENCES identity.org_unit(id),
    manager_id         uuid REFERENCES identity.app_user(id),
    default_timezone   text NOT NULL DEFAULT 'Asia/Kolkata',
    shift_start        time NOT NULL DEFAULT '09:00',
    shift_end          time NOT NULL DEFAULT '18:00',
    working_days       smallint[] NOT NULL DEFAULT '{1,2,3,4,5,6}',  -- ISO dow
    tracking_enabled   boolean NOT NULL DEFAULT true,
    status             identity.user_status NOT NULL DEFAULT 'ACTIVE',
    joined_on          date,
    left_on            date,
    row_version        bigint NOT NULL DEFAULT 0,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    deleted_at         timestamptz
);
-- Case-insensitive uniqueness on email without requiring the citext extension.
CREATE UNIQUE INDEX ux_app_user_email ON identity.app_user (lower(email)) WHERE email IS NOT NULL;
CREATE INDEX ix_app_user_manager  ON identity.app_user (manager_id);
CREATE INDEX ix_app_user_org      ON identity.app_user (org_unit_id);
CREATE INDEX ix_app_user_status   ON identity.app_user (status) WHERE deleted_at IS NULL;

-- Flattened manager→subordinate closure, refreshed on hierarchy sync.
CREATE TABLE identity.user_hierarchy_closure (
    ancestor_id   uuid NOT NULL REFERENCES identity.app_user(id) ON DELETE CASCADE,
    descendant_id uuid NOT NULL REFERENCES identity.app_user(id) ON DELETE CASCADE,
    depth         smallint NOT NULL,
    PRIMARY KEY (ancestor_id, descendant_id)
);
CREATE INDEX ix_hierarchy_descendant ON identity.user_hierarchy_closure (descendant_id);

-- ---------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------
CREATE TABLE identity.app_role (
    code        text PRIMARY KEY,          -- SALES_REP, MANAGER, ADMIN, AUDITOR, INTEGRATION
    name        text NOT NULL,
    description text,
    permissions jsonb NOT NULL DEFAULT '[]'::jsonb
);

CREATE TABLE identity.user_role (
    user_id     uuid NOT NULL REFERENCES identity.app_user(id) ON DELETE CASCADE,
    role_code   text NOT NULL REFERENCES identity.app_role(code),
    granted_at  timestamptz NOT NULL DEFAULT now(),
    granted_by  uuid REFERENCES identity.app_user(id),
    PRIMARY KEY (user_id, role_code)
);

-- ---------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------
CREATE TABLE identity.device (
    id                    uuid PRIMARY KEY,               -- client-generated UUIDv7
    user_id               uuid NOT NULL REFERENCES identity.app_user(id),
    platform              identity.device_platform NOT NULL,
    model                 text,
    manufacturer          text,
    os_version            text,
    app_version           text,
    install_id            text,
    fingerprint           text,
    push_token            text,
    push_provider         text CHECK (push_provider IN ('FCM','APNS','NONE')),
    is_company_owned      boolean NOT NULL DEFAULT false,
    -- tracking health, refreshed by the client heartbeat
    location_permission   text CHECK (location_permission IN ('ALWAYS','WHEN_IN_USE','DENIED','UNKNOWN')),
    battery_optimised     boolean,                        -- true = OS may kill our service (bad)
    notifications_allowed boolean,
    activity_permission   boolean,
    mock_location_allowed boolean,
    tracking_health_score smallint CHECK (tracking_health_score BETWEEN 0 AND 100),
    health_details        jsonb NOT NULL DEFAULT '{}'::jsonb,
    clock_skew_sec        integer NOT NULL DEFAULT 0,
    last_seen_at          timestamptz,
    last_sync_at          timestamptz,
    registered_at         timestamptz NOT NULL DEFAULT now(),
    revoked_at            timestamptz,
    revoked_by            uuid REFERENCES identity.app_user(id),
    revoke_reason         text,
    wipe_requested        boolean NOT NULL DEFAULT false,
    row_version           bigint NOT NULL DEFAULT 0,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_device_user ON identity.device (user_id) WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------------
-- Home locations (historical — reps relocate; a tour pins the one in force)
-- ---------------------------------------------------------------------
CREATE TABLE identity.user_home_location (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid NOT NULL REFERENCES identity.app_user(id),
    label           text NOT NULL DEFAULT 'Home',
    address_line1   text,
    address_line2   text,
    city            text,
    state           text,
    postal_code     text,
    country_code    char(2) NOT NULL DEFAULT 'IN',
    geog            geography(Point,4326) NOT NULL,
    geofence_radius_m integer NOT NULL DEFAULT 200 CHECK (geofence_radius_m BETWEEN 50 AND 2000),
    geo_source      customer.geo_source NOT NULL DEFAULT 'FIELD_CAPTURED',
    accuracy_m      double precision,
    effective_from  date NOT NULL DEFAULT CURRENT_DATE,
    effective_to    date,
    verified_at     timestamptz,
    verified_by     uuid REFERENCES identity.app_user(id),
    row_version     bigint NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    CONSTRAINT ck_home_period CHECK (effective_to IS NULL OR effective_to >= effective_from)
);
CREATE INDEX ix_home_user  ON identity.user_home_location (user_id, effective_from DESC);
CREATE INDEX ix_home_geog  ON identity.user_home_location USING gist (geog);
-- Only one home in force per user at a time.
CREATE UNIQUE INDEX ux_home_current ON identity.user_home_location (user_id)
    WHERE effective_to IS NULL AND deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- Non-working days: leave and holidays (so absence isn't flagged as violation)
-- ---------------------------------------------------------------------
CREATE TABLE identity.holiday (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    holiday_date date NOT NULL,
    name         text NOT NULL,
    org_unit_id  uuid REFERENCES identity.org_unit(id),   -- NULL = company-wide
    row_version  bigint NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_holiday ON identity.holiday (holiday_date, COALESCE(org_unit_id,'00000000-0000-0000-0000-000000000000'::uuid));

CREATE TABLE identity.leave_record (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL REFERENCES identity.app_user(id),
    from_date   date NOT NULL,
    to_date     date NOT NULL,
    leave_type  text NOT NULL,
    is_half_day boolean NOT NULL DEFAULT false,
    remark      text,
    xinfo_id    text,
    row_version bigint NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz,
    CONSTRAINT ck_leave_period CHECK (to_date >= from_date)
);
CREATE INDEX ix_leave_user ON identity.leave_record (user_id, from_date, to_date);

-- ---------------------------------------------------------------------
-- Consent to location tracking (privacy; see docs/06 §3)
-- ---------------------------------------------------------------------
CREATE TABLE identity.consent_record (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        uuid NOT NULL REFERENCES identity.app_user(id),
    policy_code    text NOT NULL,
    policy_version text NOT NULL,
    granted        boolean NOT NULL,
    granted_at     timestamptz NOT NULL DEFAULT now(),
    revoked_at     timestamptz,
    device_id      uuid REFERENCES identity.device(id),
    ip_address     inet,
    evidence       jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX ix_consent_user ON identity.consent_record (user_id, policy_code, granted_at DESC);

-- ---------------------------------------------------------------------
-- Syncable triggers
-- ---------------------------------------------------------------------
SELECT config.fn_make_syncable('identity.app_user',           'id', '-');
SELECT config.fn_make_syncable('identity.org_unit',           '-',  '-');
SELECT config.fn_make_syncable('identity.user_home_location', 'user_id', '-');
SELECT config.fn_make_syncable('identity.holiday',            '-',  '-');
SELECT config.fn_make_syncable('identity.leave_record',       'user_id', '-');
SELECT config.fn_make_syncable('identity.device',             'user_id', '-');
