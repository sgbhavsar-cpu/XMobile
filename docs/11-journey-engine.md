# 11 — Journey engine (built)

`src/Modules/XMobile.Tracking.Engine` — the inference core specified in
[03 — Tracking](03-tracking-and-journey.md), implemented and tested.

```
dotnet test          # 53 tests, ~200 ms, no database, no network, no device
```

## 1. Shape

```csharp
public interface IJourneyEngine
{
    JourneyResult Infer(JourneyInput input);
}
```

Pure by construction: no I/O, no clock, no randomness, and **no package references at all**.
Everything the engine may consider arrives in `JourneyInput`; everything it concludes leaves in
`JourneyResult`. Adding a dependency to that `.csproj` should be treated as a design change,
because three properties depend on this purity:

1. **Replayable** — recorded traces run in CI with no phone and no server.
2. **Re-runnable** — late-arriving offline evidence is handled by re-inferring the window, not
   by patching stored rows.
3. **Explainable** — a disputed journey can be reproduced months later from the evidence plus
   the config snapshot in `tracking.inference_run`.

| Piece | Responsibility |
|---|---|
| `PresenceResolver` | Fixes → presence runs, with flicker absorption and planned-site tie-breaking |
| `JourneyEngine` | Candidate generation, anchors, state machine, segment building |
| `ReturnLegScorer` | The four-signal homeward-leg score |
| `TravelModeClassifier` | Walk / two-wheeler / car / rail / air from speed, straightness, activity |
| `AnomalyDetector` | Gap classification, mock location, teleport, clock skew, long pauses |
| `GeoMath` | Haversine, bearing, jitter-filtered path length, Douglas-Peucker simplification |

The imperative shell (not yet built) loads evidence for a window, calls `Infer`, then diffs
against stored derived rows: new rows inserted, stale `AUTO` rows superseded, anchors untouched.

## 2. What the test suite is for

Each test encodes a way the system could quietly produce wrong data:

| Test group | Guards against |
|---|---|
| `SingleDayTests` | Departure timed from the first fix *outside* the fence (a systematic overstatement in every travel report); stationary phones accumulating fictional kilometres; geocoded sites auto-confirming visits |
| `MultiDayTourTests` | The four-day Pune→Nagpur tour: travel spanning midnight as one segment, hotel nights, a pure-travel day with zero visits not reading as non-compliance, rail km not billed as car km |
| `PlatformRealityTests` | iOS suppressing fixes at departure and at arrival; overlapping geofences in a dense market; imprecise fixes triggering transitions; gap causes; declared pauses |
| `IntegrityTests` | Mock locations manufacturing visits; real flights flagged as fraud; and that no anomaly ever deletes the journey |
| `ReturnLegAndCorrectionTests` | Inter-customer travel misread as heading home; provisional returns not withdrawn; manual corrections being overwritten by a rebuild |
| `DeterminismTests` | Non-determinism, order-dependence, and "no data" being indistinguishable from "quiet day" |

## 3. Defects the tests caught during construction

Recorded because they are all cases where the engine looked correct and produced wrong data:

1. **Overnight stops were undetectable on a real tour.** Detection tested whole transit runs for
   stationarity, but a hotel night sits *inside* a transit run — travel, stop, travel — whose
   spread is the width of the country. Now it searches for stationary clusters within runs.

2. **A return leg starting from a hotel was never detected.** The homeward-leg test only ran on
   leaving a customer. On a multi-day tour the return usually begins by checking out of a hotel,
   so the test now also runs after an overnight stop ends.

3. **Every ordinary pause was reported as an unexplained gap.** The check asked whether a pause
   covered the gap's *first instant*, but reps tap pause a few minutes after the last fix and
   resume before the next. Now it measures overlap (≥ 80 %). This one mattered most: it would
   have put reps in front of managers for something they did correctly.

4. **A slow overnight train classified as a car.** 620 km in 11 hours averages 56 km/h, under the
   rail speed threshold — and real Indian overnight trains sit exactly there. Speed alone cannot
   separate them, so long-distance legs now use straightness: road routes run 1.2–1.3× the
   straight-line distance, so a near-straight track over hundreds of kilometres is a railway.

5. **A return leg was left provisional after the rep got home.** Arriving home is proof the leg
   was homeward; it now promotes the provisional event instead of leaving a permanent
   "needs review" on a completed journey.

## 4. Known limits

Stated plainly, because each is a place where output should be treated as a well-founded guess:

- **Car versus bus is not attempted.** They are indistinguishable from phone sensors without
  route data. The engine returns `Car` and the rep can override.
- **Rail versus car over long distances relies on straightness** (§3.4). It is a good signal, not
  a certain one, and mileage claims depend on it — hence moderate confidence and rep override.
- **Back-estimated departures assume 45 km/h door to door.** Flagged `IsEstimated`, never
  presented as observed.
- **Gap-spanning distance uses a 1.25 road factor** on the straight line. Marked estimated so it
  is never silently reimbursed.
- **Site matching prefers planned sites** on overlap. Correct in the common case; an unplanned
  visit to a neighbour of a planned site can be misattributed, which is why check-in is
  confidence 1.0 and always wins.
- **The engine does not know about visits.** It infers presence; linking to a `visit` row is the
  shell's job. A rep who checks in provides an anchor that overrides everything here.

## 5. Tuning

Every threshold lives in `EngineConfig`, loaded from `config.app_setting` and snapshotted per
run. Nothing is hardcoded at a call site, so field tuning is a settings change and old journeys
stay explicable under the thresholds that were actually in force.
