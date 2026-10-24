# Requirements Document

## Introduction

Pothole Mesh is a hackathon MVP that turns iPhones into a distributed road-condition sensor network. A native SwiftUI iPhone App (tabs: Map, Drive, Demo) reports compact IMPACT and CLEAN_CROSSING Evidence to a local FastAPI + SQLite Backend. The Backend clusters Evidence into RoadDefects, scores confidence while rewarding independent devices, aggregates severity, and moves each RoadDefect through the lifecycle SUSPECTED → CONFIRMED → LIKELY_REPAIRED → RESOLVED. The Demo tab runs a deterministic traffic simulator that posts through the same `POST /evidence` path as real phones.

These requirements are derived strictly from the approved design (`design.md`). All default values below match the design. Tunables live in one place on each side: `server/app/config.py` (Backend_Config) and `AppConfig` / `DetectionConfig` (App).

### Out of Scope

Android; web client; PWA; user accounts; authentication; social features; gamification; camera detection; computer vision; LLMs; generative AI; neural or ML classifiers; Boston 311 integration; automatic government reporting; OpenStreetMap or road-network map matching; route planning; avoid-pothole navigation; background GPS; background motion sensing; Apple Watch; CarPlay; notifications; PostGIS; WebSockets; microservices, Kafka, Redis, Kubernetes, Firebase, Supabase; complex cloud deployment; municipal admin portal; device reputation system; reopening resolved defects; defect expiry; production-scale security architecture. Backend endpoints are limited to the five listed in Requirement 7.

## Glossary

- **Backend**: The FastAPI application in `server/` backed by one SQLite file.
- **Backend_Config**: The module `server/app/config.py` holding every Backend tunable.
- **Ingestion_Service**: The `ingest_evidence()` function used for all Evidence, real and simulated.
- **Fusion_Engine**: The pure, deterministic functions in `app/fusion.py` (`haversine_m`, `find_cluster`, `compute_confidence`, `aggregate_severity`, `next_state`).
- **RoadDefect**: A canonical defect entity with position, state, confidence, severity, counts, and timestamps.
- **Active_Defect**: A RoadDefect whose state is not RESOLVED.
- **Evidence**: One reported observation, of type IMPACT or CLEAN_CROSSING.
- **IMPACT**: Evidence (`type = impact`) that a device felt an unusual jolt at a position.
- **CLEAN_CROSSING**: Evidence (`type = clean_crossing`) that a device passed a known RoadDefect without an impact.
- **Device_ID**: A random per-install UUID (or per-Trip UUID in the simulator); the only identity in the system.
- **P / O**: Unique devices with IMPACT Evidence on a RoadDefect / total IMPACT Evidence count.
- **N / C**: Unique devices with CLEAN_CROSSING Evidence on a RoadDefect / total CLEAN_CROSSING Evidence count.
- **Confidence**: `alpha / (alpha + beta)` per Requirement 4.
- **Severity**: Robust aggregate of `impact_score` in [0, 100] per Requirement 6.
- **Severity_Band**: low (< 40), moderate (40 to < 70), high (≥ 70).
- **IngestResult**: Response of `POST /evidence` with `evidence_id`, `duplicate`, `created`, `transition`, `defect`.
- **App**: The native SwiftUI iPhone app in `PotholeMesh/`.
- **AppConfig**: App struct holding API base URL, poll interval, and request timeout.
- **DetectionConfig**: App struct holding every sensing constant.
- **APIClient**: Protocol-backed async URLSession wrapper for the Backend API.
- **DefectStore**: Observable App store that polls `GET /defects`.
- **EvidenceUploader**: App service that uploads real Evidence and owns the in-memory retry queue.
- **Map_Tab**: The App tab showing RoadDefects on a MapKit map, including the DefectDetailSheet.
- **Drive_Tab**: The App tab for real on-device sensing, orchestrated by DriveSession.
- **DriveSession**: Orchestrator of one sensing session (MotionService, LocationService, ImpactDetector, CleanCrossingTracker).
- **MotionService**: Owner of the single `CMMotionManager`.
- **LocationService**: When-In-Use `CLLocationManager` wrapper publishing the latest fix.
- **ImpactDetector**: Pure value type that turns motion samples into impact events.
- **CleanCrossingTracker**: Pure value type that turns location fixes plus Active_Defects into clean-crossing events.
- **Encounter**: The per-RoadDefect tracking state (Armed, InEncounter, Disarmed) inside CleanCrossingTracker.
- **Demo_Tab**: The App tab hosting the DemoSimulator controls, status card, and event log.
- **DemoSimulator**: In-app virtual traffic generator posting simulated Evidence via APIClient.
- **Trip**: One virtual vehicle pass in the DemoSimulator, numbered by sequence k (1, 2, 3, …).
- **Demo_Coordinate**: Latitude 42.35500, longitude −71.06500 (Boston).

## Requirements

### Requirement 1: Evidence Ingestion and Validation

**User Story:** As a phone or simulator client, I want to submit IMPACT and CLEAN_CROSSING Evidence to one endpoint, so that all observations flow through the same fusion pipeline.

#### Acceptance Criteria

1. WHEN Evidence that passes every check in criteria 3–13 is received at `POST /evidence`, THE Ingestion_Service SHALL store exactly one Evidence record and return HTTP 200 with an IngestResult.
2. THE Ingestion_Service SHALL apply the same validation, clustering, confidence, and lifecycle rules to Evidence with `is_simulated = true` and `is_simulated = false`, so that two payloads differing only in `is_simulated` produce the same IngestResult and the same RoadDefect state, and SHALL store the `is_simulated` value unchanged with the Evidence.
3. IF `device_id` is absent, empty (0 characters), or longer than 64 characters, THEN THE Backend SHALL reject the Evidence with HTTP 422.
4. IF `type` is absent or is any value other than `impact` or `clean_crossing`, THEN THE Backend SHALL reject the Evidence with HTTP 422.
5. IF `latitude` is absent or outside the inclusive range [−90, 90], or `longitude` is absent or outside the inclusive range [−180, 180], THEN THE Backend SHALL reject the Evidence with HTTP 422.
6. IF `timestamp` is absent, is not a valid ISO-8601 date-time, or is more than 300 s later than the Backend's time of receipt, THEN THE Backend SHALL reject the Evidence with HTTP 422.
7. IF `speed_mps` is present and less than 0, or `gps_accuracy_m` is present and ≤ 0 or > 30, THEN THE Backend SHALL reject the Evidence with HTTP 422.
8. IF IMPACT Evidence has `impact_score` absent or outside the inclusive range [0, 100], or has any of `peak_acceleration`, `peak_jerk`, or `rotation_rate` present with a value less than 0, THEN THE Backend SHALL reject the Evidence with HTTP 422.
9. WHEN IMPACT Evidence that includes a `road_defect_id` is accepted, THE Ingestion_Service SHALL disregard the supplied `road_defect_id` and attach the Evidence to the RoadDefect selected by spatial clustering.
10. IF CLEAN_CROSSING Evidence has `road_defect_id` absent, THEN THE Backend SHALL reject the Evidence with HTTP 422.
11. IF otherwise valid CLEAN_CROSSING Evidence has a `road_defect_id` that matches no stored RoadDefect, THEN THE Backend SHALL reject the Evidence with HTTP 404.
12. IF otherwise valid CLEAN_CROSSING Evidence references an existing RoadDefect whose state is RESOLVED, THEN THE Backend SHALL reject the Evidence with HTTP 409.
13. IF otherwise valid CLEAN_CROSSING Evidence references an existing non-RESOLVED RoadDefect and the great-circle distance from the reported `latitude`/`longitude` to that RoadDefect's position is greater than 40 m, THEN THE Backend SHALL reject the Evidence with HTTP 422.
14. WHEN CLEAN_CROSSING Evidence is accepted, THE Ingestion_Service SHALL attach the Evidence to the RoadDefect identified by `road_defect_id` and store `impact_score`, `peak_acceleration`, `peak_jerk`, and `rotation_rate` as null regardless of any supplied values.
15. IF the Backend rejects Evidence with HTTP 404, 409, or 422, THEN THE Backend SHALL store no Evidence record and SHALL leave every RoadDefect unchanged.

