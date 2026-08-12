# 06 — Security, identity & privacy

## 1. Identity

Decision: **Keycloak deployed on-premise with the application**. There is no existing IdP to
integrate with, so Keycloak is the identity provider, with LDAP federation available later if
an AD appears. Deploying our own is an advantage here rather than a compromise: we control
refresh-token lifetime, which is exactly what field devices need (see below), and a
third-party IdP with a 24-hour refresh window would lock reps out on the second day of a tour.

```
Flutter app ──(AppAuth, PKCE, system browser)──► Keycloak ──(LDAP federation)──► AD
      │                                              │
      │◄──── id_token + access_token + refresh_token ┘
      │
      └──► XMobile API   (Bearer access_token, validated against Keycloak JWKS)
```

- **PKCE authorization code flow** in the system browser (never an embedded webview —
  it breaks SSO and is a phishing surface).
- Access token TTL 15 min; refresh token TTL 30 days, **device-bound** (`device_id` claim
  checked against the registered device) and rotating.
- Offline reality: field devices go days without network. The app keeps working on a valid
  refresh token; if the refresh token also expires while offline, the app remains **readable
  and writable locally** but sync is blocked until re-authentication, and it says so plainly.
  Local data is never wiped on token expiry.
- Biometric/PIN unlock for app entry, backed by the OS keystore. This is app-level, separate
  from the OIDC session.
- Device registration: first login binds a `device` row. A second device is allowed by
  default (configurable); a device can be remotely revoked by an admin, which invalidates its
  refresh tokens and (on next contact) wipes the local database.

**User provisioning.** Users come from AD/LDAP; the reporting hierarchy and territory come
from XInfo, matched on `employee_code`. A user present in AD but absent from XInfo can log in
but has no assigned customers — the app shows an explicit "your profile is not yet set up in
XInfo" state rather than an empty screen.

## 2. Authorisation

RBAC with data scoping.

| Role | Scope |
|---|---|
| `SALES_REP` | Own tours, visits, reports, expenses; assigned customers |
| `MANAGER` | Own + all reports of subordinates (recursive down the org tree) |
| `ADMIN` | Configuration, form templates, geofence tuning, device revocation |
| `INTEGRATION` | Service account for XInfo callbacks only |
| `AUDITOR` | Read-only across all data, including audit log |

Enforced in two layers: an authorisation policy per endpoint, **and** a scope predicate
applied in the repository layer (`WHERE user_id IN (subtree)`). The second layer exists
because endpoint-level checks are one refactor away from being bypassed.

Org-tree descent uses a materialised path on `org_unit` plus a `user_hierarchy_closure`
table refreshed on hierarchy sync — recursive CTEs per request are avoidable cost on the
dashboards.

## 3. Location privacy

Location tracking of employees is legally sensitive in many jurisdictions (India's DPDP Act,
GDPR where applicable, and various local labour rules). The design takes a defensible position:

1. **Consent record.** `identity.consent_record` stores the policy version accepted, when,
   from which device and IP. A policy change requires re-consent. A rep who declines cannot
   use the tracking features and this is recorded — it is a management issue, not a technical one.
2. **Purpose limitation.** Tracking is active only per the hybrid window (scheduled duty
   hours and active tours). Outside that window, no location is collected at all — not
   collected-and-hidden, *not collected*.
3. **Visible state.** A persistent notification (Android, mandatory for a foreground service)
   and an in-app always-visible indicator show whether tracking is on. The rep can see their
   own full trail.
4. **Pause right.** The rep can pause with a reason (logged). The system never blocks it.
5. **Minimisation & retention.** Raw pings: 12 months hot, then aggregated to segments and
   the raw partition detached/purged. Derived journey events/segments: 7 years (they back
   expense claims). Configurable per deployment.
6. **Access limits.** Raw trails are visible to the rep, their line manager, and auditors.
   Not to peers. Every raw-trail view by a manager writes an audit row — auditing the
   watchers is what makes surveillance accountable.
7. **Off-duty leakage.** If a ping arrives outside the tracking window (a race at
   shift end, or a stale queued item), it is stored with `is_off_window = true` and excluded
   from all reporting views by default.

## 4. Data protection

| Layer | Control |
|---|---|
| In transit | TLS 1.2+; optional mTLS for device→API in high-security installs; certificate pinning in the Flutter app with a backup pin |
| At rest (server) | PostgreSQL TDE or encrypted volumes; MinIO server-side encryption |
| At rest (device) | SQLCipher-encrypted Drift DB; attachments in app-private storage; keys in Keystore/Keychain (StrongBox/Secure Enclave when available) |
| Secrets | Environment-injected, never in the repo; rotation documented |
| PII in logs | Structured logging with a redaction processor; coordinates, phone numbers, and tokens never logged at INFO |
| Attachments | Virus scan (ClamAV sidecar) before OCR; MIME sniffing, not extension trust; size cap |
| Backups | Encrypted, restore-tested quarterly |

## 5. Application security

- Input validation with FluentValidation at the API boundary; parameterised SQL only
  (EF Core + Dapper for hot paths, no string concatenation).
- Rate limiting per device on ingest and auth endpoints.
- Attachment uploads only via presigned URLs scoped to a single object key — the app never
  gets broad MinIO credentials.
- Row-level scoping tests in CI: a rep must never be able to read another rep's rows;
  this is asserted as an explicit test suite, not assumed.
- Dependency scanning and container image scanning in the pipeline.
- OWASP MASVS-aligned mobile hardening: root/jailbreak detection (report, don't block),
  screenshot suppression on expense/receipt screens (configurable), no sensitive data in
  clipboard, no logs to shared storage.

## 6. Anti-fraud posture

Everything in [03 §6](03-tracking-and-journey.md#6-anti-tamper) raises **flags, not blocks**.
Blocking a rep in the field on a false positive costs a day's selling; flagging costs a
conversation. Flags carry severity and are aggregated into a per-rep integrity view over
time — a pattern of anomalies is meaningful in a way that a single anomaly is not.

## 7. Push notifications

**Confirmed available:** outbound access to FCM/APNs is permitted, so push is enabled.
Payloads remain notification-only (a type and an id) — no customer names, amounts or
locations cross Google's or Apple's infrastructure.

Push still cannot be *depended* on. Delivery is best-effort on both platforms, so every
notification has a corresponding pull path; the notification only makes it timely. If the
deployment ever forbids outbound internet:

- notifications degrade to in-app polling on foreground;
- nothing functional depends on push — it only accelerates plan changes, sync hints and
  reminders. A self-hosted alternative (UnifiedPush/ntfy) can be substituted on Android;
  iOS has no such option, and the design accepts that.

Push payloads are **notification-only** — no business data, just a type and an ID that the
app fetches over the authenticated channel.

## 8. Audit

`audit.audit_log` records actor, entity, action, before/after JSON, timestamp, device, IP.
Written for: master data change, visit lifecycle, report submission/amendment, expense
lifecycle, journey event override, geofence/config change, permission change, device
revocation, raw-trail viewing, data export. Append-only (revoked UPDATE/DELETE grants on the
table for the application role), retained 7 years.
