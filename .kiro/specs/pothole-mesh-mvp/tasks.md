# Implementation Plan: Pothole Mesh MVP

## Overview

The plan is ordered so a judgeable demo exists as early as possible: backend fusion and tests first, then the iPhone app shell and live Map, then the in-app Demo simulator driving the full lifecycle end to end. Real sensing (Drive tab, motion, location, upload retry) and the on-device detectors come after the demo slice, followed by hardening and polish. Languages follow the design: Python 3.11+ (FastAPI, stdlib `sqlite3`) for `server/`, and Swift 5 mode / SwiftUI for `PotholeMesh/`.

Common verification commands:

- Backend tests (from `server/`): `python -m pytest -q`
- iOS build: `xcodebuild -project PotholeMesh/PotholeMesh.xcodeproj -scheme PotholeMesh -destination 'generic/platform=iOS Simulator' build`
- iOS unit tests: `xcodebuild -project PotholeMesh/PotholeMesh.xcodeproj -scheme PotholeMesh -destination 'platform=iOS Simulator,name=<available iPhone simulator>' -only-testing:PotholeMeshTests test` (pick a simulator from `xcrun simctl list devices available`)

## Tasks

- [x] 1. Backend: fusion engine, ingestion, REST API, and pytest suites
  - [x] 1.1 Implement the `server/` FastAPI + SQLite backend
    - Create `server/requirements.txt` listing exactly `fastapi`, `uvicorn`, `pytest`, `httpx`, each pinned with `==`; add `server/data/` and `*.db` to `.gitignore`
    - `app/config.py`: every tunable (cluster radius 12 m, six confidence weights, lifecycle thresholds 0.68 / 0.50 / 0.40 with P ≥ 3, N ≥ 3, N ≥ 6, severity window 20, dedupe window 2 s, future skew 300 s, GPS accuracy 30 m, clean-crossing distance 40 m, DB path, `DEMO_RESET_ENABLED`); DB path overridable for tests
    - `app/schemas.py`: pydantic `EvidenceIn` (field ranges, type-dependent required fields, timestamp skew check), `DefectOut` (exact 14 snake_case fields, ISO-8601 strings), `Transition`, `IngestResult`
    - `app/db.py`: `sqlite3` connection factory, schema + both indexes created on startup, repository functions (`insert_defect`, `insert_evidence`, `find_duplicate`, `list_active_defects`, `get_defect`, `defect_aggregates`, `update_defect`, `reset_all`); bound parameters only, no ORM
    - `app/fusion.py`: pure functions `haversine_m`, `find_cluster`, `compute_confidence`, `aggregate_severity` (per-device median then median, window 20 newest first), `next_state` (RESOLVED → LIKELY_REPAIRED → CONFIRMED precedence, confidence rounded to 6 decimals); weights read only from config
    - `app/ingest.py`: `ingest_evidence(conn, evidence, cfg)` under a process-level lock and one transaction: dedupe → (impact) cluster over non-resolved defects or create SUSPECTED / (clean crossing) 404 / 409 / 40 m 422 checks → insert (null impact fields for clean crossings, ignore client `road_defect_id` on impacts) → recompute O, P, C, N, centroid, first/last seen, confidence, severity → `next_state` → commit; return `IngestResult` with `transition` or null
    - `app/main.py`: `GET /health`, `POST /evidence`, `GET /defects` (non-resolved only), `GET /defects/{id}` (any state, 404 if missing), `POST /demo/reset` (4xx when disabled); map domain errors to 404 / 409 / 422 with no partial writes
    - _Requirements: 1.1–1.15, 2.1–2.3, 3.1–3.7, 4.1–4.6, 5.1–5.11, 6.1–6.5, 7.1–7.7, 8.1–8.8_

  - [x] 1.2 Write backend pytest suites (`tests/conftest.py`, `tests/test_fusion.py`, `tests/test_api_lifecycle.py`)
    - `conftest.py`: fresh temp SQLite file per test plus a `TestClient` fixture; no running server or network
    - `test_fusion.py` (pure functions, parametrized tables): haversine distances, clustering at/inside/outside 12 m, closed-form confidence values (P = 1 → 0.50, 2 → 0.625, 3 → 0.70, 11 → 23/26), confidence bounds and monotonicity over P/O/N/C grids, repeat discount, every `next_state` transition and retained state including the P = 11 / N = 21 → 0.40 boundary, severity aggregation and per-device single contribution
    - `test_api_lifecycle.py`: validation 422s, 404 / 409 / 40 m rejection with no stored rows, single-impact suspicion, clustering and centroid, three-device confirmation vs two-device non-confirmation, repeat-device discount, monotonicity, repair lifecycle, resolved-is-terminal, idempotent retry and dedupe, `is_simulated` equivalence, concurrent impacts producing one defect, reset enabled/disabled, and the full demo sequence as raw `POST /evidence` (P = 11; LIKELY_REPAIRED exactly at N = 14; RESOLVED exactly at N = 22; no state change at other N)
    - Parametrized pytest only, no Hypothesis; run `python -m pytest -q` from `server/` and fix until green
    - **Property 1: Single-impact suspicion**, **Property 2: Spatial clustering**, **Property 3: Independent confirmation**, **Property 4: Repeat discount**, **Property 5: Evidence monotonicity**, **Property 6: Repair lifecycle**, **Property 7: Resolved is terminal**, **Property 8: Idempotent retry**, **Property 9: Real/simulated path equivalence**, **Property 10: Severity robustness**, **Property 11: Confidence bounds**
    - **Validates: Requirements 1.1–1.15, 2.1–2.3, 3.1–3.7, 4.1–4.6, 5.1–5.10, 6.1–6.4, 7.1–7.6, 8.5, 21.1, 21.2, 21.4, 21.5, 22.1–22.4**

