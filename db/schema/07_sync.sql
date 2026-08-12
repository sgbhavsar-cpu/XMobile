-- =====================================================================
-- XMobile — 07 Sync: mutation intake, conflicts, device cursors, policy
-- (sync.change_log itself is created in 00_extensions.sql)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Idempotency ledger for client → server mutations
-- ---------------------------------------------------------------------
CREATE TABLE sync.client_mutation (
    client_mutation_id uuid PRIMARY KEY,          -- generated on the device
    device_id          uuid NOT NULL REFERENCES identity.device(id),
    user_id            uuid NOT NULL REFERENCES identity.app_user(id),
    entity             text NOT NULL,
    entity_id          uuid NOT NULL,
    op                 sync.mutation_op NOT NULL,
    base_version       bigint,
    occurred_at        timestamptz,               -- device time of the business action
    received_at        timestamptz NOT NULL DEFAULT now(),
    status             sync.mutation_status NOT NULL,
    applied_version    bigint,
    conflict_id        uuid,
    error_code         text,
    error_detail       text,
    payload_hash       char(64),
    batch_id           uuid
);
CREATE INDEX ix_mutation_device ON sync.client_mutation (device_id, received_at DESC);
CREATE INDEX ix_mutation_entity ON sync.client_mutation (entity, entity_id);

-- ---------------------------------------------------------------------
-- Conflicts surfaced back to the rep's "Sync issues" inbox (docs/04 §4)
-- ---------------------------------------------------------------------
CREATE TABLE sync.sync_conflict (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            uuid NOT NULL REFERENCES identity.app_user(id),
    device_id          uuid REFERENCES identity.device(id),
    entity             text NOT NULL,
    entity_id          uuid NOT NULL,
    client_mutation_id uuid,
    reason             text NOT NULL,   -- STALE_VERSION / IMMUTABLE_STATE / SCOPE_LOST / VALIDATION / POLICY
    resolution         text NOT NULL,   -- SERVER_WINS / CLIENT_WINS / FIELD_MERGE / MANUAL_REQUIRED
    client_payload     jsonb NOT NULL,
    server_payload     jsonb,
    merged_payload     jsonb,
    detected_at        timestamptz NOT NULL DEFAULT now(),
    acknowledged_at    timestamptz,
    resolved_at        timestamptz,
    resolved_by        uuid REFERENCES identity.app_user(id),
    row_version        bigint NOT NULL DEFAULT 0,
    updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_conflict_user_open ON sync.sync_conflict (user_id) WHERE resolved_at IS NULL;

-- ---------------------------------------------------------------------
-- Per-device sync state (server-side view of what a device has)
-- ---------------------------------------------------------------------
CREATE TABLE sync.device_sync_state (
    device_id        uuid NOT NULL REFERENCES identity.device(id) ON DELETE CASCADE,
    entity           text NOT NULL,
    last_cursor      bigint NOT NULL DEFAULT 0,    -- last sync.change_log.id delivered
    last_pull_at     timestamptz,
    last_push_at     timestamptz,
    rows_delivered   bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (device_id, entity)
);

CREATE TABLE sync.sync_session (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id      uuid NOT NULL REFERENCES identity.device(id),
    user_id        uuid NOT NULL REFERENCES identity.app_user(id),
    direction      text NOT NULL CHECK (direction IN ('PULL','PUSH','BOTH')),
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    mutations_sent integer NOT NULL DEFAULT 0,
    mutations_applied integer NOT NULL DEFAULT 0,
    mutations_conflicted integer NOT NULL DEFAULT 0,
    changes_delivered integer NOT NULL DEFAULT 0,
    bytes_out      bigint,
    bytes_in       bigint,
    network_type   text,
    outcome        text CHECK (outcome IN ('SUCCESS','PARTIAL','FAILED','ABORTED')),
    error          text
);
CREATE INDEX ix_sync_session_device ON sync.sync_session (device_id, started_at DESC);

-- ---------------------------------------------------------------------
-- Admin-tunable sync window (the "tunable" in the offline decision)
-- ---------------------------------------------------------------------
CREATE TABLE sync.sync_policy (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    role_code             text REFERENCES identity.app_role(code),   -- NULL = default policy
    entity                text NOT NULL,
    back_days             integer NOT NULL DEFAULT 90,
    forward_days          integer NOT NULL DEFAULT 30,
    include_team_data     boolean NOT NULL DEFAULT false,
    attachments_mode      text NOT NULL DEFAULT 'WIFI_ONLY'
                          CHECK (attachments_mode IN ('ALWAYS','WIFI_ONLY','METADATA_ONLY','NEVER')),
    max_attachment_mb     integer NOT NULL DEFAULT 10,
    refresh_minutes       integer NOT NULL DEFAULT 15,
    pull_page_size        integer NOT NULL DEFAULT 500,
    push_batch_size       integer NOT NULL DEFAULT 100,
    max_outbox_rows       integer NOT NULL DEFAULT 20000,
    policy_version        integer NOT NULL DEFAULT 1,
    row_version           bigint  NOT NULL DEFAULT 0,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_sync_policy ON sync.sync_policy
    (COALESCE(role_code,'*'), entity);

SELECT config.fn_make_syncable('sync.sync_policy', '-', '-');

-- ---------------------------------------------------------------------
-- Retention / housekeeping registry (driven by a nightly job)
-- ---------------------------------------------------------------------
CREATE TABLE sync.retention_rule (
    entity        text PRIMARY KEY,
    keep_days     integer NOT NULL,
    action        text NOT NULL CHECK (action IN ('PURGE','ARCHIVE','AGGREGATE_THEN_PURGE','DETACH_PARTITION')),
    last_run_at   timestamptz,
    last_removed  bigint,
    is_active     boolean NOT NULL DEFAULT true
);
