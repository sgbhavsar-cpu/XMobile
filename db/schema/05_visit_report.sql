-- =====================================================================
-- XMobile — 05 Visits, dynamic form templates, visit reports
-- Report = fixed core columns + admin-defined dynamic section (jsonb).
-- =====================================================================

CREATE TABLE visit.visit (
    id                  uuid PRIMARY KEY,                      -- client-generated UUIDv7
    visit_plan_id       uuid REFERENCES planning.visit_plan(id),  -- NULL = unplanned visit
    tour_id             uuid REFERENCES planning.tour(id),
    tour_day_id         uuid REFERENCES planning.tour_day(id),
    user_id             uuid NOT NULL REFERENCES identity.app_user(id),
    customer_id         uuid NOT NULL REFERENCES customer.customer_account(id),
    site_id             uuid NOT NULL REFERENCES customer.customer_site(id),
    contact_id          uuid REFERENCES customer.customer_contact(id),
    visit_type_code     text NOT NULL REFERENCES config.visit_type(code),
    local_date          date NOT NULL,

    -- check-in
    check_in_at         timestamptz NOT NULL,
    check_in_geog       geography(Point,4326),
    check_in_accuracy_m real,
    check_in_distance_m integer,                 -- metres from the site's geofence centre
    check_in_method     visit.checkin_method NOT NULL DEFAULT 'MANUAL',
    check_in_device_id  uuid REFERENCES identity.device(id),
    is_out_of_geofence  boolean NOT NULL DEFAULT false,
    out_of_fence_reason_code text,
    out_of_fence_remark text,

    -- check-out
    check_out_at        timestamptz,
    check_out_geog      geography(Point,4326),
    check_out_accuracy_m real,
    check_out_method    visit.checkin_method,
    auto_closed         boolean NOT NULL DEFAULT false,
    duration_min        integer GENERATED ALWAYS AS (
                            CASE WHEN check_out_at IS NULL THEN NULL
                                 ELSE (EXTRACT(epoch FROM (check_out_at - check_in_at)) / 60)::integer END) STORED,

    -- verification artefacts
    selfie_attachment_id    uuid,
    signature_attachment_id uuid,
    photo_count             smallint NOT NULL DEFAULT 0,

    is_unplanned        boolean NOT NULL DEFAULT false,
    status              visit.visit_status NOT NULL DEFAULT 'CHECKED_IN',
    void_reason         text,
    -- link to the derived journey (nullable: inference may run later)
    arrive_event_id     uuid REFERENCES tracking.journey_event(id),
    depart_event_id     uuid REFERENCES tracking.journey_event(id),

    device_tz           text,
    row_version         bigint NOT NULL DEFAULT 0,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz,
    CONSTRAINT ck_visit_period CHECK (check_out_at IS NULL OR check_out_at >= check_in_at)
);
CREATE INDEX ix_visit_user_date ON visit.visit (user_id, local_date DESC) WHERE deleted_at IS NULL;
CREATE INDEX ix_visit_customer  ON visit.visit (customer_id, check_in_at DESC);
CREATE INDEX ix_visit_site      ON visit.visit (site_id, check_in_at DESC);
CREATE INDEX ix_visit_tour      ON visit.visit (tour_id);
CREATE INDEX ix_visit_open      ON visit.visit (user_id) WHERE status = 'CHECKED_IN' AND deleted_at IS NULL;
CREATE UNIQUE INDEX ux_visit_plan ON visit.visit (visit_plan_id)
    WHERE visit_plan_id IS NOT NULL AND deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- Dynamic form templates. Published versions are immutable; a change
-- creates a new version so historical reports still render correctly.
-- ---------------------------------------------------------------------
CREATE TABLE visit.form_template (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code             text NOT NULL,
    version          integer NOT NULL,
    name             text NOT NULL,
    description      text,
    -- applicability
    visit_type_code  text REFERENCES config.visit_type(code),
    customer_category text,
    org_unit_id      uuid REFERENCES identity.org_unit(id),
    -- JSON Schema-ish definition rendered by the Flutter form engine:
    -- { "sections":[ { "key":"stock", "title":"Stock check",
    --                  "fields":[ {"key":"closing_qty","type":"number","label":"Closing qty",
    --                              "required":true,"min":0,
    --                              "visibleIf":{"field":"has_stock","eq":true}} ] } ] }
    schema           jsonb NOT NULL,
    status           visit.template_status NOT NULL DEFAULT 'DRAFT',
    effective_from   date,
    effective_to     date,
    published_at     timestamptz,
    published_by     uuid REFERENCES identity.app_user(id),
    row_version      bigint NOT NULL DEFAULT 0,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (code, version)
);
CREATE INDEX ix_template_active ON visit.form_template (code, status, effective_from);
CREATE UNIQUE INDEX ux_template_published ON visit.form_template (code)
    WHERE status = 'PUBLISHED' AND effective_to IS NULL;

