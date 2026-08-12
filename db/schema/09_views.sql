-- =====================================================================
-- XMobile — 09 Views and helper functions for dashboards and the API
-- =====================================================================

-- ---------------------------------------------------------------------
-- The rep's visible customer set (drives the offline working set and RLS-style scoping)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW customer.v_user_customer_scope AS
SELECT a.user_id,
       a.customer_id,
       c.name        AS customer_name,
       a.role        AS assignment_role
FROM   customer.customer_assignment a
JOIN   customer.customer_account   c ON c.id = a.customer_id
WHERE  a.deleted_at IS NULL
  AND  c.deleted_at IS NULL
  AND  c.is_active
  AND (a.valid_to IS NULL OR a.valid_to >= CURRENT_DATE);

-- Manager scope: self + all descendants
CREATE OR REPLACE FUNCTION identity.fn_visible_user_ids(p_user_id uuid)
RETURNS TABLE (user_id uuid) LANGUAGE sql STABLE AS $$
    SELECT p_user_id
    UNION
    SELECT h.descendant_id
    FROM   identity.user_hierarchy_closure h
    WHERE  h.ancestor_id = p_user_id;
$$;

-- ---------------------------------------------------------------------
-- Live day view for the manager dashboard
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW tracking.v_live_status AS
SELECT u.id                          AS user_id,
       u.full_name,
       u.employee_code,
       u.manager_id,
       s.state,
       s.since,
       s.tracking_active,
       s.last_ping_at,
       EXTRACT(epoch FROM (now() - s.last_ping_at))::integer AS last_ping_age_s,
       s.health_score,
       t.id                          AS tour_id,
       t.title                       AS tour_title,
       cs.name                       AS current_site_name,
       ca.name                       AS current_customer_name,
       d.tracking_health_score       AS device_health_score,
       d.location_permission,
       d.battery_optimised
FROM   identity.app_user u
LEFT   JOIN tracking.user_journey_state s ON s.user_id = u.id
LEFT   JOIN planning.tour               t ON t.id = s.tour_id
LEFT   JOIN customer.customer_site     cs ON cs.id = s.site_id
LEFT   JOIN customer.customer_account  ca ON ca.id = cs.customer_id
LEFT   JOIN LATERAL (
        SELECT * FROM identity.device dv
        WHERE dv.user_id = u.id AND dv.revoked_at IS NULL
        ORDER BY dv.last_seen_at DESC NULLS LAST LIMIT 1) d ON true
WHERE  u.status = 'ACTIVE' AND u.deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- Plan vs actual, per rep per day (compares against the baseline plan)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW planning.v_plan_vs_actual AS
WITH planned AS (
    SELECT p.user_id, p.planned_date AS local_date,
           count(*) FILTER (WHERE p.is_baseline)                       AS planned_baseline,
           count(*)                                                    AS planned_total,
           count(*) FILTER (WHERE p.status = 'COMPLETED')              AS plan_completed,
           count(*) FILTER (WHERE p.status = 'SKIPPED')                AS plan_skipped
    FROM   planning.visit_plan p
    WHERE  p.deleted_at IS NULL
    GROUP  BY 1,2
), actual AS (
    SELECT v.user_id, v.local_date,
           count(*)                                        AS visits_done,
           count(*) FILTER (WHERE v.is_unplanned)          AS visits_unplanned,
           min(v.check_in_at)                              AS first_check_in,
           max(v.check_out_at)                             AS last_check_out,
           avg(v.duration_min)::numeric(10,1)              AS avg_duration_min,
           count(*) FILTER (WHERE v.is_out_of_geofence)    AS out_of_fence_count
    FROM   visit.visit v
    WHERE  v.deleted_at IS NULL AND v.status <> 'VOIDED'
    GROUP  BY 1,2
)
SELECT COALESCE(p.user_id, a.user_id)     AS user_id,
       COALESCE(p.local_date, a.local_date) AS local_date,
       COALESCE(p.planned_baseline, 0)    AS planned_baseline,
       COALESCE(p.planned_total, 0)       AS planned_total,
       COALESCE(p.plan_completed, 0)      AS plan_completed,
       COALESCE(p.plan_skipped, 0)        AS plan_skipped,
       COALESCE(a.visits_done, 0)         AS visits_done,
       COALESCE(a.visits_unplanned, 0)    AS visits_unplanned,
       a.first_check_in,
       a.last_check_out,
       a.avg_duration_min,
       COALESCE(a.out_of_fence_count, 0)  AS out_of_fence_count,
       CASE WHEN COALESCE(p.planned_baseline,0) = 0 THEN NULL
            ELSE round(100.0 * COALESCE(p.plan_completed,0) / p.planned_baseline, 1)
       END                                AS plan_adherence_pct
