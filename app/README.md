# XMobile — Flutter app

The field app. Runs by default against an **in-memory backend** (`MockApiClient`), so every
screen and form can be used and tested regardless of backend progress. A real
`HttpApiClient` (`lib/core/api/http_api_client.dart`) now exists and talks to the ASP.NET Core
backend in `src/XMobile.Api` — see "What is real and what is stubbed" below for exactly how much
of it that covers today. It isn't the default provider yet; swap it in per the override below.

```bash
cd app
flutter pub get
flutter run          # any employee code + a 4-character password signs you in
flutter test         # 74 tests, no device or emulator needed
flutter analyze
```

## How it talks to the backend

```
screens ─► repositories/providers ─► ApiClient (interface) ─► MockApiClient (default, in memory)
                                                           └► HttpApiClient (real backend, built but opt-in)
```

`ApiClient` (`lib/core/api/api_client.dart`) mirrors `api/openapi.yaml` closely — `HttpApiClient`
also calls a couple of endpoints not yet in that spec (`PUT /v1/auth/home`,
`GET /v1/plans/{id}`; see `docs/10-roadmap.md §6`) where the interface needed one to exist at
all. Connecting to the real service is an override of **one provider**, and `main.dart` already
wires it up behind a build-time flag so no code change is needed to try it:

```bash
flutter run --dart-define=XMOBILE_API_BASE_URL=https://xmobile.internal/api
```

Leave the flag unset and the app runs against `MockApiClient`, same as `flutter run` alone. The
override itself (`lib/main.dart`) is nothing more than:

```dart
apiClientProvider.overrideWithValue(HttpApiClient(baseUrl: _apiBaseUrl))
```

No screen, form or repository changes — though a good number of `ApiClient`'s methods
(opportunities, expenses, most reference-data lookups, device tracking-health) have no backend yet and
`HttpApiClient` throws a catchable `ApiException` for those rather than pretending to work; a
screen exercising one of them will show an error instead of the mock's data until its module is
built server-side. The mock deliberately models two things a naive stub would not, because both
change how the UI must behave:

- **latency** — every call takes a beat, so loading states are real and get exercised;
- **connectivity** — `offline` makes calls throw `OfflineException`, which is how the outbox,
  pending badges and sync screen are tested without a network to unplug.

## What is real and what is stubbed

| Area | Today | When plugins land |
|---|---|---|
| Every screen, form, validation rule | **Real** | unchanged |
| Offline queueing, conflict surfacing | **Real** | swap the transport |
| Dynamic report forms (schema → widgets) | **Real** | unchanged |
| Location capture | **Manual entry** (pick a place, or type coordinates) | GPS plugin fills it in; manual entry stays as the fallback |
| Share-intent receipts | Simulate buttons in the share inbox | `receive_sharing_intent` + iOS share extension |
| OCR on receipts | Plausible fake extraction | `google_mlkit_text_recognition` on device |
| Permission toggles on tracking health | Switches that drive the same scoring | real permission dialogs |

The manual paths are not throwaway scaffolding. A rep whose GPS will not fix still has to be
able to record where they were, so **manual location entry ships**; the plugin only removes
the typing in the common case.

## Layout

```
lib/
  app/            router, shell, theme
  core/
    api/          ApiClient contract, MockApiClient, HttpApiClient, TokenStore, seed data
    db/           Drift database (local persistence — outbox table so far)
    models/       domain models + enums mirroring the API
    state/        Riverpod providers, offline outbox (now Drift-backed)
    ui/           form fields, status chips, async/error/empty states
  features/
    auth/ home/ tours/ visits/ customers/ opportunities/
    expenses/ journey/ settings/ sync/ more/ developer/
test/
  flows_test.dart              39 end-to-end rules against the in-memory backend
  widget_test.dart             13 tests rendering real screens and driving forms
  http_api_client_test.dart    17 tests against a fake http.Client (token/device-id persistence,
                                journey/tracking mapping)
  outbox_repository_test.dart  5 tests against a real (in-memory) Drift database
```

## Try these

The seed data opens onto a Pune territory with a Nagpur tour already in progress.

1. **Today → Check in** on a planned visit. Change the location to somewhere far away and
   watch the out-of-geofence reason appear — allowed, but it must be explained.
2. **Check out → write the report.** The dynamic section under "Standard sales call" comes
   from a template, not from app code. Submit it, then try to edit it.
3. **Expenses → shared receipts → "UPI screenshot".** It arrives read, with a suggested
   category. One tap turns it into a pre-filled expense that you still have to confirm.
4. **More → Developer → No connection.** Now check in, or add an expense. Nothing fails;
   work queues, the banner appears, and **More → Sync** shows what is still on the device.
5. **More → Developer → XInfo unreachable.** Submit an expense: a different failure, a
   different message, and the expense survives for retry.
6. **More → Tracking health.** The seed device is deliberately misconfigured. Fix an item and
   watch the score move — this is the screen that carries the whole no-MDM story.
7. **Customers → New prospect.** Capture one and visit it immediately, before XInfo has
   approved it.
