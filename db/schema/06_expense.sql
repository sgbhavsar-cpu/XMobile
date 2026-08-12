-- =====================================================================
-- XMobile — 06 Attachments, OCR, expense capture
-- Capture-only: XInfo owns approval and settlement (docs/05).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Attachments: binaries live in MinIO, metadata here.
-- Shared by expenses and visits.
-- ---------------------------------------------------------------------
CREATE TABLE expense.attachment (
    id               uuid PRIMARY KEY,                 -- client-generated UUIDv7
    owner_user_id    uuid NOT NULL REFERENCES identity.app_user(id),
    file_name        text NOT NULL,
    mime_type        text NOT NULL,
    size_bytes       bigint NOT NULL CHECK (size_bytes >= 0),
    sha256           char(64) NOT NULL,
    storage_bucket   text NOT NULL DEFAULT 'xmobile',
    storage_key      text NOT NULL,
    thumbnail_key    text,
    page_count       smallint,                          -- PDFs
    status           expense.attachment_status NOT NULL DEFAULT 'PENDING_UPLOAD',
    -- provenance: how the file arrived (share-intent from UPI app, camera, etc.)
    capture_source   expense.capture_source NOT NULL DEFAULT 'MANUAL',
    source_app       text,                              -- e.g. 'com.google.android.apps.nbu.paisa.user'
    captured_at      timestamptz,
    captured_geog    geography(Point,4326),
    exif             jsonb NOT NULL DEFAULT '{}'::jsonb,
    virus_scan_status text CHECK (virus_scan_status IN ('PENDING','CLEAN','INFECTED','SKIPPED')),
    virus_scanned_at timestamptz,
    uploaded_at      timestamptz,
    upload_parts     smallint,
    row_version      bigint NOT NULL DEFAULT 0,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz
);
CREATE INDEX ix_attachment_owner  ON expense.attachment (owner_user_id, created_at DESC);
-- Content dedupe: the same UPI screenshot shared twice uploads once.
CREATE UNIQUE INDEX ux_attachment_sha ON expense.attachment (owner_user_id, sha256) WHERE deleted_at IS NULL;

-- Late FK from visit.visit_attachment now that the table exists
ALTER TABLE visit.visit_attachment
    ADD CONSTRAINT fk_visit_attachment_att FOREIGN KEY (attachment_id) REFERENCES expense.attachment(id);

-- ---------------------------------------------------------------------
-- OCR / document extraction (pre-fills the expense form)
-- ---------------------------------------------------------------------
CREATE TABLE expense.ocr_extraction (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    attachment_id    uuid NOT NULL REFERENCES expense.attachment(id) ON DELETE CASCADE,
    engine           text NOT NULL,            -- MLKIT_ONDEVICE / TESSERACT / PADDLEOCR
    engine_version   text,
    doc_type         text,                     -- UPI_SCREENSHOT / TAX_INVOICE / TICKET_PDF / TOLL_RECEIPT / HOTEL_BILL
    raw_text         text,
    amount           numeric(14,2),
    currency         char(3),
    txn_date         date,
    txn_time         time,
    merchant_name    text,
    payment_ref      text,                     -- UPI txn id / invoice no / PNR
    payment_mode     text,                     -- UPI / CARD / CASH / NETBANKING
    from_place       text,
    to_place         text,
    gst_amount       numeric(14,2),
    confidence       numeric(3,2),
    fields           jsonb NOT NULL DEFAULT '{}'::jsonb,
    extracted_at     timestamptz NOT NULL DEFAULT now(),
    processed_on     text NOT NULL DEFAULT 'DEVICE' CHECK (processed_on IN ('DEVICE','SERVER'))
);
CREATE INDEX ix_ocr_attachment ON expense.ocr_extraction (attachment_id);