FROM   planned p
FULL   JOIN actual a ON a.user_id = p.user_id AND a.local_date = p.local_date;

-- ---------------------------------------------------------------------
-- Tour summary (for the manager and for the XInfo TOUR_COMPLETED push)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW planning.v_tour_summary AS
SELECT t.id AS tour_id,
       t.user_id,
       t.title,
       t.status,
       t.planned_start_date,
       t.planned_end_date,
       t.actual_start_at,
       t.actual_end_at,
       (SELECT count(*) FROM planning.visit_plan vp
         WHERE vp.tour_id = t.id AND vp.deleted_at IS NULL)                       AS planned_visits,
       (SELECT count(*) FROM visit.visit v
         WHERE v.tour_id = t.id AND v.deleted_at IS NULL AND v.status <> 'VOIDED') AS actual_visits,
       (SELECT COALESCE(sum(s.distance_m),0) FROM tracking.journey_segment s
         WHERE s.tour_id = t.id AND s.superseded_by_id IS NULL)                    AS distance_m,
       (SELECT COALESCE(sum(e.amount),0) FROM expense.expense e
         WHERE e.tour_id = t.id AND e.deleted_at IS NULL)                          AS expense_total,
       (SELECT count(*) FROM tracking.tracking_anomaly an
         WHERE an.tour_id = t.id AND an.severity IN ('HIGH','CRITICAL'))           AS high_anomalies
FROM   planning.tour t
WHERE  t.deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- Exception report feed
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW tracking.v_exceptions AS
SELECT a.id, a.user_id, a.local_date, a.anomaly_type, a.severity,
       a.window_start, a.window_end, a.duration_s, a.details,
       a.acknowledged_at, a.resolved_at, 'ANOMALY'::text AS source
FROM   tracking.tracking_anomaly a
UNION ALL
SELECT v.id, v.user_id, v.local_date, 'CHECKIN_OUT_OF_FENCE', 'MEDIUM',
       v.check_in_at, v.check_in_at, 0,
       jsonb_build_object('distance_m', v.check_in_distance_m,
                          'reason', v.out_of_fence_reason_code,
                          'site_id', v.site_id),
       NULL, NULL, 'VISIT'
FROM   visit.visit v
WHERE  v.is_out_of_geofence AND v.deleted_at IS NULL
UNION ALL
SELECT p.id, p.user_id, p.paused_at::date, 'TRACKING_PAUSE', 'LOW',
       p.paused_at, p.resumed_at,
       EXTRACT(epoch FROM (COALESCE(p.resumed_at, now()) - p.paused_at))::integer,
       jsonb_build_object('reason', p.reason_code, 'auto_resumed', p.auto_resumed),
       NULL, NULL, 'PAUSE'
FROM   tracking.tracking_pause p;

