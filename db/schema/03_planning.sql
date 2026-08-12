-- =====================================================================
-- XMobile — 03 Planning: tours (multi-day) with per-day sub-plans
-- =====================================================================

CREATE TABLE planning.tour (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             uuid NOT NULL REFERENCES identity.app_user(id),
    code                text,                                   -- human reference, e.g. TR-2026-00841
    title               text NOT NULL,
    purpose             text,
    home_location_id    uuid NOT NULL REFERENCES identity.user_home_location(id),  -- pinned at creation
    planned_start_date  date NOT NULL,
    planned_end_date    date NOT NULL,
    destination_city    text,
    destination_state   text,
    actual_start_at     timestamptz,        -- confirmed DEPART_HOME
    actual_end_at       timestamptz,        -- confirmed ARRIVE_HOME
    status              planning.tour_status NOT NULL DEFAULT 'DRAFT',
    is_single_day       boolean GENERATED ALWAYS AS (planned_start_date = planned_end_date) STORED,
    -- Planning is self-service: no manager approval gate. The baseline is locked when the
    -- tour starts, so plan-vs-actual compares against intent rather than a plan edited at
    -- day's end (docs/02 §2.1).
    baseline_locked_at  timestamptz,
    created_by          uuid REFERENCES identity.app_user(id),
    cancel_reason       text,
    remark              text,
    -- rollups maintained by the tracking worker
    total_distance_m    bigint,
    total_visits        integer NOT NULL DEFAULT 0,
    total_expense_amount numeric(14,2),
    row_version         bigint NOT NULL DEFAULT 0,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz,
    CONSTRAINT ck_tour_dates CHECK (planned_end_date >= planned_start_date)
);
CREATE INDEX ix_tour_user_dates ON planning.tour (user_id, planned_start_date DESC) WHERE deleted_at IS NULL;
CREATE INDEX ix_tour_status     ON planning.tour (status) WHERE deleted_at IS NULL;
-- At most one tour in progress per rep.
CREATE UNIQUE INDEX ux_tour_in_progress ON planning.tour (user_id)
    WHERE status = 'IN_PROGRESS' AND deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- One row per calendar day of the tour; editable in the field.
-- ---------------------------------------------------------------------
CREATE TABLE planning.tour_day (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tour_id          uuid NOT NULL REFERENCES planning.tour(id) ON DELETE CASCADE,
    user_id          uuid NOT NULL REFERENCES identity.app_user(id),  -- denormalised for sync scoping
    plan_date        date NOT NULL,
    day_seq          smallint NOT NULL,
    activity_type    planning.day_activity NOT NULL DEFAULT 'VISITS',
    from_city        text,
    to_city          text,
    planned_travel_mode tracking.travel_mode,
    overnight_city   text,
    overnight_note   text,
    notes            text,
    revision         integer NOT NULL DEFAULT 1,     -- bumped on in-field edits after baseline lock
    row_version      bigint NOT NULL DEFAULT 0,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz
);
CREATE UNIQUE INDEX ux_tour_day ON planning.tour_day (tour_id, plan_date) WHERE deleted_at IS NULL;
CREATE INDEX ix_tour_day_user   ON planning.tour_day (user_id, plan_date);

-- ---------------------------------------------------------------------
-- Visit plans (intent). A visit plan may exist without a tour_day only
-- transitionally; the API attaches it to the day matching planned_date.
-- ---------------------------------------------------------------------
CREATE TABLE planning.visit_plan (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tour_id            uuid REFERENCES planning.tour(id) ON DELETE CASCADE,
    tour_day_id        uuid REFERENCES planning.tour_day(id) ON DELETE CASCADE,
    user_id            uuid NOT NULL REFERENCES identity.app_user(id),
    customer_id        uuid NOT NULL REFERENCES customer.customer_account(id),
    site_id            uuid NOT NULL REFERENCES customer.customer_site(id),
    contact_id         uuid REFERENCES customer.customer_contact(id),
    visit_type_code    text NOT NULL REFERENCES config.visit_type(code) DEFERRABLE INITIALLY DEFERRED,
    planned_date       date NOT NULL,
    planned_start_time time,
    planned_duration_min smallint NOT NULL DEFAULT 45,
    seq                smallint NOT NULL DEFAULT 1,
    objective          text,
    status             planning.plan_status NOT NULL DEFAULT 'PLANNED',
    skip_reason_code   text,
    skip_remark        text,
    rescheduled_to_id  uuid REFERENCES planning.visit_plan(id),
    is_baseline        boolean NOT NULL DEFAULT true,   -- false = added after baseline lock
    created_by         uuid REFERENCES identity.app_user(id),
    row_version        bigint NOT NULL DEFAULT 0,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    deleted_at         timestamptz
);
CREATE INDEX ix_plan_user_date ON planning.visit_plan (user_id, planned_date) WHERE deleted_at IS NULL;
CREATE INDEX ix_plan_tour      ON planning.visit_plan (tour_id);
CREATE INDEX ix_plan_site      ON planning.visit_plan (site_id);
CREATE INDEX ix_plan_status    ON planning.visit_plan (status) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- Plan revision history — plan-vs-actual must compare against the baseline,
-- not against a plan edited at 18:00 to match what actually happened.
-- ---------------------------------------------------------------------
CREATE TABLE planning.plan_revision (
    id           bigserial PRIMARY KEY,
    tour_id      uuid NOT NULL REFERENCES planning.tour(id) ON DELETE CASCADE,
    revised_at   timestamptz NOT NULL DEFAULT now(),
    revised_by   uuid REFERENCES identity.app_user(id),
    change_type  text NOT NULL,       -- DAY_ADDED / VISIT_ADDED / VISIT_REMOVED / RESEQUENCED / DATE_CHANGED
    entity_id    uuid,
    before_json  jsonb,
    after_json   jsonb,
    reason       text
);
CREATE INDEX ix_plan_revision_tour ON planning.plan_revision (tour_id, revised_at DESC);

-- ---------------------------------------------------------------------
-- Optional: suggested route order for a tour day (route optimisation output)
-- ---------------------------------------------------------------------
CREATE TABLE planning.route_suggestion (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tour_day_id   uuid NOT NULL REFERENCES planning.tour_day(id) ON DELETE CASCADE,
    generated_at  timestamptz NOT NULL DEFAULT now(),
    algorithm     text NOT NULL DEFAULT 'NEAREST_NEIGHBOUR_2OPT',
    ordered_plan_ids uuid[] NOT NULL,
    estimated_distance_m bigint,
    estimated_duration_s integer,
    accepted      boolean NOT NULL DEFAULT false,
    accepted_at   timestamptz
);

SELECT config.fn_make_syncable('planning.tour',       'user_id', '-');
SELECT config.fn_make_syncable('planning.tour_day',   'user_id', '-');
SELECT config.fn_make_syncable('planning.visit_plan', 'user_id', 'customer_id');
