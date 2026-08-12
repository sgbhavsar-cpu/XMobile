-- =====================================================================
-- XMobile — 10 Reference data seed
-- =====================================================================

INSERT INTO identity.app_role (code, name, description, permissions) VALUES
 ('SALES_REP',  'Sales Representative', 'Field user: own tours, visits, reports, expenses',
  '["visit:write","expense:write","tour:write","report:write","self:read"]'),
 ('MANAGER',    'Manager',              'Own data plus all subordinates',
  '["team:read","plan:write","exception:review","report:read"]'),
 ('ADMIN',      'Administrator',        'Configuration and device administration',
  '["config:write","form:publish","device:revoke","geofence:write","user:manage"]'),
 ('AUDITOR',    'Auditor',              'Read-only across all data including audit log',
  '["*:read","audit:read"]'),
 ('INTEGRATION','Integration Service',  'XInfo service account',
  '["integration:write"]')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------
INSERT INTO config.visit_type (code, name, default_duration_min, requires_selfie, allows_remote, sort_order) VALUES
 ('SALES_CALL',   'Sales call',            45, false, false, 10),
 ('COLLECTION',   'Payment collection',    30, false, false, 20),
 ('SERVICE',      'Service / complaint',   60, true,  false, 30),
 ('DEMO',         'Product demonstration', 90, true,  false, 40),
 ('NEW_PROSPECT', 'New prospect',          45, true,  false, 50),
 ('COURTESY',     'Courtesy / relationship',30,false, false, 60),
 ('REMOTE_CALL',  'Telephonic / online',   20, false, true,  70)
ON CONFLICT (code) DO NOTHING;

INSERT INTO config.visit_outcome (code, name, is_positive, requires_follow_up, sort_order) VALUES
 ('ORDER_BOOKED',    'Order booked',            true,  false, 10),
 ('QUOTE_GIVEN',     'Quotation given',         true,  true,  20),
 ('NEGOTIATION',     'Under negotiation',       true,  true,  30),
 ('INFO_ONLY',       'Information shared',      true,  false, 40),
 ('COMPLAINT_LOGGED','Complaint logged',        false, true,  50),
 ('NO_REQUIREMENT',  'No current requirement',  false, false, 60),
 ('CONTACT_ABSENT',  'Contact not available',   false, true,  70),
 ('LOST_TO_COMPETITOR','Lost to competitor',    false, true,  80)
ON CONFLICT (code) DO NOTHING;

INSERT INTO config.reason_code (domain, code, name, requires_remark, sort_order) VALUES
 ('VISIT_SKIP','CUSTOMER_UNAVAILABLE','Customer unavailable',      false, 10),
 ('VISIT_SKIP','TIME_SHORTAGE',       'Ran out of time',           false, 20),
 ('VISIT_SKIP','TRAVEL_DELAY',        'Travel delay',              false, 30),
 ('VISIT_SKIP','CUSTOMER_CLOSED',     'Premises closed',           false, 40),
 ('VISIT_SKIP','PERSONAL_EMERGENCY',  'Personal emergency',        true,  50),
 ('VISIT_SKIP','OTHER',               'Other',                     true,  99),
 ('TRACKING_PAUSE','PERSONAL_BREAK',  'Personal / lunch break',    false, 10),
 ('TRACKING_PAUSE','LOW_BATTERY',     'Low battery',               false, 20),
 ('TRACKING_PAUSE','PRIVATE_TRIP',    'Personal trip in work hours',true, 30),
 ('TRACKING_PAUSE','DEVICE_ISSUE',    'Device problem',            true,  40),
 ('OUT_OF_GEOFENCE','MET_OUTSIDE',    'Met contact outside premises',true,10),
 ('OUT_OF_GEOFENCE','WRONG_LOCATION_ON_FILE','Recorded location is wrong',true,20),
 ('OUT_OF_GEOFENCE','GPS_INACCURATE', 'GPS inaccurate',            false, 30),
 ('TOUR_ABANDON','ILLNESS',           'Illness',                   true,  10),
 ('TOUR_ABANDON','RECALLED',          'Recalled by management',    true,  20),
 ('TOUR_ABANDON','TRAVEL_CANCELLED',  'Travel cancelled',          true,  30)