### Requirement 2: Duplicate Evidence Handling

**User Story:** As a client that retries uploads, I want duplicate submissions to be idempotent, so that retries do not inflate evidence counts.

#### Acceptance Criteria

1. WHEN Evidence that passes all Requirement 1 validation arrives and a stored Evidence row has the same `device_id`, the same `type`, a `timestamp` differing by at most 2 s in either direction, and the same target (for CLEAN_CROSSING: the same `road_defect_id`; for IMPACT: a Haversine distance of at most 12 m from the incoming position), THE Ingestion_Service SHALL classify the incoming Evidence as a duplicate.
2. WHEN Evidence is classified as a duplicate, THE Ingestion_Service SHALL insert no Evidence row and return HTTP 200 with an IngestResult whose `duplicate` is `true` and whose `defect` is the matched row's RoadDefect, with every field equal to its value before the request.
3. FOR ALL valid Evidence payloads accepted with HTTP 200, WHEN the identical payload is posted a second time, THE Ingestion_Service SHALL leave the RoadDefect's O, P, C, N, Confidence, Severity, and state equal to their values after the first post.

### Requirement 3: Spatial Clustering and Aggregates

**User Story:** As the Backend, I want to group nearby impacts into one RoadDefect, so that many observations of one pothole become one canonical entity.

#### Acceptance Criteria

1. WHEN IMPACT Evidence passes validation (Requirement 1) and is not classified as a duplicate (Requirement 2), THE Fusion_Engine SHALL compute the Haversine distance in meters from the impact position to every Active_Defect and select the Active_Defect with the smallest distance.
2. WHEN the selected nearest Active_Defect is at a distance ≤ 12 m, THE Ingestion_Service SHALL attach the IMPACT Evidence to that Active_Defect and return `created = false` in the IngestResult.
3. WHEN no Active_Defect exists or the nearest Active_Defect is at a distance > 12 m, THE Ingestion_Service SHALL create a new RoadDefect in state SUSPECTED at the impact latitude and longitude with P = O = 1 and N = C = 0, attach the IMPACT Evidence to it, and return `created = true` in the IngestResult.
4. IF every RoadDefect at a distance ≤ 12 m from an IMPACT is RESOLVED, THEN THE Ingestion_Service SHALL leave those RESOLVED RoadDefects unchanged and create a new SUSPECTED RoadDefect for the IMPACT per criterion 3.
5. WHEN IMPACT Evidence is attached to a RoadDefect, THE Ingestion_Service SHALL set the RoadDefect latitude and longitude to the arithmetic mean latitude and arithmetic mean longitude of all IMPACT Evidence on that RoadDefect, including the newly attached IMPACT, before the IngestResult is returned.
6. WHEN non-duplicate Evidence is inserted, THE Ingestion_Service SHALL recompute O and C as `COUNT(*)` and P and N as `COUNT(DISTINCT device_id)` over the stored IMPACT and CLEAN_CROSSING Evidence rows, respectively, of the RoadDefect the Evidence is attached to, before the IngestResult is returned.
7. WHEN non-duplicate IMPACT Evidence is inserted, THE Ingestion_Service SHALL set `first_seen` to the earliest and `last_seen` to the latest IMPACT Evidence `timestamp` on the RoadDefect, including the newly inserted IMPACT, before the IngestResult is returned.

### Requirement 4: Confidence Scoring

**User Story:** As a city observer, I want confidence to reward independent devices and drop with clean crossings, so that no single phone can confirm or clear a defect.

#### Acceptance Criteria

1. WHEN non-duplicate Evidence is attached to a RoadDefect, THE Fusion_Engine SHALL recompute that RoadDefect's Confidence as `alpha / (alpha + beta)`, where `alpha = PRIOR_ALPHA + W_POS_DEVICE·P + W_POS_REPEAT·max(O − P, 0)` and `beta = PRIOR_BETA + W_NEG_DEVICE·N + W_NEG_REPEAT·max(C − N, 0)`, with P, O, N, and C counted over all non-duplicate Evidence attached to that RoadDefect, including the new Evidence.
2. THE Backend_Config SHALL define the six confidence weights with the values `PRIOR_ALPHA = 1`, `W_POS_DEVICE = 2.0`, `W_POS_REPEAT = 0.25`, `PRIOR_BETA = 3`, `W_NEG_DEVICE = 1.5`, `W_NEG_REPEAT = 0.15`, and THE Fusion_Engine SHALL read the weights only from Backend_Config.
3. FOR ALL non-negative integers P, O, N, C with O ≥ P and C ≥ N, THE Fusion_Engine SHALL produce a Confidence strictly greater than 0 and strictly less than 1.
4. FOR ALL RoadDefect Evidence sets, adding one non-duplicate CLEAN_CROSSING to the RoadDefect, from either a new or an already-counted Device_ID, with all other Evidence unchanged, SHALL produce a Confidence less than or equal to the Confidence before the addition.
5. FOR ALL RoadDefect Evidence sets, adding one non-duplicate IMPACT to the RoadDefect, from either a new or an already-counted Device_ID, with all other Evidence unchanged, SHALL produce a Confidence greater than or equal to the Confidence before the addition.
6. FOR ALL integers k > 1 and any fixed CLEAN_CROSSING Evidence (same N and C), k non-duplicate IMPACTs from one Device_ID (P = 1, O = k) SHALL produce a strictly lower Confidence than k non-duplicate IMPACTs from k distinct Device_IDs (P = k, O = k).

### Requirement 5: Defect Lifecycle

**User Story:** As a city observer, I want defects to move through SUSPECTED, CONFIRMED, LIKELY_REPAIRED, and RESOLVED, so that the map reflects both new potholes and repairs.