- [x] 2. Checkpoint - Backend complete
  - Ensure all tests pass, ask the user if questions arise.

- [x] 3. iPhone app shell, networking, and live Map tab
  - [x] 3.1 Configure the existing Xcode project and build the app foundation
    - Preserve `PotholeMesh.xcodeproj` (no recreation, no `pbxproj` file-reference edits, `IPHONEOS_DEPLOYMENT_TARGET = 26.2`, `SWIFT_VERSION = 5.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` unchanged); only add app-target build settings in Debug and Release: `INFOPLIST_KEY_NSMotionUsageDescription` and `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` (exact design strings) and `INFOPLIST_FILE = PotholeMesh-Info.plist`
    - Create partial plist `PotholeMesh/PotholeMesh-Info.plist` (outside the synchronized folder) with ATS `NSAllowsLocalNetworking = YES` (no `NSAllowsArbitraryLoads`) and a non-empty `NSLocalNetworkUsageDescription`
    - `Config/AppConfig.swift`: default base URL constant, `UserDefaults` override, 2 s poll interval, 5 s timeout
    - `Models/RoadDefect.swift`, `Models/Evidence.swift`, `Models/APIModels.swift`: `RoadDefect`, `DefectState` (display name, color, SF Symbol, severity band helper), `EvidencePayload`, `IngestResponse`, `Transition`; snake_case + ISO-8601 coding
    - `Services/DeviceIdentity.swift`: random UUID created once and stored in `UserDefaults`
    - `Services/APIClient.swift`: `APIClientProtocol` + URLSession implementation of `health()`, `postEvidence(_:)`, `defects()`, `defect(id:)`, `resetDemo()`, throwing only typed `APIError` (`unreachable`, `timeout`, `http(status)`, `decoding`); no force-unwraps
    - `Services/DefectStore.swift` (`@Observable`): single 2 s poll loop, publishes defects, last refresh time, and connection status; keeps last data on failure
    - `PotholeMeshApp.swift`: create shared services, inject via environment, start/stop polling on `scenePhase`; `ContentView.swift`: root `TabView` with exactly Map, Drive, Demo (Drive and Demo as placeholders for now)
    - _Requirements: 9.1–9.3, 10.1–10.11, 19.1, 19.2, 19.7, 20.1–20.6_

  - [x] 3.2 Implement the Map tab and defect detail sheet
    - `Map/MapTabView.swift`: `Map(position:selection:)` centered on the Demo_Coordinate, one `Annotation` per `DefectStore` defect using only backend values, `UserAnnotation()` when already authorized (never requests permission), connection pill only while unreachable
    - `Map/DefectMarker.swift`: SUSPECTED amber outlined `exclamationmark`, CONFIRMED solid red `exclamationmark.triangle.fill`, LIKELY_REPAIRED green/teal `wrench.and.screwdriver.fill`; three sizes by severity band; animated state change; fade-out when a defect drops from the poll
    - `Map/DefectDetailSheet.swift`: medium/large detents, state pill, confidence `Gauge` with %, severity score and band, P / O and N / C stats grid, relative first/last seen, two-segment O vs C bar; live-updates from `DefectStore` by id
    - Verify with the `xcodebuild … build` command from the Overview and fix all errors
    - _Requirements: 11.1–11.10_