-- ---------------------------------------------------------------------
-- Customer 360: what the rep sees before walking in (all offline-cached)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW customer.v_customer_360 AS
SELECT c.id AS customer_id,
       c.name,
       c.lifecycle_status,
       c.category,
       (SELECT count(*) FROM customer.customer_site s
         WHERE s.customer_id = c.id AND s.deleted_at IS NULL)                AS site_count,
       (SELECT max(v.check_in_at) FROM visit.visit v
         WHERE v.customer_id = c.id AND v.deleted_at IS NULL)                AS last_visit_at,
       (SELECT count(*) FROM visit.visit v
         WHERE v.customer_id = c.id AND v.deleted_at IS NULL
           AND v.check_in_at > now() - interval '90 days')                   AS visits_90d,
       (SELECT COALESCE(sum(sh.amount),0) FROM customer.sales_history sh
         WHERE sh.customer_id = c.id AND sh.deleted_at IS NULL
           AND sh.document_type = 'ORDER'
           AND sh.document_date > CURRENT_DATE - 365)                        AS sales_12m,
       (SELECT max(sh.document_date) FROM customer.sales_history sh
         WHERE sh.customer_id = c.id AND sh.deleted_at IS NULL)              AS last_order_date,
       (SELECT count(*) FROM customer.opportunity o
         JOIN config.opportunity_stage st ON st.code = o.stage_code
         WHERE o.customer_id = c.id AND o.deleted_at IS NULL AND st.is_open) AS open_opportunities,
       (SELECT COALESCE(sum(o.estimated_value),0) FROM customer.opportunity o
         JOIN config.opportunity_stage st ON st.code = o.stage_code
         WHERE o.customer_id = c.id AND o.deleted_at IS NULL AND st.is_open) AS open_pipeline_value
FROM   customer.customer_account c
WHERE  c.deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- Pipeline view: open opportunities with age and staleness
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW customer.v_open_pipeline AS
SELECT o.id                AS opportunity_id,
       o.customer_id,
       c.name              AS customer_name,
       o.owner_user_id,
       o.title,
       o.stage_code,
       st.name             AS stage_name,
       st.probability_pct  AS stage_probability,
       o.estimated_value,
       o.expected_close_date,
       (o.expected_close_date < CURRENT_DATE)                      AS is_overdue,
       EXTRACT(day FROM (now() - o.created_at))::integer           AS age_days,
       (SELECT max(v.check_in_at) FROM visit.visit_opportunity vo
         JOIN visit.visit v ON v.id = vo.visit_id
        WHERE vo.opportunity_id = o.id)                            AS last_touched_at,
       o.is_field_created
FROM   customer.opportunity o
JOIN   config.opportunity_stage st ON st.code = o.stage_code
JOIN   customer.customer_account c ON c.id = o.customer_id
WHERE  o.deleted_at IS NULL AND st.is_open;

-- ---------------------------------------------------------------------
-- Helper: nearest customer site to a point (site matching during inference)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION customer.fn_match_site(p_point geography, p_user_id uuid, p_max_m integer DEFAULT 500)
RETURNS TABLE (site_id uuid, customer_id uuid, distance_m double precision, within_fence boolean)
LANGUAGE sql STABLE AS $$
    SELECT s.id, s.customer_id,
           ST_Distance(s.geog, p_point) AS distance_m,
           ST_Distance(s.geog, p_point) <= s.geofence_radius_m AS within_fence
    FROM   customer.customer_site s
    JOIN   customer.v_user_customer_scope sc
           ON sc.customer_id = s.customer_id AND sc.user_id = p_user_id
    WHERE  s.geog IS NOT NULL
      AND  s.deleted_at IS NULL
      AND  ST_DWithin(s.geog, p_point, GREATEST(p_max_m, s.geofence_radius_m))
    ORDER  BY s.geog <-> p_point::geometry::geography
    LIMIT  5;
$$;

-- ---------------------------------------------------------------------
-- Helper: suggest a geofence radius from historical confirmed check-ins
-- (docs/02 §3 — one radius does not fit a rural yard and a city office)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION customer.fn_suggest_radius(p_site_id uuid)
RETURNS integer LANGUAGE sql STABLE AS $$
    SELECT GREATEST(80, LEAST(1000,
             (percentile_disc(0.9) WITHIN GROUP (
                 ORDER BY ST_Distance(v.check_in_geog, s.geog)) * 1.2)::integer))
    FROM   visit.visit v
    JOIN   customer.customer_site s ON s.id = v.site_id
    WHERE  v.site_id = p_site_id
      AND  v.check_in_geog IS NOT NULL
      AND  v.check_in_accuracy_m <= 50
      AND  v.deleted_at IS NULL
      AND  v.check_in_at > now() - interval '180 days'
    HAVING count(*) >= 5;
