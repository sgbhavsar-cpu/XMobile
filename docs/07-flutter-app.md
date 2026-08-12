# 07 — Flutter app structure

## 1. Project layout (feature-first, layered inside each feature)

```
lib/
  main.dart
  app/
    app.dart                     MaterialApp, router, theme
    router.dart                  go_router routes + auth guard
    di.dart                      Riverpod providers root
  core/
    config/                      env, endpoints, feature flags
    error/                       failure types, error mapper
    network/                     dio client, auth interceptor, retry, connectivity
    db/                          Drift database, DAOs, migrations, encryption
    sync/                        sync engine (see §4)
    location/                    tracking service abstraction (see §3)
    permissions/                 permission + tracking-health diagnostics
    storage/                     secure storage, file cache, attachment store
    utils/                       uuid v7, geo math, date/tz helpers
  features/
    auth/          data/ domain/ presentation/
    home/                        today screen: tour, next visit, tracking state
    tours/                       tour list, tour detail, day plan editor
    visits/                      check-in/out, visit list, visit detail
    reports/                     dynamic form engine + core fields
    expenses/                    capture, share inbox, list, mileage
    customers/                   customer list, site detail, capture location
    journey/                     my day timeline, gaps, corrections
    conflicts/                   sync issues inbox
    settings/                    diagnostics, sync status, consent, about
  shared/
    widgets/                     buttons, offline banner, sync badge, map widget
    forms/                       dynamic form renderer (schema → widgets)
```

**State management:** Riverpod (code-generated providers). Repositories return
`Stream` from Drift so the UI is always reading local state — the network is never on the
UI path. This is what makes the app feel identical online and offline.

**Navigation:** go_router with guards for auth, consent, and mandatory-diagnostics states.

## 2. Key packages

| Concern | Package | Note |
|---|---|---|
| Local DB | `drift` + `sqlcipher_flutter_libs` | Typed SQL, streams, migrations, encrypted |
| DI/state | `flutter_riverpod`, `riverpod_generator` | |
| HTTP | `dio` + `dio_smart_retry` | Interceptors for auth, retry, logging |
| Auth | `flutter_appauth` + `flutter_secure_storage` | OIDC PKCE in the system browser |
| Background location | `flutter_background_geolocation` (commercial) **or** `background_locator_2` + `geolocator` | See §3 |
| Geofencing | Provided by the above, else `native_geofence` | |
| Activity recognition | Bundled with the tracking plugin, else `flutter_activity_recognition` | |
| Background work | `workmanager` (Android), `BGTaskScheduler` via platform channel (iOS) | Sync + upload |
| Share intent | `receive_sharing_intent` | UPI screenshots, ticket PDFs |
| OCR | `google_mlkit_text_recognition` | On-device, works offline |
| Maps | `flutter_map` + local tile server, or `google_maps_flutter` | On-prem may forbid Google tiles |
| Files/images | `image_picker`, `file_picker`, `flutter_image_compress`, `crypto` (sha256) | |
| Signature | `signature` | Customer sign-off |
| Push | `firebase_messaging` | Only external dependency |
| Connectivity | `connectivity_plus`, `internet_connection_checker` | |
| Device info | `device_info_plus`, `battery_plus`, `package_info_plus` | Health heartbeat |
| Permissions | `permission_handler` | |
| Logs | `logger` + rotating file sink, redacted | Support diagnostics |

### On the tracking plugin choice

`flutter_background_geolocation` (Transistorsoft) is a paid library, and for this
requirement it is worth the licence: it already solves motion-triggered sampling, stop
detection, geofencing with the iOS 20-region ceiling, headless Android restart, persistent
queue with HTTP retry, and OEM battery-killer workarounds. Rebuilding that on
`geolocator` + `background_locator_2` is realistic but costs months and will be less
reliable on Chinese OEM Android builds.

The design keeps a `LocationTrackingService` interface with two implementations so the
choice is reversible and testable:

```dart
abstract interface class LocationTrackingService {
  Future<void> start(TrackingConfig config);
  Future<void> stop();
  Future<void> setProfile(SamplingProfile profile);
  Future<void> syncGeofences(List<GeofenceSpec> fences);
  Stream<PingEvent> get pings;
  Stream<GeofenceTransition> get transitions;
  Stream<TrackingHealth> get health;
}
```

## 3. Background execution

### Android
- Foreground service with a persistent notification (`FOREGROUND_SERVICE_LOCATION`).
- `ACCESS_BACKGROUND_LOCATION` requested with a clear rationale screen — Play policy
  requires it, and reps refuse the permission if the reason is not explained.
- `RECEIVE_BOOT_COMPLETED` to restart tracking after reboot.
- Battery-optimisation exemption requested via `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`;
  for company-owned devices, set by MDM instead.
- OEM-specific guidance screen (Xiaomi/Oppo/Vivo/Realme autostart settings) triggered by
  manufacturer detection — this single screen prevents the most common "tracking stopped"
  support ticket.