#### Acceptance Criteria

1. WHEN non-duplicate Evidence (IMPACT or CLEAN_CROSSING) is stored against a RoadDefect, THE Fusion_Engine SHALL evaluate `next_state(state, P, N, confidence)` once, after recomputing P (count of distinct devices with IMPACT Evidence on that RoadDefect), N (count of distinct devices with CLEAN_CROSSING Evidence on that RoadDefect), and Confidence from the RoadDefect's stored Evidence, using Confidence rounded to 6 decimal places for every threshold comparison.
2. WHEN `next_state` is evaluated and the state is CONFIRMED or LIKELY_REPAIRED and N ≥ 6 and Confidence < 0.40, THE Fusion_Engine SHALL set the state to RESOLVED, with this check taking precedence over criteria 3 and 4.
3. WHEN `next_state` is evaluated and the state is CONFIRMED and the condition in criterion 2 does not hold and N ≥ 3 and Confidence < 0.50, THE Fusion_Engine SHALL set the state to LIKELY_REPAIRED, with this check taking precedence over criterion 4.
4. WHEN `next_state` is evaluated and the state is SUSPECTED or LIKELY_REPAIRED and neither the condition in criterion 2 nor the condition in criterion 3 holds and P ≥ 3 and Confidence ≥ 0.68, THE Fusion_Engine SHALL set the state to CONFIRMED.
5. WHEN `next_state` is evaluated and none of the conditions in criteria 2, 3, or 4 hold, THE Fusion_Engine SHALL leave the state unchanged.
6. WHILE a RoadDefect is SUSPECTED, WHEN non-duplicate CLEAN_CROSSING Evidence is ingested for it and no new IMPACT Evidence is ingested for it, THE Fusion_Engine SHALL keep the state SUSPECTED and SHALL set Confidence to a value strictly lower than the Confidence before that ingest.
7. WHEN an ingest changes a RoadDefect's state, THE Ingestion_Service SHALL return `transition = {from, to}` in the IngestResult with `from` equal to the state before the ingest and `to` equal to the state after it, and WHEN an ingest leaves the state unchanged, THE Ingestion_Service SHALL return `transition = null`.
8. WHEN exactly one IMPACT from each of three distinct devices is ingested, all clustering into the same RoadDefect, and that RoadDefect has zero CLEAN_CROSSING Evidence, THE Fusion_Engine SHALL set the RoadDefect to CONFIRMED with Confidence equal to 0.700000 after rounding to 6 decimal places.
9. WHEN IMPACTs from exactly two distinct devices are ingested, all clustering into the same RoadDefect, and that RoadDefect has zero CLEAN_CROSSING Evidence, THE Fusion_Engine SHALL keep the RoadDefect SUSPECTED regardless of how many IMPACTs those two devices submit.
10. WHILE a RoadDefect is RESOLVED, THE Backend SHALL NOT change that RoadDefect's state to any other value.
11. THE Backend_Config SHALL define the lifecycle thresholds used by criteria 2–4, with defaults: CONFIRMED requires P ≥ 3 and Confidence ≥ 0.68; LIKELY_REPAIRED requires N ≥ 3 and Confidence < 0.50; RESOLVED requires N ≥ 6 and Confidence < 0.40.

### Requirement 6: Severity Aggregation

**User Story:** As a city observer, I want a robust severity score per defect, so that one noisy or frequent reporter does not dominate.

#### Acceptance Criteria

1. WHEN non-duplicate IMPACT Evidence is ingested, THE Fusion_Engine SHALL recompute Severity for the RoadDefect the Evidence was clustered into, using only that RoadDefect's `SEVERITY_WINDOW` most recent IMPACT Evidence rows (ordered by Evidence `timestamp`, newest first), counted across all devices combined.
2. WHEN computing Severity, THE Fusion_Engine SHALL first take, for each distinct `device_id` in the window, the median of that device's `impact_score` values, and then take the median of those per-device medians, where the median of an even-sized set is the mean of its two middle values.
3. THE Fusion_Engine SHALL produce Severity in [0, 100] inclusive.
4. FOR ALL RoadDefect evidence sets, THE Fusion_Engine SHALL let each distinct `device_id` in the window contribute exactly one value to the outer median, regardless of how many of the window's IMPACTs come from that device.
5. THE Backend_Config SHALL define the severity window `SEVERITY_WINDOW = 20`.

### Requirement 7: Defect Query and Demo Reset API

**User Story:** As the App, I want simple REST endpoints to read defects and reset the demo, so that the map and simulator stay in sync with the Backend.

#### Acceptance Criteria

1. WHEN `GET /health` is requested, THE Backend SHALL return HTTP 200 with the body `{"status":"ok"}`.
2. WHEN `GET /defects` is requested, THE Backend SHALL return HTTP 200 with a JSON array containing exactly one DefectOut per Active_Defect, excluding every RESOLVED RoadDefect, and an empty array when no Active_Defect exists.
3. WHEN `GET /defects/{id}` is requested for an existing RoadDefect in any state, including RESOLVED, THE Backend SHALL return HTTP 200 with that RoadDefect as a single DefectOut.
4. IF `GET /defects/{id}` references an `id` that matches no RoadDefect, THEN THE Backend SHALL return HTTP 404 and leave all stored data unchanged.
5. WHERE `DEMO_RESET_ENABLED` is true, WHEN `POST /demo/reset` is requested, THE Backend SHALL delete all Evidence and all RoadDefects and return HTTP 200 with the body `{"status":"reset"}`, such that a subsequent `GET /defects` returns an empty array and a subsequent `GET /defects/{id}` for any previously existing `id` returns HTTP 404.
6. WHERE `DEMO_RESET_ENABLED` is false, WHEN `POST /demo/reset` is requested, THE Backend SHALL return an HTTP 4xx error response without the body `{"status":"reset"}` and leave all Evidence and RoadDefects unchanged.
7. THE Backend SHALL serialize every DefectOut with exactly the fields `id`, `latitude`, `longitude`, `state`, `confidence`, `severity`, `positive_observation_count`, `positive_unique_device_count`, `clean_crossing_count`, `clean_unique_device_count`, `first_seen`, `last_seen`, `created_at`, `updated_at`, using these snake_case keys and ISO-8601 strings for `first_seen`, `last_seen`, `created_at`, and `updated_at`.

### Requirement 8: Backend Configuration, Persistence, and Concurrency

**User Story:** As a developer, I want a minimal, tunable, and safe Backend, so that the demo is reliable and easy to adjust.

#### Acceptance Criteria