- [x] 4. Demo simulator vertical slice (full lifecycle on the Map)
  - [x] 4.1 Implement `DemoSimulator`, `DemoEventLog`, and `DemoTabView`
    - `Demo/DemoSimulator.swift` (`@Observable`): local ground truth (`hasPothole`, `isRepaired`, Demo_Coordinate); one cancellable traffic `Task` with interval `10 s / rateFactor / speed` (Low 3, Medium 10, High 25; 1x/2x/5x), waiting before each trip; trip counter k (reset to 1), fresh UUID and `Vehicle NN` label per trip; deterministic golden-angle spiral position, `SCORES` table, peaks, speed, and accuracy from k; current-time timestamps; `is_simulated = true`; serialized awaits through `APIClientProtocol`
    - Phase logic: IMPACT per trip while pothole present and not repaired; capture `demoDefectId` from the first impact result; CLEAN_CROSSING per trip once repaired and id known; post nothing (still increment k) when repaired without an id or after RESOLVED is seen (transition or 409)
    - Error handling: log "Server unreachable, retrying" on network/timeout and keep looping; pause after 3 consecutive failures with a Resume control; log and drop 4xx without retry
    - Controls: RESET DEMO (pause, `POST /demo/reset`, k = 1, clear ground truth, id, and log), INJECT POTHOLE, START / PAUSE TRAFFIC, REPAIR POTHOLE, Traffic Rate and Simulation Speed segmented controls
    - `Demo/DemoEventLog.swift`: bounded last-50 human-readable entries derived from `IngestResult` (impact, clean crossing, created, confirmed, likely repaired, resolved)
    - `Demo/DemoTabView.swift`: status card (state pill matching marker color, confidence %, P and N, severity) updated from each ingest result with `GET /defects/{id}` fallback; on state change animate the pill, show a short banner, fire a haptic; server URL field persisted via `AppConfig` and a health row using `health()`
    - Replace the Demo placeholder in `ContentView`; verify with `xcodebuild … build`
    - _Requirements: 12.1–12.12, 13.1–13.11, 19.4, 22.1–22.5_

- [ ] 5. Checkpoint - Demo vertical slice complete
  - Ensure the backend tests pass and the iOS build succeeds, ask the user if questions arise. The user runs the scripted demo (Reset → Inject → Start Low @ 1x → Medium @ 1x → Repair at Medium @ 2x) on the iPhone against the Mac backend manually.

- [ ] 6. Real sensing services, evidence uploader, and Drive tab UI
  - [ ] 6.1 Implement sensor services, `EvidenceUploader`, `DriveSession`, and `DriveTabView`
    - `Config/DetectionConfig.swift`: single struct with every sensing constant from the design (sampling, window, thresholds, cooldown, capture, score bounds and weights, crossing radii, encounter timeout)
    - `Drive/MotionService.swift`: one `CMMotionManager`, device motion at 50 Hz on `OperationQueue.main`, delivers `MotionSample(t, accelMagnitudeG, rotationRateRadS)`; exposes availability; in-memory only
    - `Drive/LocationService.swift`: When-In-Use only, best-for-navigation accuracy, `.automotiveNavigation`, no background updates; updates only during a session; drops fixes with accuracy < 0 or > 20 m or older than 5 s; speed < 0 → unknown; keeps only the latest `LocationFix`; publishes authorization status
    - `Services/EvidenceUploader.swift` (`@Observable`): immediate post; in-memory FIFO retry queue (max 50, drop oldest) for unreachable / timeout / 5xx; backoff 2 → 4 → 8 → 16 → 30 s cap, reset on success; drop 4xx; publish `uploadedCount` and `pendingCount`
    - `Drive/DriveSession.swift` (`@Observable`): owns motion and location services, session start/stop, status (GPS good/poor/searching/denied, speed, duration, impacts, uploads), downsampled ~10 Hz magnitude buffer for the chart; gates evidence off while GPS is searching/poor or authorization is denied, resuming automatically
    - `Drive/DriveTabView.swift` + `Drive/AccelerationChart.swift`: START / STOP SENSING button, status rows, Swift Charts line, blocking-condition banners (motion unavailable, location denied with Settings deep link, poor GPS, too slow, server unreachable); Start disabled when motion is unavailable
    - Replace the Drive placeholder in `ContentView`; inject `EvidenceUploader` from `PotholeMeshApp`; verify with `xcodebuild … build`
    - _Requirements: 9.4–9.7, 14.1–14.6, 15.1, 15.2, 16.1–16.6, 18.1–18.6, 19.3, 19.5, 19.6_