### iOS
- `Always` location authorisation, `allowsBackgroundLocationUpdates = true`,
  `pausesLocationUpdatesAutomatically = false`.
- Region monitoring (≤ 20 regions, dynamically managed), significant-location-change, and
  `CLVisit` monitoring — all of which relaunch a terminated app.
- `BGProcessingTask` for sync and uploads; opportunistic, never assumed.
- Background modes: `location`, `fetch`, `processing`, `remote-notification`.

### Tracking health screen
A first-class feature, not a debug page: shows permission level, battery optimisation,
power-saving state, last successful upload, queued items, and a plain-language fix for each
problem. The rep sees the same score the manager sees, which turns an accusation into a checklist.

## 4. Sync engine

```
UI action → Repository (Drift tx: write row + write outbox row)
                     ↓
              SyncScheduler  (triggers: foreground, connectivity, timer, WorkManager, push hint)
                     ↓
   ┌─────────────────┴─────────────────┐
   │ PushWorker        PullWorker      │
   │ drains outbox     cursor delta    │
   │ batch ≤ 100       page ≤ 500      │
   └─────────────────┬─────────────────┘
                     ↓
        ConflictHandler → conflicts inbox (user-visible)
                     ↓
        AttachmentUploader (separate queue, policy-gated)
```

Ordering rule inside the push worker: dependency-sorted (tour → plan → visit → report →
attachment link), so the server rarely has to return `DEFERRED`.

Idempotency: `clientMutationId` is generated once when the outbox row is written and never
regenerated on retry. This is the single most important detail in the whole engine — a
regenerated ID on retry creates duplicate expenses.

## 5. Local database

Drift schema mirrors the server subset plus `_outbox`, `_sync_state`, `_conflicts`,
`_ping_queue`, `_attachment_queue`. Encrypted with SQLCipher; the key lives in
Keystore/Keychain and is never written to preferences.

Migration strategy: numbered Drift migrations; a failed migration falls back to
"purge and re-bootstrap" only when the outbox is empty — never discard unsent work.

## 6. Share-intent ingestion (UPI screenshots, ticket PDFs)

The flow you asked for, in detail:

1. Rep pays by UPI → taps **Share** on the payment screenshot → picks XMobile.
   (Android: `ACTION_SEND` intent filter for `image/*`, `application/pdf`, `text/plain`.
   iOS: a Share Extension writing to the App Group container.)
2. `receive_sharing_intent` delivers the file (cold start or warm) → the file is copied into
   app-private storage, sha256 computed, an `attachment` row created with
   `capture_source = SHARE_INTENT` and `source_app` recorded.
3. **On-device OCR** (`google_mlkit_text_recognition`) runs immediately — offline, no server
   round trip. A rules layer extracts amount, date, merchant, UPI reference, and classifies
   the document (UPI screenshot vs invoice vs ticket). PDFs are rendered to an image first.
4. A **share inbox** entry appears with a notification: "₹2,450 to IRCTC on 10 Aug — add as
   expense?" One tap opens a pre-filled expense form; the rep picks a category and saves.
5. Everything above works with no network. Upload and push happen later.

Design notes that matter in practice:
- Never auto-create the expense without confirmation — OCR misreads amounts, and a
  silently-wrong expense is worse than a missing one.
- Keep the raw file forever (it is the receipt), not just the extracted fields.
- The inbox prevents loss: a share received while the app is busy is queued, not dropped.
- Dedupe by sha256 — reps re-share the same screenshot surprisingly often.

## 7. Dynamic form engine

`schema (jsonb) → widgets`, supporting: `text`, `number`, `bool`, `choice`, `multichoice`,
`date`, `photo`, `signature`, `rating`, `section`, with `required`, `min`/`max`,
`maxLength`, `regex`, and `visibleIf` conditional display.

- The template version used is pinned into the report at first save, so a mid-day template
  publish cannot change a form the rep is filling.
- Validation runs locally; the server re-validates against the same pinned version.
- Unknown field types render as read-only text rather than crashing — forward compatibility
  for an app that is behind the server.

## 8. Offline UX rules

1. Every screen renders from the local DB; there is no "loading from server" spinner on the
   critical path.
2. A persistent, unobtrusive banner shows offline state and pending-sync count.
3. Any row with unsynced changes carries a small pending indicator.
4. Actions that genuinely require network (first login, attachment download not cached)
   say so explicitly rather than failing silently.
5. The "Sync issues" inbox is reachable in two taps from home.

## 9. Testing

- Unit: repositories, sync engine, form validation, OCR field extraction, geo maths.
- Widget: check-in flow, expense capture from share intent, dynamic form rendering.
- Integration: full offline day — 6 visits, 4 expenses, no network, then sync; asserted
  against a real backend in Docker.
- Trace replay: recorded device traces (see [03 §10](03-tracking-and-journey.md#10-test-strategy-for-the-engine))
  played through the client-side collection policy to assert battery-relevant behaviour
  (sampling profile transitions) without a device.