1. THE Backend_Config SHALL be the single source of every Backend tunable: cluster radius (12 m), the six confidence weights (Requirement 4), the lifecycle thresholds (Requirement 5), severity window (20), dedupe window (2 s), validation limits (300 s future skew, 30 m GPS accuracy, 40 m clean-crossing distance), database path, and `DEMO_RESET_ENABLED`, with no other Backend module hard-coding these values.
2. WHEN the Backend starts, THE Backend SHALL ensure the `road_defect` and `evidence` tables and the `idx_evidence_defect` and `idx_evidence_device` indexes defined in the design exist in the single SQLite file at the Backend_Config database path, using the stdlib `sqlite3` module and no ORM.
3. THE Backend SHALL pass every SQL value as a bound `sqlite3` parameter and SHALL NOT build SQL text by string formatting or concatenation of input values.
4. WHEN Evidence is ingested, THE Ingestion_Service SHALL hold one process-level lock and one SQLite transaction from cluster lookup through commit, so that a failed ingest leaves no partial rows.
5. WHEN two IMPACTs located within the cluster radius of each other are ingested concurrently and no RoadDefect yet exists there, THE Ingestion_Service SHALL produce exactly one RoadDefect containing both IMPACTs.
6. THE Fusion_Engine SHALL implement clustering, confidence, severity, and lifecycle as pure functions that return identical outputs for identical inputs and perform no database, file, network, or clock access.
7. WHEN `uvicorn app.main:app --host 0.0.0.0 --port 8000` is run from `server/`, THE Backend SHALL serve its API on port 8000.
8. THE Backend SHALL list exactly `fastapi`, `uvicorn`, `pytest`, and `httpx` as its direct dependencies in `server/requirements.txt`, each pinned with `==` to an exact version.

### Requirement 9: Anonymous Identity and Privacy

**User Story:** As a driver, I want the App to observe roads rather than people, so that my identity and route stay private.

#### Acceptance Criteria

1. WHEN the App launches and no Device_ID is stored in `UserDefaults`, THE App SHALL generate a random UUID Device_ID and store it in `UserDefaults`.
2. WHEN the App launches and a Device_ID is already stored in `UserDefaults`, THE App SHALL reuse the stored Device_ID without generating a new one.
3. THE App SHALL identify the device to the Backend by the Device_ID alone, sending no other device, user, or account identifier.
4. THE App SHALL upload only discrete IMPACT and CLEAN_CROSSING Evidence, each describing one observation at one position, and SHALL NOT upload routes, location trails, continuous location, or raw motion streams.
5. THE MotionService SHALL hold raw motion data only in an in-memory ring buffer covering at most the most recent 2 s, and SHALL NOT write raw motion data to disk.
6. THE LocationService SHALL hold only the latest location fix, replacing it on each new fix, in memory only and never written to disk.
7. THE EvidenceUploader SHALL hold the retry queue in memory only, so that queued Evidence is not written to disk and does not persist after the App terminates.

### Requirement 10: App Shell, Configuration, API Client, and Polling

**User Story:** As a demo presenter, I want a simple three-tab app with a configurable server connection, so that I can point the App at the Mac on the LAN.

#### Acceptance Criteria

1. THE App SHALL present a root `TabView` with exactly three tabs, in the order Map, Drive, Demo.
2. THE AppConfig SHALL define, in one place, the default API base URL as a constant, the poll interval as 2 s, and the request timeout as 5 s.
3. WHEN the user changes the server URL value in the Demo_Tab, THE AppConfig SHALL persist that value in `UserDefaults` as the API base URL override, and THE APIClient SHALL use the override for every request issued after the change.
4. WHEN the App launches, THE AppConfig SHALL use the API base URL override stored in `UserDefaults` if one exists, and otherwise the default API base URL constant.
5. THE APIClient SHALL provide the async operations `health()`, `postEvidence(_:)`, `defects()`, `defect(id:)`, and `resetDemo()`, each decoding response bodies with ISO-8601 dates and snake_case keys.
6. IF an APIClient request fails, THEN THE APIClient SHALL throw exactly one typed `APIError`: `timeout` when no response arrives within 5 s, `unreachable` when the server cannot be reached, `http(status)` carrying the status code when the response status is outside 2xx, or `decoding` when the response body cannot be decoded.
7. THE APIClient SHALL be defined behind a protocol so that DefectStore and DemoSimulator accept a fake implementation of that protocol in tests.
8. WHILE the App scene phase is active, THE DefectStore SHALL request `GET /defects` once every 2 s through a single poll loop.
9. WHEN the App scene phase changes from active to any other phase, THE DefectStore SHALL stop the poll loop and issue no further `GET /defects` requests until the scene phase returns to active.
10. WHEN a poll succeeds, THE DefectStore SHALL publish the returned defect list, set the last refresh time to the time of that poll, and set connection status to connected, with the Map_Tab and the CleanCrossingTracker both reading from this same published state.
11. IF a poll fails with any `APIError`, THEN THE DefectStore SHALL keep the previously published defect list and last refresh time unchanged and set connection status to reflect the failure until the next successful poll.

### Requirement 11: Map Tab and Defect Detail Sheet

**User Story:** As a city observer, I want a live map of road defects with details, so that I can see where potholes are and how certain the system is.

#### Acceptance Criteria

1. WHEN the Map_Tab first appears after App launch, THE Map_Tab SHALL center the camera on the Demo_Coordinate.
2. THE Map_Tab SHALL render exactly one annotation per RoadDefect in the DefectStore, at that RoadDefect's Backend-returned latitude and longitude, using only the state, Confidence, and Severity values returned by the Backend with no client-side recomputation.
3. THE Map_Tab SHALL style SUSPECTED markers as amber outlined circles with `exclamationmark`, CONFIRMED markers as solid red circles with `exclamationmark.triangle.fill`, and LIKELY_REPAIRED markers as green/teal circles with `wrench.and.screwdriver.fill`.
4. THE Map_Tab SHALL size each marker by its Severity_Band using three distinct sizes, strictly increasing from low (< 40) to moderate (40 to < 70) to high (≥ 70).
5. WHEN a poll returns a RoadDefect whose state differs from its state in the previous poll, THE Map_Tab SHALL animate the marker's change to the new state's style.
6. WHEN a successful poll of `GET /defects` omits a RoadDefect id that was present in the previous successful poll, THE Map_Tab SHALL fade out and then remove that RoadDefect's marker.
7. WHILE location permission is authorized, THE Map_Tab SHALL show the user location annotation, and THE Map_Tab SHALL NOT itself request location permission, leaving permission requests to the Drive_Tab.
8. WHEN the user selects a marker, THE Map_Tab SHALL present a DefectDetailSheet for that RoadDefect with medium and large detents, showing the state pill, a confidence Gauge with Confidence expressed as a percentage, the Severity score and Severity_Band, P / O and N / C statistics, `first_seen` and `last_seen` as relative times, and a two-segment bar whose segments are proportional to O (positive) and C (clean) Evidence counts.
9. WHILE the DefectDetailSheet is open, THE Map_Tab SHALL refresh every displayed sheet value from the DefectStore entry with the same RoadDefect id after each successful poll.
10. WHILE the DefectStore connection status reports the Backend unreachable, THE Map_Tab SHALL keep displaying the markers from the last successful poll and show a connection pill, and THE Map_Tab SHALL hide the pill when the next poll succeeds.

