-- =====================================================================
-- XMobile — 02 Customer master (XInfo is the source of truth)
-- XMobile owns: site coordinates captured in the field, geofence radius.
-- =====================================================================

CREATE TABLE customer.customer_account (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    xinfo_id         text UNIQUE,                  -- match key; never match on name
    code             text UNIQUE,
    name             text NOT NULL,
    legal_name       text,
    account_type     text,                         -- DISTRIBUTOR / DEALER / OEM / RETAILER ...
    category         text,                         -- A / B / C, drives visit frequency norms
    industry         text,
    parent_id        uuid REFERENCES customer.customer_account(id),
    owner_user_id    uuid REFERENCES identity.app_user(id),   -- primary rep, from XInfo
    org_unit_id      uuid REFERENCES identity.org_unit(id),
    credit_status    text,
    gst_number       text,
    phone            text,
    email            text,
    is_active        boolean NOT NULL DEFAULT true,
    xinfo_synced_at  timestamptz,
    xinfo_hash       text,                         -- for full-pull change detection
    row_version      bigint NOT NULL DEFAULT 0,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz
);
CREATE INDEX ix_account_owner  ON customer.customer_account (owner_user_id) WHERE deleted_at IS NULL;
CREATE INDEX ix_account_org    ON customer.customer_account (org_unit_id);
CREATE INDEX ix_account_name_trgm ON customer.customer_account USING gin (name gin_trgm_ops);

-- ---------------------------------------------------------------------
-- Sites: the geo-bearing entity. Visits and geofences reference a SITE,
-- never an account, because one account can have many physical locations.
-- ---------------------------------------------------------------------
CREATE TABLE customer.customer_site (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id       uuid NOT NULL REFERENCES customer.customer_account(id),
    xinfo_id          text UNIQUE,
    site_code         text,
    name              text NOT NULL,              -- 'Head Office', 'Plant 2', 'Warehouse'
    site_type         text,
    is_primary        boolean NOT NULL DEFAULT false,
    address_line1     text,
    address_line2     text,
    landmark          text,
    city              text,
    district          text,
    state             text,
    postal_code       text,
    country_code      char(2) NOT NULL DEFAULT 'IN',
    geog              geography(Point,4326),
    geo_source        customer.geo_source NOT NULL DEFAULT 'NONE',
    geo_accuracy_m    double precision,
    geofence_radius_m integer NOT NULL DEFAULT 150 CHECK (geofence_radius_m BETWEEN 50 AND 5000),
    geo_captured_by   uuid REFERENCES identity.app_user(id),
    geo_captured_at   timestamptz,
    geo_verified_by   uuid REFERENCES identity.app_user(id),
    geo_verified_at   timestamptz,
    suggested_radius_m integer,                    -- from historical check-in spread
    timezone          text NOT NULL DEFAULT 'Asia/Kolkata',
    is_active         boolean NOT NULL DEFAULT true,
    row_version       bigint NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at        timestamptz
);
CREATE INDEX ix_site_customer ON customer.customer_site (customer_id) WHERE deleted_at IS NULL;
CREATE INDEX ix_site_geog     ON customer.customer_site USING gist (geog);
CREATE UNIQUE INDEX ux_site_primary ON customer.customer_site (customer_id)
    WHERE is_primary AND deleted_at IS NULL;