- [ ] 7. On-device impact and clean-crossing detection with XCTests
  - [ ] 7.1 Implement `ImpactDetector` and `CleanCrossingTracker` and wire them into `DriveSession`
    - `Drive/ImpactDetector.swift`: pure value type `process(sample, context) -> ImpactEvent?`; computes m, r, jerk; rolling 2 s μ/σ with `sigmaFloorG`; candidate gate (fresh accurate fix, known speed ≥ 4 m/s, z ≥ 4, m ≥ 0.35 g, jerk ≥ 8 g/s, r ≤ 3 rad/s, cooldown 2 s) using the pre-event baseline; 0.25 s capture of peaks and duration above μ + 2σ; transparent integer score in [0, 100]; time injected, no system clock
    - `Drive/CleanCrossingTracker.swift`: pure value type with one Encounter per active defect (Armed → InEncounter at ≤ 12 m → Disarmed at > 20 m, emitting only if no impact, exit speed ≥ 4 m/s, and accuracy in (0, 20] m; Disarmed after 30 s without emit; re-Armed beyond 60 m); `noteImpact(at:time:)` sets `impactSeen` only for InEncounter defects within `exitRadiusM` (20 m) of the impact position
    - `DriveSession`: feed samples to the detector; on an event build one IMPACT payload from the gating fix with `is_simulated = false`, hand it to `EvidenceUploader`, increment the count, call `noteImpact(at:time:)`, fire a light haptic and counter animation; feed each accepted fix plus `DefectStore` defects to the tracker and upload one clean_crossing payload per emitted event
    - _Requirements: 14.7, 14.8, 15.3–15.6, 15.11, 17.1–17.7, 17.9_

  - [ ] 7.2 Write `ImpactDetectorTests` and `CleanCrossingTrackerTests` in `PotholeMeshTests`
    - Synthetic samples, fixes, and injected time only; no hardware, permissions, or network
    - Impact detector: flat 0.02 g noise never triggers (seeded deterministic noise); single 1.5 g spike after 2 s baseline at speed ≥ 4 m/s triggers once; spike with low/unknown speed, rotation > 3 rad/s, or inside cooldown does not trigger; score in [0, 100] and non-decreasing with amplitude
    - Clean-crossing tracker: straight pass emits exactly one; pass with impact within 20 m of the defect emits none; impact farther than 20 m does not suppress; lingering/oscillating within 60 m emits at most one; slow or unknown-speed exit emits none; > 30 s encounter emits none; re-arm beyond 60 m
    - Run the `xcodebuild … -only-testing:PotholeMeshTests test` command from the Overview and fix until green
    - **Property 12: iOS impact detector**, **Property 13: iOS clean-crossing tracker**
    - **Validates: Requirements 15.7–15.10, 17.2–17.6, 17.8, 21.3, 21.6**

- [ ] 8. Integration hardening, polish, and run instructions
  - [ ] 8.1 Harden error and permission paths, polish UI, and document running the demo
    - Audit for force-unwraps on external data and confirm every network call is `async` throwing only `APIError`; decoding errors are logged and leave published state unchanged
    - Confirm polling stops off-active and resumes on active; Map keeps last markers while unreachable; Drive banners re-evaluate on authorization changes; simulator pause/resume after repeated failures
    - Visual polish within the design: consistent state colors across marker, sheet, and Demo status card; transition animations; readable log; accessibility labels on markers, controls, and status rows
    - Update `README.md` with backend setup (`pip install -r requirements.txt`, `uvicorn app.main:app --host 0.0.0.0 --port 8000` from `server/`, `python -m pytest`), finding the Mac LAN IP and entering it in the Demo tab server URL field, the local-network prompt, and the Definition-of-Done demo script
    - Run backend tests, the iOS build, and the iOS unit tests; fix any failures
    - _Requirements: 10.9, 11.10, 13.7, 13.8, 14.4, 14.6, 19.1–19.7, 21.5, 21.6, 22.6, 22.7_

- [ ] 9. Final checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- No sub-tasks are marked optional. The backend pytest suites (1.2) and the iOS XCTests (7.2) are required, since the user asked for them explicitly.
- Tasks 1–4 form the judgeable demo slice and are complete before any real-sensor work (tasks 6–7).
- Real-device steps (installing on the iPhone, the Definition-of-Done demo script in Requirement 22.1–22.6, and a real drive or bump test for 22.7) are performed manually by the user. Automated tasks stop at `pytest` and `xcodebuild` build/test.
- Requirement 22.1–22.4 arithmetic is verified automatically by the backend demo-sequence test in 1.2.
- Property tests use parametrized pytest tables (backend) and deterministic synthetic XCTest inputs (iOS); no Hypothesis or third-party packages.
- Each task references requirement clauses for traceability; correctness properties are referenced by number from `design.md`.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2", "3.1"] },
    { "id": 2, "tasks": ["3.2"] },
    { "id": 3, "tasks": ["4.1"] },
    { "id": 4, "tasks": ["6.1"] },
    { "id": 5, "tasks": ["7.1"] },
    { "id": 6, "tasks": ["7.2"] },
    { "id": 7, "tasks": ["8.1"] }
  ]
}
```