### Requirement 12: Demo Simulator Traffic Generation

**User Story:** As a demo presenter, I want deterministic virtual traffic that uses the real ingestion path, so that judges see the real fusion engine work end to end.

#### Acceptance Criteria

1. THE DemoSimulator SHALL keep the ground truth (`hasPothole`, `isRepaired`, Demo_Coordinate) only on the device and SHALL send it to the Backend only as Evidence posted to `POST /evidence` through APIClient with `is_simulated = true`.
2. WHILE traffic is running, THE DemoSimulator SHALL wait one interval of `10 s / rateFactor / speed` (rateFactor Low = 3, Medium = 10, High = 25; speed 1, 2, or 5) before each Trip, counting from START for the first Trip and from the end of the previous Trip after that.
3. WHEN a Trip runs, THE DemoSimulator SHALL give it the sequence number k (k = 1 for the first Trip after RESET DEMO, then +1 for every Trip, including Trips that post nothing), a fresh UUID Device_ID, and the log label `Vehicle NN`, where NN is k zero-padded to at least two digits (for example `Vehicle 01`).
4. WHEN a Trip posts Evidence, THE DemoSimulator SHALL set the position to a golden-angle spiral point around the Demo_Coordinate with `θ = k·137.508°` and `r = 6 m·sqrt(((k − 1) mod 16 + 1) / 16)`, converted using `Δlat = r·cosθ / 111 320` and `Δlon = r·sinθ / (111 320·cos lat)`. It SHALL also set `speed_mps = 8 + (3k mod 7)`, `gps_accuracy_m = 3 + (k mod 6)`, and `timestamp` = the current device time when the post is made, so that every posted position is at most 6 m from the Demo_Coordinate.
5. WHEN a Trip posts an IMPACT, THE DemoSimulator SHALL set `impact_score = SCORES[(k − 1) mod 8]` with `SCORES = [58, 72, 64, 69, 55, 76, 61, 67]`, `peak_acceleration = 0.4 + impact_score/50` (g), `peak_jerk = 10 + impact_score/2` (g/s), and `rotation_rate = 0.6 + 0.1·(k mod 5)` (rad/s).
6. WHILE `hasPothole` is true and `isRepaired` is false, THE DemoSimulator SHALL post exactly one IMPACT per Trip.
7. WHEN the DemoSimulator receives the first IngestResult for an IMPACT while `demoDefectId` is unknown, THE DemoSimulator SHALL store that result's `defect.id` as `demoDefectId`.
8. WHILE `isRepaired` is true, `demoDefectId` is known, and the demo RoadDefect has not been seen as RESOLVED, THE DemoSimulator SHALL post exactly one CLEAN_CROSSING per Trip with `road_defect_id = demoDefectId`.
9. IF a Trip runs while `isRepaired` is true and `demoDefectId` is unknown, THEN THE DemoSimulator SHALL post no Evidence for that Trip and SHALL still increment k.
10. WHEN the DemoSimulator sees the demo RoadDefect reach RESOLVED, either as a RESOLVED transition in an IngestResult or as an HTTP 409 response to a CLEAN_CROSSING, THE DemoSimulator SHALL post no more Evidence for any later Trip and SHALL keep running Trips (incrementing k, posting nothing) until PAUSE TRAFFIC or RESET DEMO.
11. THE DemoSimulator SHALL wait for each `POST /evidence` response, or a failure, before starting the interval wait for the next Trip, so that no more than 1 simulator request is in flight at a time.
12. FOR ALL runs that start with RESET DEMO and have the same number of Trips in each ground-truth phase, THE DemoSimulator SHALL produce the same sequence of Evidence types and field values (except `device_id` and `timestamp`), the same log labels, and the same fusion outcomes (RoadDefect status transitions and the k at which each one happens).

### Requirement 13: Demo Controls, Event Log, and Visible Transitions

**User Story:** As a demo presenter, I want clear controls, a readable log, and obvious state changes, so that the audience can follow the lifecycle in about one minute.

#### Acceptance Criteria

1. THE Demo_Tab SHALL display the following controls: RESET DEMO, INJECT POTHOLE, START / PAUSE TRAFFIC, TRAFFIC RATE (segmented control with exactly Low / Medium / High), SIMULATION SPEED (segmented control with exactly 1x / 2x / 5x), REPAIR POTHOLE, a server URL field, and a health row.
2. WHEN RESET DEMO is pressed, THE DemoSimulator SHALL pause the traffic loop, call `POST /demo/reset`, set k to 1, set `hasPothole` to false, set `isRepaired` to false, clear `demoDefectId`, and empty the event log.
3. WHEN INJECT POTHOLE is pressed, THE DemoSimulator SHALL set `hasPothole` to true and `isRepaired` to false.
4. WHEN the START / PAUSE TRAFFIC control is pressed, THE DemoSimulator SHALL start the traffic loop if it is paused, or cancel the traffic loop if it is running.
5. WHEN REPAIR POTHOLE is pressed, THE DemoSimulator SHALL set `isRepaired` to true.
6. WHEN an IngestResult is received, THE Demo_Tab SHALL append one or more human-readable entries derived from that IngestResult (for example "Vehicle 03: impact detected (score 64)", "Defect #1 created · suspected", "Defect #1 confirmed", "Vehicle 12: clean crossing", "Defect #1 likely repaired", "Defect #1 resolved") to the event log, retaining only the 50 most recent entries and discarding the oldest.
7. IF a simulator post fails with a network error or timeout, THEN THE Demo_Tab SHALL append "Server unreachable, retrying" to the event log and THE DemoSimulator SHALL keep the traffic loop running.
8. IF 3 simulator posts in a row fail with a network error or timeout, with no successful post between them, THEN THE DemoSimulator SHALL pause the traffic loop and THE Demo_Tab SHALL show "Server unreachable" with a Resume control that restarts the traffic loop.
9. IF a simulator post returns a 4xx status, THEN THE DemoSimulator SHALL append an entry describing the failure to the event log and drop that post without retrying it.
10. THE Demo_Tab SHALL show a status card for the demo RoadDefect containing a state pill in the same color as that state's Map_Tab marker, the Confidence as a percentage, the P and N counts, and the Severity, updated from each IngestResult and, when no IngestResult defect is available, from `GET /defects/{id}` using `demoDefectId`.
11. WHEN the demo RoadDefect's state differs from its previously displayed state, THE Demo_Tab SHALL animate the state pill, show a short banner naming the new state, and fire a haptic.

### Requirement 14: Drive Tab and Sensing Status

**User Story:** As a driver, I want a simple sensing screen with clear status, so that I know when my phone is producing useful evidence.

#### Acceptance Criteria