CREATE TABLE customer.customer_contact (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id  uuid NOT NULL REFERENCES customer.customer_account(id),
    site_id      uuid REFERENCES customer.customer_site(id),
    xinfo_id     text UNIQUE,
    full_name    text NOT NULL,
    designation  text,
    department   text,
    phone        text,
    email        text,
    is_primary   boolean NOT NULL DEFAULT false,
    is_active    boolean NOT NULL DEFAULT true,
    row_version  bigint NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    deleted_at   timestamptz
);
CREATE INDEX ix_contact_customer ON customer.customer_contact (customer_id) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- Rep ↔ customer assignment (from XInfo). Drives the offline working set
-- and the /sync scope filter.
-- ---------------------------------------------------------------------
CREATE TABLE customer.customer_assignment (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id  uuid NOT NULL REFERENCES customer.customer_account(id),
    user_id      uuid NOT NULL REFERENCES identity.app_user(id),
    role         text NOT NULL DEFAULT 'PRIMARY' CHECK (role IN ('PRIMARY','SECONDARY','SUPPORT')),
    valid_from   date NOT NULL DEFAULT CURRENT_DATE,
    valid_to     date,
    xinfo_id     text,
    row_version  bigint NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    deleted_at   timestamptz,
    CONSTRAINT ck_assignment_period CHECK (valid_to IS NULL OR valid_to >= valid_from)
);
CREATE INDEX ix_assignment_user     ON customer.customer_assignment (user_id) WHERE deleted_at IS NULL;
CREATE INDEX ix_assignment_customer ON customer.customer_assignment (customer_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_assignment_active ON customer.customer_assignment (customer_id, user_id, role)
    WHERE valid_to IS NULL AND deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- Geofence registry: one row per monitorable place (home or customer site).
-- The mobile client pulls its active subset (iOS: max 20 — see docs/03 §2).
-- ---------------------------------------------------------------------
CREATE TABLE customer.geofence (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ref_type    text NOT NULL CHECK (ref_type IN ('HOME','CUSTOMER_SITE')),
    ref_id      uuid NOT NULL,                     -- user_home_location.id | customer_site.id
    name        text NOT NULL,
    geog        geography(Point,4326) NOT NULL,
    radius_m    integer NOT NULL CHECK (radius_m BETWEEN 50 AND 5000),
    dwell_sec   integer NOT NULL DEFAULT 240,
    is_active   boolean NOT NULL DEFAULT true,
    row_version bigint NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_geofence_ref ON customer.geofence (ref_type, ref_id);
CREATE INDEX ix_geofence_geog       ON customer.geofence USING gist (geog);

-- Keep the geofence registry in step with site/home coordinate changes.
CREATE OR REPLACE FUNCTION customer.fn_sync_site_geofence()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.geog IS NULL OR NEW.deleted_at IS NOT NULL OR NOT NEW.is_active THEN
        UPDATE customer.geofence SET is_active = false, updated_at = now()
         WHERE ref_type = 'CUSTOMER_SITE' AND ref_id = NEW.id;
        RETURN NEW;
    END IF;

    INSERT INTO customer.geofence (ref_type, ref_id, name, geog, radius_m, is_active)
    VALUES ('CUSTOMER_SITE', NEW.id, NEW.name, NEW.geog, NEW.geofence_radius_m, true)
    ON CONFLICT (ref_type, ref_id) DO UPDATE
        SET name = EXCLUDED.name, geog = EXCLUDED.geog, radius_m = EXCLUDED.radius_m,
            is_active = true, updated_at = now();
    RETURN NEW;
END $$;

CREATE TRIGGER tg_site_geofence
AFTER INSERT OR UPDATE OF geog, geofence_radius_m, is_active, deleted_at, name
ON customer.customer_site
FOR EACH ROW EXECUTE FUNCTION customer.fn_sync_site_geofence();

CREATE OR REPLACE FUNCTION identity.fn_sync_home_geofence()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.deleted_at IS NOT NULL OR NEW.effective_to IS NOT NULL THEN
        UPDATE customer.geofence SET is_active = false, updated_at = now()
         WHERE ref_type = 'HOME' AND ref_id = NEW.id;
        RETURN NEW;
    END IF;

    INSERT INTO customer.geofence (ref_type, ref_id, name, geog, radius_m, dwell_sec, is_active)
    VALUES ('HOME', NEW.id, NEW.label, NEW.geog, NEW.geofence_radius_m, 600, true)
    ON CONFLICT (ref_type, ref_id) DO UPDATE
        SET name = EXCLUDED.name, geog = EXCLUDED.geog, radius_m = EXCLUDED.radius_m,
            is_active = true, updated_at = now();
    RETURN NEW;
END $$;

CREATE TRIGGER tg_home_geofence
AFTER INSERT OR UPDATE OF geog, geofence_radius_m, effective_to, deleted_at, label
ON identity.user_home_location
FOR EACH ROW EXECUTE FUNCTION identity.fn_sync_home_geofence();

-- ---------------------------------------------------------------------
-- Data-quality exceptions raised by the XInfo import (docs/05 §3)
-- ---------------------------------------------------------------------
CREATE TABLE customer.data_quality_flag (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entity       text NOT NULL,
    entity_id    uuid NOT NULL,
    flag_type    text NOT NULL,   -- ADDRESS_MOVED_FAR / MISSING_GEO / GEOCODE_LOW_CONFIDENCE /
                                  -- DUPLICATE_SUSPECT / RADIUS_SUGGESTION
    severity     text NOT NULL DEFAULT 'MEDIUM' CHECK (severity IN ('LOW','MEDIUM','HIGH')),
    details      jsonb NOT NULL DEFAULT '{}'::jsonb,
    detected_at  timestamptz NOT NULL DEFAULT now(),
    resolved_at  timestamptz,
    resolved_by  uuid REFERENCES identity.app_user(id),
    resolution   text
);
CREATE INDEX ix_dq_open ON customer.data_quality_flag (entity, entity_id) WHERE resolved_at IS NULL;

-- ---------------------------------------------------------------------
-- Syncable triggers
-- ---------------------------------------------------------------------
SELECT config.fn_make_syncable('customer.customer_account',    '-', 'id');
SELECT config.fn_make_syncable('customer.customer_site',       '-', 'customer_id');
SELECT config.fn_make_syncable('customer.customer_contact',    '-', 'customer_id');
SELECT config.fn_make_syncable('customer.customer_assignment', 'user_id', 'customer_id');
SELECT config.fn_make_syncable('customer.geofence',            '-', '-');