$$;

-- ---------------------------------------------------------------------
-- Expense duplicate probe (image hash OR same amount/date/merchant)
-- ---------------------------------------------------------------------
-- ---------------------------------------------------------------------
-- Suggested mileage amount from tracked distance (indicative only —
-- XInfo recomputes authoritatively; docs/05 §5)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION expense.fn_suggest_mileage(p_user_id uuid, p_date date)
RETURNS TABLE (distance_km numeric, estimated_km numeric, travel_mode tracking.travel_mode,
               rate_per_km numeric, suggested_amount numeric)
LANGUAGE sql STABLE AS $$
    WITH seg AS (
        SELECT s.travel_mode,
               sum(s.distance_m) FILTER (WHERE NOT s.is_estimated) / 1000.0 AS tracked_km,
               sum(s.distance_m) FILTER (WHERE s.is_estimated)     / 1000.0 AS est_km
        FROM   tracking.journey_segment s
        WHERE  s.user_id = p_user_id
          AND  s.local_date = p_date
          AND  s.superseded_by_id IS NULL
          AND  s.segment_type IN ('OUTBOUND_TRAVEL','INTER_TRAVEL','RETURN_TRAVEL')
          AND  s.travel_mode IN ('CAR','TWO_WHEELER')     -- only own-vehicle modes are claimable per km
        GROUP  BY s.travel_mode
    )
    SELECT round(COALESCE(seg.tracked_km,0)::numeric, 2),
           round(COALESCE(seg.est_km,0)::numeric, 2),
           seg.travel_mode,
           r.rate_per_km,
           round((COALESCE(seg.tracked_km,0) + COALESCE(seg.est_km,0))::numeric * r.rate_per_km, 2)
    FROM   seg
    LEFT   JOIN LATERAL (
            SELECT mr.rate_per_km FROM expense.mileage_rate mr
            WHERE  mr.travel_mode = seg.travel_mode
              AND  mr.effective_from <= p_date
              AND  (mr.effective_to IS NULL OR mr.effective_to >= p_date)
            ORDER  BY mr.effective_from DESC LIMIT 1) r ON true;
$$;

CREATE OR REPLACE FUNCTION expense.fn_find_duplicates(p_expense_id uuid)
RETURNS TABLE (candidate_id uuid, score numeric, reason text)
LANGUAGE sql STABLE AS $$
    WITH me AS (
        SELECT e.*, (SELECT array_agg(a.sha256)
                     FROM expense.expense_attachment ea
                     JOIN expense.attachment a ON a.id = ea.attachment_id
                     WHERE ea.expense_id = e.id) AS hashes
        FROM expense.expense e WHERE e.id = p_expense_id
    )
    SELECT o.id,
           CASE WHEN oh.sha256 IS NOT NULL THEN 1.00
                WHEN o.amount = me.amount AND o.expense_date = me.expense_date
                     AND COALESCE(o.merchant_name,'') = COALESCE(me.merchant_name,'') THEN 0.85
                ELSE 0.60 END,
           CASE WHEN oh.sha256 IS NOT NULL THEN 'SAME_RECEIPT_IMAGE'
                ELSE 'SAME_AMOUNT_DATE' END
    FROM   me
    JOIN   expense.expense o
           ON  o.user_id = me.user_id
           AND o.id <> me.id
           AND o.deleted_at IS NULL
           AND o.expense_date BETWEEN me.expense_date - 2 AND me.expense_date + 2
           AND o.amount = me.amount
    LEFT   JOIN LATERAL (
            SELECT a.sha256 FROM expense.expense_attachment ea
            JOIN expense.attachment a ON a.id = ea.attachment_id
            WHERE ea.expense_id = o.id AND a.sha256 = ANY(COALESCE(me.hashes, ARRAY[]::char(64)[]))
            LIMIT 1) oh ON true;
$$;
