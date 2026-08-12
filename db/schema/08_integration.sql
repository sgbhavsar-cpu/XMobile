-- =====================================================================
-- XMobile — 08 XInfo integration, audit, notifications
-- =====================================================================

-- ---------------------------------------------------------------------
-- Transactional outbox: written in the same tx as the business row
-- ---------------------------------------------------------------------
CREATE TABLE integration.outbox_message (
    id               bigserial PRIMARY KEY,
    message_id       uuid NOT NULL DEFAULT gen_random_uuid(),
    target_system    text NOT NULL DEFAULT 'XINFO',
    message_type     text NOT NULL,     -- VISIT_COMPLETED / EXPENSE_CAPTURED / TOUR_COMPLETED / ...
    aggregate_type   text NOT NULL,
    aggregate_id     uuid NOT NULL,
    idempotency_key  text NOT NULL,     -- e.g. 'expense:{id}:v{row_version}'
    payload          jsonb NOT NULL,    -- snapshot, self-contained
    schema_version   integer NOT NULL DEFAULT 1,
    status           integration.outbox_status NOT NULL DEFAULT 'PENDING',
    attempts         smallint NOT NULL DEFAULT 0,
    max_attempts     smallint NOT NULL DEFAULT 12,
    next_attempt_at  timestamptz NOT NULL DEFAULT now(),
    claimed_by       text,
    claimed_at       timestamptz,
    sent_at          timestamptz,
    response_ref     text,              -- XInfo's id for the pushed record
    last_error       text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_outbox_idem  ON integration.outbox_message (target_system, idempotency_key);
CREATE INDEX ix_outbox_due          ON integration.outbox_message (next_attempt_at)
    WHERE status IN ('PENDING','FAILED');
CREATE INDEX ix_outbox_aggregate    ON integration.outbox_message (aggregate_type, aggregate_id, id);
CREATE INDEX ix_outbox_dead         ON integration.outbox_message (created_at) WHERE status = 'DEAD';

-- ---------------------------------------------------------------------
-- Inbound pull runs (customers, hierarchy, reference data, statuses)
-- ---------------------------------------------------------------------
CREATE TABLE integration.inbound_sync_run (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_system   text NOT NULL DEFAULT 'XINFO',
    entity          text NOT NULL,
    mode            text NOT NULL DEFAULT 'DELTA' CHECK (mode IN ('DELTA','FULL','TARGETED','WEBHOOK')),
    cursor_from     timestamptz,
    cursor_to       timestamptz,
    started_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz,
    status          integration.run_status NOT NULL DEFAULT 'RUNNING',
    records_read    integer NOT NULL DEFAULT 0,
    records_created integer NOT NULL DEFAULT 0,
    records_updated integer NOT NULL DEFAULT 0,
    records_skipped integer NOT NULL DEFAULT 0,
    records_failed  integer NOT NULL DEFAULT 0,
    error           text,
    details         jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX ix_inbound_run ON integration.inbound_sync_run (entity, started_at DESC);

-- ---------------------------------------------------------------------
-- Local ↔ XInfo identity map (basis of reconciliation and support answers)
-- ---------------------------------------------------------------------
CREATE TABLE integration.xinfo_entity_map (
    local_type              text NOT NULL,
    local_id                uuid NOT NULL,
    xinfo_type              text NOT NULL,
    xinfo_id                text NOT NULL,
    last_pushed_row_version bigint,
    last_pushed_at          timestamptz,
    last_acked_at           timestamptz,
    PRIMARY KEY (local_type, local_id)
);
CREATE UNIQUE INDEX ux_xinfo_map_remote ON integration.xinfo_entity_map (xinfo_type, xinfo_id);

-- Editable code mappings (expense categories, visit types, outcomes)
CREATE TABLE integration.code_map (
    domain      text NOT NULL,      -- EXPENSE_CATEGORY / VISIT_TYPE / VISIT_OUTCOME / TRAVEL_MODE
    local_code  text NOT NULL,
    xinfo_code  text NOT NULL,
    direction   text NOT NULL DEFAULT 'BOTH' CHECK (direction IN ('IN','OUT','BOTH')),
    is_active   boolean NOT NULL DEFAULT true,
    PRIMARY KEY (domain, local_code)
);

-- ---------------------------------------------------------------------
-- Nightly reconciliation output (docs/05 §6) — the safety net for
-- capture-only expenses
-- ---------------------------------------------------------------------
CREATE TABLE integration.reconciliation_run (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_date        date NOT NULL,
    entity          text NOT NULL,
    local_count     integer NOT NULL DEFAULT 0,
    remote_count    integer NOT NULL DEFAULT 0,
    local_sum       numeric(16,2),
    remote_sum      numeric(16,2),
    missing_remote  uuid[],
    missing_local   text[],
    status          text NOT NULL DEFAULT 'OK' CHECK (status IN ('OK','DISCREPANCY','FAILED')),
    details         jsonb NOT NULL DEFAULT '{}'::jsonb,
    started_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz
);
CREATE INDEX ix_recon_date ON integration.reconciliation_run (run_date DESC, entity);

-- ---------------------------------------------------------------------
-- Audit log — append-only (revoke UPDATE/DELETE from the app role)
-- ---------------------------------------------------------------------
CREATE TABLE audit.audit_log (
    id            bigserial PRIMARY KEY,
    occurred_at   timestamptz NOT NULL DEFAULT now(),
    actor_user_id uuid,
    actor_role    text,
    device_id     uuid,
    ip_address    inet,
    entity        text NOT NULL,
    entity_id     uuid,
    action        text NOT NULL,      -- CREATE / UPDATE / DELETE / SUBMIT / OVERRIDE / VIEW_TRAIL /
                                      -- EXPORT / REVOKE_DEVICE / CONFIG_CHANGE / PUSH_RETRY
    before_json   jsonb,
    after_json    jsonb,
    context       jsonb NOT NULL DEFAULT '{}'::jsonb,
    request_id    text
);
CREATE INDEX ix_audit_entity ON audit.audit_log (entity, entity_id, occurred_at DESC);
CREATE INDEX ix_audit_actor  ON audit.audit_log (actor_user_id, occurred_at DESC);
CREATE INDEX ix_audit_time   ON audit.audit_log (occurred_at DESC);

-- ---------------------------------------------------------------------
-- Notifications (push is notification-only; the app fetches the payload)
-- ---------------------------------------------------------------------
CREATE TABLE integration.notification (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid NOT NULL REFERENCES identity.app_user(id),
    type         text NOT NULL,   -- PLAN_ASSIGNED / PLAN_CHANGED / VISIT_CLOSE_PROMPT / EXPENSE_STATUS /
                                  -- SYNC_HINT / TRACKING_HEALTH / CONFLICT / ANOMALY
    title        text NOT NULL,
    body         text,
    data         jsonb NOT NULL DEFAULT '{}'::jsonb,   -- ids only, no business data
    priority     text NOT NULL DEFAULT 'NORMAL' CHECK (priority IN ('LOW','NORMAL','HIGH')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    sent_at      timestamptz,
    delivered_at timestamptz,
    read_at      timestamptz,
    send_error   text,
    row_version  bigint NOT NULL DEFAULT 0,
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_notification_user ON integration.notification (user_id, created_at DESC);
CREATE INDEX ix_notification_unread ON integration.notification (user_id) WHERE read_at IS NULL;

SELECT config.fn_make_syncable('integration.notification', 'user_id', '-');