-- ---------------------------------------------------------------------
-- Visit report: fixed core + dynamic answers
-- ---------------------------------------------------------------------
CREATE TABLE visit.visit_report (
    visit_id            uuid PRIMARY KEY REFERENCES visit.visit(id) ON DELETE CASCADE,
    user_id             uuid NOT NULL REFERENCES identity.app_user(id),
    template_id         uuid REFERENCES visit.form_template(id),
    template_code       text,
    template_version    integer,

    -- ---- fixed core (always queryable) ----
    outcome_code        text REFERENCES config.visit_outcome(code),
    summary             text,
    discussion_points   text,
    next_action         text,
    follow_up_date      date,
    order_intent        boolean,
    order_value_est     numeric(14,2),
    currency            char(3) NOT NULL DEFAULT 'INR',
    competitor_seen     boolean NOT NULL DEFAULT false,
    competitor_notes    text,
    customer_sentiment  smallint CHECK (customer_sentiment BETWEEN 1 AND 5),
    issues_raised       text,
    contact_met_id      uuid REFERENCES customer.customer_contact(id),
    contact_met_name    text,          -- free text when the contact isn't in the master yet

    -- ---- dynamic extension ----
    answers             jsonb NOT NULL DEFAULT '{}'::jsonb,

    voice_note_attachment_id uuid,
    is_draft            boolean NOT NULL DEFAULT true,
    submitted_at        timestamptz,
    row_version         bigint NOT NULL DEFAULT 0,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_report_followup ON visit.visit_report (user_id, follow_up_date) WHERE follow_up_date IS NOT NULL;
CREATE INDEX ix_report_outcome  ON visit.visit_report (outcome_code);
CREATE INDEX ix_report_answers  ON visit.visit_report USING gin (answers jsonb_path_ops);

-- Amendments after submission (reports are immutable once submitted)
CREATE TABLE visit.visit_report_amendment (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    visit_id     uuid NOT NULL REFERENCES visit.visit(id) ON DELETE CASCADE,
    amended_by   uuid NOT NULL REFERENCES identity.app_user(id),
    amended_at   timestamptz NOT NULL DEFAULT now(),
    reason       text NOT NULL,
    before_json  jsonb NOT NULL,
    after_json   jsonb NOT NULL,
    row_version  bigint NOT NULL DEFAULT 0
);
CREATE INDEX ix_amendment_visit ON visit.visit_report_amendment (visit_id, amended_at DESC);

-- Photos and other attachments linked to a visit
CREATE TABLE visit.visit_attachment (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    visit_id       uuid NOT NULL REFERENCES visit.visit(id) ON DELETE CASCADE,
    attachment_id  uuid NOT NULL,               -- expense.attachment(id); FK added in 06
    kind           text NOT NULL CHECK (kind IN ('SELFIE','SIGNATURE','SITE_PHOTO','DOCUMENT','VOICE_NOTE')),
    caption        text,
    row_version    bigint NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_visit_attachment ON visit.visit_attachment (visit_id);

-- ---------------------------------------------------------------------
-- Visit ↔ opportunity: which visit advanced which deal. Many-to-many,
-- because one call often covers several open opportunities.
-- ---------------------------------------------------------------------
CREATE TABLE visit.visit_opportunity (
    visit_id        uuid NOT NULL REFERENCES visit.visit(id) ON DELETE CASCADE,
    opportunity_id  uuid NOT NULL REFERENCES customer.opportunity(id),
    stage_before    text,
    stage_after     text,
    value_before    numeric(14,2),
    value_after     numeric(14,2),
    discussed_note  text,
    linked_at       timestamptz NOT NULL DEFAULT now(),
    row_version     bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (visit_id, opportunity_id)
);
CREATE INDEX ix_visit_opportunity_opp ON visit.visit_opportunity (opportunity_id);

-- Late FK: stage history records the visit that moved the deal
ALTER TABLE customer.opportunity_stage_history
    ADD CONSTRAINT fk_opp_history_visit FOREIGN KEY (visit_id) REFERENCES visit.visit(id);

SELECT config.fn_make_syncable('visit.visit',            'user_id', 'customer_id');
SELECT config.fn_make_syncable('visit.visit_report',     'user_id', '-', 'visit_id');
SELECT config.fn_make_syncable('visit.form_template',    '-', '-');
SELECT config.fn_make_syncable('visit.visit_attachment', '-', '-');