-- ---------------------------------------------------------------------
-- Expense categories (mapped to XInfo codes via integration.code_map)
-- ---------------------------------------------------------------------
CREATE TABLE expense.expense_category (
    code              text PRIMARY KEY,
    name              text NOT NULL,
    parent_code       text REFERENCES expense.expense_category(code),
    requires_receipt  boolean NOT NULL DEFAULT true,
    receipt_threshold numeric(14,2),          -- receipt required above this amount only
    is_distance_based boolean NOT NULL DEFAULT false,   -- mileage
    is_per_diem       boolean NOT NULL DEFAULT false,
    requires_route    boolean NOT NULL DEFAULT false,   -- from/to cities mandatory
    requires_tour     boolean NOT NULL DEFAULT false,
    daily_cap         numeric(14,2),          -- soft warning only; XInfo enforces policy
    xinfo_code        text,
    sort_order        smallint NOT NULL DEFAULT 0,
    is_active         boolean NOT NULL DEFAULT true,
    row_version       bigint NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

-- Mileage rates by mode and grade (used to pre-fill distance-based claims)
CREATE TABLE expense.mileage_rate (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    travel_mode   tracking.travel_mode NOT NULL,
    grade         text,
    rate_per_km   numeric(10,2) NOT NULL,
    currency      char(3) NOT NULL DEFAULT 'INR',
    effective_from date NOT NULL,
    effective_to   date,
    row_version   bigint NOT NULL DEFAULT 0,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_mileage_lookup ON expense.mileage_rate (travel_mode, grade, effective_from DESC);

-- ---------------------------------------------------------------------
-- Expenses
-- ---------------------------------------------------------------------
CREATE TABLE expense.expense (
    id                uuid PRIMARY KEY,                    -- client-generated UUIDv7
    user_id           uuid NOT NULL REFERENCES identity.app_user(id),
    tour_id           uuid REFERENCES planning.tour(id),
    tour_day_id       uuid REFERENCES planning.tour_day(id),
    visit_id          uuid REFERENCES visit.visit(id),
    category_code     text NOT NULL REFERENCES expense.expense_category(code),
    expense_date      date NOT NULL,
    amount            numeric(14,2) NOT NULL CHECK (amount >= 0),
    currency          char(3) NOT NULL DEFAULT 'INR',
    tax_amount        numeric(14,2),
    payment_mode      text CHECK (payment_mode IN ('CASH','UPI','CARD','NETBANKING','COMPANY_PAID','OTHER')),
    merchant_name     text,
    payment_ref       text,
    description       text,

    -- travel-specific
    travel_mode       tracking.travel_mode,
    from_place        text,
    to_place          text,
    distance_km       numeric(10,2),
    distance_source   text CHECK (distance_source IN ('MANUAL','TRACKED','ESTIMATED')),
    rate_per_km       numeric(10,2),

    -- capture provenance
    capture_source    expense.capture_source NOT NULL DEFAULT 'MANUAL',
    source_app        text,
    ocr_extraction_id uuid REFERENCES expense.ocr_extraction(id),
    ocr_confidence    numeric(3,2),
    was_ocr_edited    boolean NOT NULL DEFAULT false,
    captured_geog     geography(Point,4326),

    -- duplicate detection
    duplicate_of_id   uuid REFERENCES expense.expense(id),
    duplicate_score   numeric(3,2),

    status            expense.expense_status NOT NULL DEFAULT 'DRAFT',
    submitted_at      timestamptz,

    -- XInfo linkage (capture-only model)
    xinfo_ref         text,
    pushed_at         timestamptz,
    acknowledged_at   timestamptz,
    xinfo_status      text,           -- mirrored for display: PENDING / APPROVED / REJECTED / PAID
    xinfo_status_at   timestamptz,
    xinfo_remark      text,
    settled_amount    numeric(14,2),
    settled_on        date,
    push_error        text,

    device_id         uuid REFERENCES identity.device(id),
    row_version       bigint NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at        timestamptz
);
CREATE INDEX ix_expense_user_date ON expense.expense (user_id, expense_date DESC) WHERE deleted_at IS NULL;
CREATE INDEX ix_expense_tour      ON expense.expense (tour_id);
CREATE INDEX ix_expense_status    ON expense.expense (status) WHERE deleted_at IS NULL;
CREATE INDEX ix_expense_pending_push ON expense.expense (submitted_at)
    WHERE status IN ('SUBMITTED','PUSH_FAILED') AND deleted_at IS NULL;
-- Duplicate-suspect probe: same user, date and amount
CREATE INDEX ix_expense_dupe_probe ON expense.expense (user_id, expense_date, amount) WHERE deleted_at IS NULL;

CREATE TABLE expense.expense_attachment (
    expense_id     uuid NOT NULL REFERENCES expense.expense(id) ON DELETE CASCADE,
    attachment_id  uuid NOT NULL REFERENCES expense.attachment(id),
    kind           text NOT NULL DEFAULT 'RECEIPT' CHECK (kind IN ('RECEIPT','TICKET','SCREENSHOT','INVOICE','OTHER')),
    added_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (expense_id, attachment_id)
);

-- Inbox for files shared into the app before they are turned into an expense
-- (Android share sheet / iOS share extension — docs/07 §6)
CREATE TABLE expense.share_inbox_item (
    id             uuid PRIMARY KEY,
    user_id        uuid NOT NULL REFERENCES identity.app_user(id),
    attachment_id  uuid REFERENCES expense.attachment(id),
    received_at    timestamptz NOT NULL DEFAULT now(),
    source_app     text,
    shared_text    text,                       -- some apps share text alongside the image
    suggested_category_code text REFERENCES expense.expense_category(code),
    suggested_amount numeric(14,2),
    suggested_date   date,
    status         text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','CONVERTED','DISMISSED')),
    expense_id     uuid REFERENCES expense.expense(id),
    dismissed_reason text,
    row_version    bigint NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_share_inbox_user ON expense.share_inbox_item (user_id, status, received_at DESC);

SELECT config.fn_make_syncable('expense.expense',           'user_id', '-');
SELECT config.fn_make_syncable('expense.attachment',        'owner_user_id', '-');
SELECT config.fn_make_syncable('expense.share_inbox_item',  'user_id', '-');
SELECT config.fn_make_syncable('expense.expense_category',  '-', '-', 'code');
SELECT config.fn_make_syncable('expense.mileage_rate',      '-', '-');