ON CONFLICT (domain, code) DO NOTHING;

-- ---------------------------------------------------------------------
INSERT INTO expense.expense_category
  (code, name, requires_receipt, receipt_threshold, is_distance_based, is_per_diem, requires_route, requires_tour, sort_order) VALUES
 ('TRAVEL_AIR',    'Air travel',        true,  NULL,  false, false, true,  true,  10),
 ('TRAVEL_RAIL',   'Rail travel',       true,  NULL,  false, false, true,  true,  20),
 ('TRAVEL_BUS',    'Bus travel',        true,  NULL,  false, false, true,  false, 30),
 ('TRAVEL_TAXI',   'Taxi / cab',        true,  200,   false, false, false, false, 40),
 ('TRAVEL_OWN_VEHICLE','Own vehicle (mileage)', false, NULL, true, false, true, false, 50),
 ('FUEL',          'Fuel',              true,  NULL,  false, false, false, false, 60),
 ('TOLL_PARKING',  'Toll / parking',    true,  100,   false, false, false, false, 70),
 ('LODGING',       'Hotel / lodging',   true,  NULL,  false, false, false, true,  80),
 ('MEALS',         'Meals',             true,  300,   false, false, false, false, 90),
 ('DAILY_ALLOWANCE','Daily allowance',  false, NULL,  false, true,  false, true, 100),
 ('CUSTOMER_ENTERTAINMENT','Customer entertainment', true, NULL, false, false, false, false, 110),
 ('COMMUNICATION', 'Phone / internet',  true,  NULL,  false, false, false, false, 120),
 ('COURIER',       'Courier / postage', true,  NULL,  false, false, false, false, 130),
 ('MISC',          'Miscellaneous',     true,  NULL,  false, false, false, false, 140)
ON CONFLICT (code) DO NOTHING;

INSERT INTO expense.mileage_rate (travel_mode, grade, rate_per_km, effective_from) VALUES
 ('TWO_WHEELER', NULL, 3.50, CURRENT_DATE),
 ('CAR',         NULL, 9.00, CURRENT_DATE)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Tracking tuning defaults (docs/03 §9)
-- ---------------------------------------------------------------------
INSERT INTO config.app_setting (key, value, data_type, description) VALUES
 ('tracking.home_radius_m',            '200',   'int',     'Default home geofence radius'),
 ('tracking.site_radius_m',            '150',   'int',     'Default customer site geofence radius'),
 ('tracking.min_dwell_arrival_min',    '4',     'int',     'Dwell needed to confirm arrival'),
 ('tracking.depart_displacement_m',    '500',   'int',     'Displacement confirming a departure'),
 ('tracking.gap_threshold_min',        '45',    'int',     'Evidence gap before state becomes UNKNOWN'),
 ('tracking.overnight_stationary_h',   '4',     'int',     'Stationary hours implying an overnight stop'),
 ('tracking.overnight_window_start',   '"21:00"','time',   'Overnight detection window start (device local)'),
 ('tracking.overnight_window_end',     '"07:00"','time',   'Overnight detection window end (device local)'),
 ('tracking.auto_confirm_confidence',  '0.75',  'decimal', 'Confidence at or above which events auto-confirm'),
 ('tracking.review_confidence_floor',  '0.45',  'decimal', 'Below this, candidates are discarded'),
 ('tracking.pause_auto_resume_min',    '60',    'int',     'Auto-resume a paused session after N minutes'),
 ('tracking.visit_auto_close_min',     '45',    'int',     'Auto-close an open visit after confirmed departure'),
 ('tracking.road_distance_factor',     '1.25',  'decimal', 'Straight-line to road distance factor for gap estimates'),
 ('tracking.prestart_window_min',      '60',    'int',     'Start tracking this long before shift start'),
 ('tracking.max_geofences_ios',        '20',    'int',     'iOS platform limit'),
 ('tracking.max_geofences_android',    '90',    'int',     'Android budget'),
 ('tracking.ping_interval_moving_s',   '30',    'int',     'Sampling interval while moving locally'),
 ('tracking.ping_interval_transit_s',  '90',    'int',     'Sampling interval in long-distance transit'),
 ('tracking.ping_interval_dwell_s',    '300',   'int',     'Sampling interval while dwelling'),
 ('tracking.accuracy_reject_m',        '100',   'int',     'Above this accuracy, a ping cannot drive a transition'),
 ('tracking.teleport_speed_kmph',      '900',   'int',     'Implied speed treated as a teleport anomaly'),
 ('sync.default_back_days',            '90',    'int',     'Default offline window, days back'),
 ('sync.default_forward_days',         '30',    'int',     'Default offline window, days forward'),
 ('expense.duplicate_window_days',     '2',     'int',     'Window for duplicate expense detection'),
 ('privacy.raw_ping_retention_days',   '365',   'int',     'Raw location retention before aggregation'),
 ('privacy.journey_retention_days',    '2555',  'int',     'Derived journey retention (7 years)')