1. THE Drive_Tab SHALL provide a single sensing button labeled START SENSING while no DriveSession is active and STOP SENSING while a DriveSession is active, where pressing START SENSING starts a DriveSession and pressing STOP SENSING stops it.
2. WHILE a DriveSession exists, THE Drive_Tab SHALL show sensing status (active or stopped), GPS status, current speed, session duration elapsed since START SENSING was pressed, impacts detected in the session, and the EvidenceUploader `uploadedCount` and `pendingCount`, where GPS status is: denied if location authorization is denied or restricted; searching if no fix has been received; poor if the latest fix has horizontal accuracy > `maxHorizontalAccuracyM` (20 m) or is older than 5 s; and good otherwise.
3. WHILE sensing is active, THE Drive_Tab SHALL show a Swift Charts line of acceleration magnitude `m` downsampled to 10 Hz, drawn only from samples held in the in-memory buffer.
4. WHILE a DriveSession is active and at least one blocking condition holds, THE Drive_Tab SHALL show a banner naming each holding condition from this set: motion unavailable (device motion not available), location denied (GPS status denied), poor GPS (GPS status searching or poor), too slow (latest fix speed < `minSpeedMps` (4.0 m/s) or unknown), or server unreachable (the most recent Evidence upload failed with an unreachable or timeout error).
5. IF device motion is unavailable, THEN THE Drive_Tab SHALL show "Motion sensors unavailable" and disable the START SENSING button so that pressing it starts no DriveSession.
6. IF location authorization is denied or restricted, THEN THE Drive_Tab SHALL show a banner containing a deep link that opens the app's page in iOS Settings, and THE DriveSession SHALL produce zero IMPACT and zero CLEAN_CROSSING Evidence until authorization is granted.
7. WHEN the ImpactDetector emits an impact event, THE DriveSession SHALL build exactly one IMPACT payload from the location fix that passed the impact gate, the event's peaks, and its score with `is_simulated = false`, and hand that payload to the EvidenceUploader.
8. WHEN the ImpactDetector emits an impact event, THE DriveSession SHALL increment the impacts-detected count by 1, call `CleanCrossingTracker.noteImpact(at:time:)` with the impact's fix and time, and trigger one light haptic and one counter animation.

### Requirement 15: Motion Processing and Impact Detection

**User Story:** As a driver, I want the phone to detect real road impacts and ignore phone handling, so that only meaningful jolts are reported.

#### Acceptance Criteria

1. THE DetectionConfig SHALL be the single source of every sensing constant, including `sampleHz = 50`, `windowSeconds = 2`, `sigmaFloorG = 0.03`, `zThreshold = 4.0`, `minPeakG = 0.35`, `jerkThresholdGps = 8.0`, `maxRotationRadS = 3.0`, `minSpeedMps = 4.0`, `maxHorizontalAccuracyM = 20`, `cooldownSeconds = 2.0`, `captureSeconds = 0.25`, and every bound and weight used in the impact score of criterion 6.
2. WHILE a DriveSession is active, THE MotionService SHALL deliver device-motion samples at `sampleHz` (50 Hz) on `OperationQueue.main` from exactly one `CMMotionManager` instance.
3. WHEN a motion sample arrives, THE ImpactDetector SHALL compute `m = |userAcceleration|` in g, `r = |rotationRate|` in rad/s, and `jerk = (m − m_prev)·sampleHz` in g/s, where `m_prev` is the m of the immediately preceding sample, and SHALL update the mean μ and standard deviation σ of m over the most recent `windowSeconds` (2 s) of samples.
4. WHILE no capture is in progress, WHEN a motion sample arrives and all of the following hold, THE ImpactDetector SHALL start a capture lasting `captureSeconds` (0.25 s): the latest location fix is at most 5 s old with horizontal accuracy ≤ `maxHorizontalAccuracyM` (20 m) and a known speed ≥ `minSpeedMps` (4.0 m/s); `z = (m − μ)/max(σ, sigmaFloorG) ≥ zThreshold` (4.0), with μ and σ taken from the window preceding the sample; m ≥ `minPeakG` (0.35 g); jerk ≥ `jerkThresholdGps` (8.0 g/s); r ≤ `maxRotationRadS` (3.0 rad/s); and at least `cooldownSeconds` (2.0 s) have elapsed since the previously emitted impact event, or no impact event has yet been emitted.
5. WHEN a capture completes, THE ImpactDetector SHALL emit exactly one impact event containing peak m (g), peak |jerk| (g/s), peak r (rad/s), and the duration in seconds during which m exceeded μ + 2σ within the capture, where μ and σ are the baseline values from the window preceding the triggering sample.
6. WHEN an impact event is emitted, THE ImpactDetector SHALL attach `score = round(100·raw·(1 − 0.3·n(peakRotation, 0.5, maxRotationRadS)))` with `raw = 0.35·n(z, zThreshold, 12) + 0.25·n(peakJerk, jerkThresholdGps, 40) + 0.20·n(peakG, minPeakG, 2.5) + 0.10·n(duration, 0.02, 0.20) + 0.10·n(speed, minSpeedMps, 20)` and `n(x, lo, hi) = clamp((x − lo)/(hi − lo), 0, 1)`, where z is the triggering sample's z, speed is the triggering fix's speed in m/s, and the score is an integer in [0, 100].
7. WHEN the ImpactDetector processes a flat synthetic signal with Gaussian noise of standard deviation 0.02 g, with a fresh location fix at speed ≥ `minSpeedMps` and accuracy ≤ `maxHorizontalAccuracyM`, THE ImpactDetector SHALL emit zero impact events.
8. WHEN the ImpactDetector processes a single-sample 1.5 g spike preceded by at least `windowSeconds` of flat baseline signal, with a fresh location fix at speed ≥ `minSpeedMps`, accuracy ≤ `maxHorizontalAccuracyM`, and r ≤ `maxRotationRadS`, THE ImpactDetector SHALL emit exactly one impact event.
9. IF the spike of criterion 8 occurs with fix speed below `minSpeedMps` or unknown, with r above `maxRotationRadS`, or less than `cooldownSeconds` after a previously emitted impact event, THEN THE ImpactDetector SHALL emit zero impact events for that spike.
10. WHEN two inputs identical except for spike amplitude both produce an impact event, THE ImpactDetector SHALL assign the larger-amplitude spike a score greater than or equal to the score of the smaller-amplitude spike.
11. THE ImpactDetector SHALL be a pure value type that receives motion samples, location fixes, and timestamps as inputs, produces identical events for identical input sequences, and runs in unit tests without `CMMotionManager`, `CLLocationManager`, or the system clock.

### Requirement 16: Location Handling

**User Story:** As a driver, I want location used only while I sense, so that the App tags evidence without tracking me.

#### Acceptance Criteria