ON CONFLICT DO NOTHING;

INSERT INTO config.feature_flag (code, enabled, description) VALUES
 ('ocr_on_device',        true,  'Run OCR with ML Kit on the device before upload'),
 ('route_optimisation',   false, 'Suggest an optimal visit order for a tour day'),
 ('voice_note_reports',   false, 'Allow voice notes on visit reports'),
 ('auto_mileage_expense', false, 'Pre-create mileage expenses from tracked distance'),
 ('offline_map_tiles',    false, 'Bundle offline map tiles for the territory')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------
INSERT INTO sync.sync_policy (role_code, entity, back_days, forward_days, attachments_mode, max_attachment_mb) VALUES
 (NULL, 'customer.customer_account', 36500, 36500, 'METADATA_ONLY', 10),
 (NULL, 'customer.customer_site',    36500, 36500, 'METADATA_ONLY', 10),
 (NULL, 'planning.tour',             90,    30,    'METADATA_ONLY', 10),
 (NULL, 'planning.visit_plan',       90,    30,    'METADATA_ONLY', 10),
 (NULL, 'visit.visit',               90,    0,     'WIFI_ONLY',     10),
 (NULL, 'visit.visit_report',        90,    0,     'WIFI_ONLY',     10),
 (NULL, 'expense.expense',           180,   0,     'WIFI_ONLY',     15),
 (NULL, 'tracking.journey_event',    30,    0,     'NEVER',         0)
ON CONFLICT DO NOTHING;

INSERT INTO sync.retention_rule (entity, keep_days, action) VALUES
 ('tracking.location_ping',      365,  'DETACH_PARTITION'),
 ('tracking.device_heartbeat',   90,   'PURGE'),
 ('tracking.geofence_event',     365,  'PURGE'),
 ('sync.client_mutation',        90,   'PURGE'),
 ('sync.sync_session',           30,   'PURGE'),
 ('integration.outbox_message',  180,  'ARCHIVE'),
 ('audit.audit_log',             2555, 'ARCHIVE')
ON CONFLICT (entity) DO NOTHING;

-- ---------------------------------------------------------------------
-- A minimal published visit-report template (dynamic extension section)
-- ---------------------------------------------------------------------
INSERT INTO visit.form_template (code, version, name, visit_type_code, status, effective_from, published_at, schema)
VALUES ('STD_SALES_CALL', 1, 'Standard sales call', 'SALES_CALL', 'PUBLISHED', CURRENT_DATE, now(),
'{
  "sections": [
    { "key": "stock", "title": "Stock check",
      "fields": [
        { "key": "stock_checked", "type": "bool",   "label": "Stock checked?", "required": true },
        { "key": "closing_qty",   "type": "number", "label": "Closing quantity", "min": 0,
          "visibleIf": { "field": "stock_checked", "eq": true } },
        { "key": "expiry_issue",  "type": "bool",   "label": "Near-expiry stock seen?",
          "visibleIf": { "field": "stock_checked", "eq": true } }
      ] },
    { "key": "market", "title": "Market feedback",
      "fields": [
        { "key": "competitor_scheme", "type": "text",   "label": "Competitor scheme seen", "maxLength": 500 },
        { "key": "price_feedback",    "type": "choice", "label": "Price feedback",
          "options": ["Competitive","Slightly high","Too high"] },
        { "key": "shelf_photo",       "type": "photo",  "label": "Shelf photo", "maxCount": 3 }
      ] }
  ]
}'::jsonb)
ON CONFLICT (code, version) DO NOTHING;