1. WHEN a DriveSession starts, THE LocationService SHALL request When-In-Use authorization (never Always authorization), set `desiredAccuracy = kCLLocationAccuracyBestForNavigation` and `activityType = .automotiveNavigation`, and keep background location updates disabled.
2. WHILE a DriveSession is active, THE LocationService SHALL publish each fix that passes criterion 4 as the latest fix, replacing the previous latest fix.
3. WHEN the DriveSession stops, THE LocationService SHALL stop location updates and publish no further fixes until the next DriveSession starts.
4. IF a received fix has `horizontalAccuracy < 0`, has `horizontalAccuracy > 20 m`, or has a timestamp more than 5 s older than the device's current time, THEN THE LocationService SHALL discard the fix without publishing it, leaving the previous latest fix unchanged; fixes with accuracy exactly 20 m or age exactly 5 s SHALL be accepted.
5. IF an accepted fix reports `speed < 0`, THEN THE LocationService SHALL publish the fix with speed marked as unknown, and THE ImpactDetector SHALL treat unknown speed as failing the `minSpeedMps` (4.0 m/s) gate.
6. WHEN location authorization changes, THE LocationService SHALL publish the new authorization status (not determined, when-in-use, denied, or restricted).

### Requirement 17: Clean-Crossing Detection

**User Story:** As a city observer, I want phones to report when they pass a known defect without an impact, so that repairs are detected from negative evidence.

#### Acceptance Criteria

1. THE CleanCrossingTracker SHALL keep exactly one Encounter for each Active_Defect passed to `update(fix:activeDefects:now:)`, create each new Encounter in the Armed state, and read `cleanCrossingRadiusM = 12`, `exitRadiusM = 20`, `resetRadiusM = 60`, `maxEncounterSeconds = 30`, `minSpeedMps = 4.0`, and `maxHorizontalAccuracyM = 20` from DetectionConfig.
2. WHEN `update` is called and an Armed Encounter's RoadDefect is at a distance ≤ `cleanCrossingRadiusM` (12 m) from the current fix, THE CleanCrossingTracker SHALL move that Encounter to InEncounter, set `impactSeen = false`, and record the injected `now` as the encounter start time.
3. WHEN `update` is called and an InEncounter Encounter's RoadDefect is at a distance > `exitRadiusM` (20 m) from the current fix, THE CleanCrossingTracker SHALL move that Encounter to Disarmed and emit one CLEAN_CROSSING event only if all hold: `impactSeen` is false, the exit fix speed is ≥ `minSpeedMps` (4.0 m/s), and the exit fix horizontal accuracy is > 0 m and ≤ `maxHorizontalAccuracyM` (20 m); otherwise it SHALL emit no event.
4. IF `update` is called while an Encounter is InEncounter and the injected `now` is more than `maxEncounterSeconds` (30 s) after that Encounter's start time, THEN THE CleanCrossingTracker SHALL move the Encounter to Disarmed without emitting an event.
5. WHEN `update` is called and a Disarmed Encounter's RoadDefect is at a distance > `resetRadiusM` (60 m) from the current fix, THE CleanCrossingTracker SHALL move that Encounter to Armed; at distances ≤ 60 m the Encounter SHALL remain Disarmed and emit no event.
6. WHEN `noteImpact(at:time:)` is called, THE CleanCrossingTracker SHALL set `impactSeen = true` only for Encounters that are InEncounter and whose RoadDefect is at a distance ≤ `exitRadiusM` (20 m) from the impact position, and SHALL leave all other Encounters unchanged.
7. WHEN a CLEAN_CROSSING event is emitted, THE DriveSession SHALL pass the EvidenceUploader exactly one clean_crossing payload containing the exit fix position, the Encounter's `road_defect_id`, the exit fix speed, the exit fix GPS accuracy, and `is_simulated = false`.
8. FOR ALL passes with no impact, where the fix comes within 12 m of a RoadDefect, exits beyond 20 m within 30 s, and the exit fix has speed ≥ 4.0 m/s and accuracy ≤ 20 m, THE CleanCrossingTracker SHALL emit exactly one CLEAN_CROSSING for that RoadDefect. Any sequence of fixes that stays within 60 m of the RoadDefect after the first exit, including lingering or oscillating across the 12 m and 20 m radii, SHALL emit at most one CLEAN_CROSSING in total. A pass whose exit fix speed is below 4.0 m/s or unknown (speed < 0) SHALL emit none.
9. THE CleanCrossingTracker SHALL be a pure value type that reads time only from the injected `now`/`time` parameters and uses no sensor, location, or network APIs, so it can be unit tested without hardware.

### Requirement 18: Evidence Upload and Retry

**User Story:** As a driver, I want evidence to survive brief network drops, so that detections are not lost when the server is momentarily unreachable.

#### Acceptance Criteria

1. WHEN the EvidenceUploader receives a payload, THE EvidenceUploader SHALL issue one `postEvidence(_:)` request for that payload with no added delay or batching.
2. IF a post or retry fails with `APIError.unreachable`, `APIError.timeout` (5 s request timeout from AppConfig), or `APIError.http(status)` with status 500–599, THEN THE EvidenceUploader SHALL keep the payload, unchanged and with its original timestamp, in the in-memory FIFO retry queue, holding at most 50 items and discarding the oldest item when a 51st would be added.
3. WHILE the retry queue is non-empty, THE EvidenceUploader SHALL retry the oldest queued payload after a delay that starts at 2 s, doubles after each consecutive retryable failure (2 s, 4 s, 8 s, 16 s, 30 s, 30 s, …), never exceeds 30 s, and goes back to 2 s after a successful retry.
4. IF a post or retry returns `APIError.http(status)` with status 400–499, THEN THE EvidenceUploader SHALL discard the payload, remove it from the retry queue if present, and make no further attempts for it.
5. WHEN a post or retry returns a 2xx status, THE EvidenceUploader SHALL remove the payload from the retry queue if present and increment `uploadedCount` by 1.
6. THE EvidenceUploader SHALL publish `uploadedCount` as the number of payloads accepted with a 2xx status since launch, and `pendingCount` as the current number of payloads in the retry queue (0–50), updating each one whenever its value changes.

### Requirement 19: App Error Handling

**User Story:** As a demo presenter, I want the App to degrade gracefully, so that a hiccup never crashes the demo.

#### Acceptance Criteria

1. IF a Backend response cannot be decoded, THEN THE App SHALL log the `APIError.decoding` thrown by the APIClient, continue running without crashing, and keep the previously published defect data, Demo_Tab status card, and Drive_Tab counts unchanged until the next successful poll or response.
2. IF a DefectStore poll fails with `APIError.unreachable` or `APIError.timeout` (no response within the 5 s AppConfig request timeout), THEN THE DefectStore SHALL keep publishing the last successfully polled defect list and continue polling every 2 s per Requirement 10.
3. IF a Drive Evidence post fails with `APIError.unreachable` or `APIError.timeout`, THEN THE EvidenceUploader SHALL enqueue the payload for retry per Requirement 18.
4. IF a simulator post fails with `APIError.unreachable` or `APIError.timeout`, THEN THE DemoSimulator SHALL keep the traffic loop running per Requirement 13 criteria 7 and 8.
5. WHILE GPS status is searching or poor (no fix within the last 5 s with horizontal accuracy ≤ 20 m), THE DriveSession SHALL send no IMPACT or CLEAN_CROSSING Evidence to the EvidenceUploader.
6. WHEN a fix no older than 5 s with horizontal accuracy ≤ 20 m arrives while GPS status is searching or poor, THE DriveSession SHALL resume sending IMPACT and CLEAN_CROSSING Evidence without user action.
7. THE App SHALL access all Backend responses, motion data, and location data without force-unwraps, and THE APIClient SHALL perform every network call as an `async` operation that throws only `APIError`.

### Requirement 20: Xcode Project Constraints

**User Story:** As a developer, I want the existing Xcode project preserved with correct privacy and networking settings, so that the App builds and runs on the demo iPhone.

#### Acceptance Criteria

1. THE App SHALL be built from the existing `PotholeMesh.xcodeproj`, with new Swift files added only by placing them under the file-system synchronized folders (`PotholeMesh/PotholeMesh/` for app code, `PotholeMeshTests/` for unit tests), and with no project recreation and no added `pbxproj` file references.
2. THE App SHALL keep `IPHONEOS_DEPLOYMENT_TARGET = 26.2` unchanged in every build configuration (Debug and Release) where it is currently set.
3. THE App SHALL keep `GENERATE_INFOPLIST_FILE = YES` and set `INFOPLIST_KEY_NSMotionUsageDescription` and `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` as app-target build settings in both Debug and Release, with values that match the strings in the design character for character.
4. THE App SHALL use a partial plist at `PotholeMesh/PotholeMesh-Info.plist`, referenced by the app target's `INFOPLIST_FILE` and located outside the synchronized `PotholeMesh/PotholeMesh/` folder, that contains an ATS dictionary with `NSAllowsLocalNetworking = YES` and no `NSAllowsArbitraryLoads` key, plus a non-empty `NSLocalNetworkUsageDescription` string.
5. THE App SHALL keep `SWIFT_VERSION = 5.0` on the app and test targets, and keep `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on the app target.
6. THE App SHALL link only Apple frameworks (SwiftUI, MapKit, Core Motion, Core Location, Swift Charts, Foundation, XCTest), with zero Swift Package, CocoaPods, Carthage, or other third-party dependencies in the project.

### Requirement 21: Testing

**User Story:** As a developer, I want automated tests for fusion and detection logic, so that the demo-critical behavior is verified before judging.

#### Acceptance Criteria

1. THE Backend SHALL include `tests/test_fusion.py` that calls the Fusion_Engine functions directly, without a database or HTTP client, and asserts `haversine_m` distances, `find_cluster` clustering per Requirement 3, the closed-form Confidence values of Requirement 4, Requirement 5.8 (0.70), and Requirement 22.4 (0.40), every `next_state` transition and retained state in Requirement 5.2–5.5, and `aggregate_severity` results per Requirement 6.
2. THE Backend SHALL include `tests/test_api_lifecycle.py` that exercises the Backend through `TestClient` against a fresh temporary SQLite file per test, covering ingestion (Requirement 1), clustering (Requirement 3), confirmation (Requirement 5.8–5.9), repeat-device discount (Requirement 4.6), Confidence monotonicity (Requirement 4.4–4.5), the repair lifecycle (Requirement 5.2–5.3), RESOLVED as terminal (Requirement 5.10), idempotent retry (Requirement 2.3), identical RoadDefect outcomes for payloads differing only in `is_simulated`, and the Requirement 22.1–22.4 demo sequence sent as raw `POST /evidence` requests.
3. THE App SHALL include `ImpactDetectorTests` covering Requirement 15.7–15.10 and `CleanCrossingTrackerTests` covering Requirement 17.2–17.6 and 17.8 in the existing XCTest `PotholeMeshTests` target, using synthetic motion samples and location fixes with injected time and no sensor hardware, location permission, or network access.
4. THE Backend tests SHALL use parametrized pytest, SHALL run with only the Requirement 8.8 dependencies installed, and SHALL NOT use Hypothesis or any other property-testing library.
5. WHEN `pytest` is run from `server/`, THE Backend tests SHALL all pass without a running uvicorn server or network access, and without modifying any SQLite file other than the per-test temporary file.
6. WHEN the `PotholeMeshTests` target is run, THE App tests SHALL all pass without a physical device or a reachable Backend.

### Requirement 22: End-to-End Demo (Definition of Done)

**User Story:** As a hackathon judge, I want to watch a pothole appear, confirm, and resolve on a real iPhone, so that I can see the full distributed-sensing lifecycle.

#### Acceptance Criteria

1. WHEN the presenter presses RESET DEMO, then INJECT POTHOLE, then START TRAFFIC at Low @ 1x (one trip every 3.3 s, first trip one interval after START), THE App SHALL show the demo RoadDefect as SUSPECTED after Trip 1 (about 3.3 s, P = 1) and as CONFIRMED after Trip 3 (about 10 s, P = 3, Confidence 0.70), with the Map_Tab rendering the SUSPECTED marker in at least one 2 s `GET /defects` poll result between Trip 1 and Trip 3.
2. WHEN the presenter then switches to Medium @ 1x (one trip every 1.0 s) and runs traffic until P = 11 (8 more trips, about 8 s), THE Backend SHALL report the demo RoadDefect as CONFIRMED with P = 11, N = 0, and Confidence = 23/26, which displays as 0.88 at two decimal places.
3. WHEN the presenter then presses REPAIR POTHOLE at Medium @ 2x (one clean-crossing trip every 0.5 s, each from a new unique device) with P = 11, THE Backend SHALL move the demo RoadDefect from CONFIRMED to LIKELY_REPAIRED on the ingest that makes N = 14 (Confidence 23/47 < 0.50) and to RESOLVED on the ingest that makes N = 22 (Confidence 23/59 < 0.40), and SHALL NOT change state at any other N in that range.
4. IF P = 11 and N = 21, THEN THE Fusion_Engine SHALL compute Confidence exactly 0.40 (23/57.5) and keep the demo RoadDefect in LIKELY_REPAIRED, because RESOLVED requires Confidence strictly below 0.40.
5. WHEN the demo RoadDefect reaches RESOLVED, THE Map_Tab SHALL remove its marker no later than the first `GET /defects` poll that completes after the transition, and THE Demo_Tab SHALL show the state RESOLVED as returned by `GET /defects/{id}`.
6. THE App SHALL complete the scripted demo sequence in criteria 1 through 5, measured from the RESET DEMO press to the Demo_Tab showing RESOLVED, within 2 minutes on a real iPhone connected over the LAN to the Backend running on the developer Mac.
7. WHEN a real drive or bump test produces an IMPACT on the Drive_Tab and its `POST /evidence` upload succeeds, THE Map_Tab SHALL show a marker for the RoadDefect returned in that upload's IngestResult no later than the first `GET /defects` poll that completes after the upload, using the same `POST /evidence` pipeline as the simulator.
