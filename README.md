# Pothole Mesh

Pothole Mesh turns iPhones into a distributed road-condition sensor network. The iPhone app (tabs: Map, Drive, Demo) reports compact IMPACT and CLEAN_CROSSING evidence to a local FastAPI + SQLite backend, which clusters it into road defects and moves each one through SUSPECTED → CONFIRMED → LIKELY_REPAIRED → RESOLVED. The Demo tab's traffic simulator posts through the same `POST /evidence` endpoint real phones use.

- `server/`: Python 3.11+ backend (FastAPI, uvicorn, stdlib `sqlite3`)
- `PotholeMesh/`: SwiftUI iPhone app (Xcode project, Apple frameworks only)

## 1. Run the backend (Mac)

```sh
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

`--host 0.0.0.0` is required so the iPhone can reach the Mac over the LAN. Check it with `curl http://localhost:8000/health`, which returns `{"status":"ok"}`. If macOS asks whether Python may accept incoming network connections, choose Allow.

The database is `server/data/pothole_mesh.db` (gitignored). Optional environment variables:

- `POTHOLE_MESH_DB_PATH`: use a different SQLite file
- `POTHOLE_MESH_DEMO_RESET_ENABLED=0`: disable `POST /demo/reset`

The backend has no authentication. Anyone on the same network can post evidence or reset the demo, so run it only on a trusted network.

### Backend tests

```sh
cd server
source .venv/bin/activate
python -m pytest
```

Tests use a fresh temporary SQLite file each and need no running server or network.

## 2. Run the app (iPhone)

1. Open `PotholeMesh/PotholeMesh.xcodeproj` in Xcode, select your iPhone, set your signing team, and run.
2. Find the Mac's LAN IP. Use `ipconfig getifaddr en0` (Wi-Fi; try `en1` if that's empty), or open System Settings → Wi-Fi → Details. The iPhone and the Mac must be on the same Wi-Fi network.
3. In the app, open the **Demo** tab. Enter `http://<Mac LAN IP>:8000` (for example `http://192.168.1.20:8000`) in the Server field, then tap **Save**. The health row should show "Server healthy".
4. On the first request to the Mac, iOS asks to let Pothole Mesh find and connect to devices on your local network. Tap **Allow**. If you tapped Don't Allow, turn it back on in Settings → Privacy & Security → Local Network → Pothole Mesh.

In the iOS Simulator on the same Mac, the default `http://localhost:8000` works without changes.

### iOS tests

```sh
xcodebuild -project PotholeMesh/PotholeMesh.xcodeproj -scheme PotholeMesh \
  -destination 'platform=iOS Simulator,name=<iPhone simulator>' \
  -only-testing:PotholeMeshTests test
```

Pick a simulator name from `xcrun simctl list devices available`.

## 3. Demo script (Definition of Done)

Run it on the iPhone with the backend running on the Mac. The whole sequence takes about one minute and should finish within 2 minutes. Keep the Map tab one swipe away to show the marker changing.

| Step | Demo tab action | What you should see |
|---|---|---|
| 1 | **RESET DEMO** | Log cleared, status card shows "None yet", Map is empty |
| 2 | **INJECT POTHOLE** | Ground truth shows "pothole present" |
| 3 | Traffic rate **Low**, speed **1x**, then **START TRAFFIC** | Trip 1 (~3.3 s): Defect #1 created · suspected (amber marker). Trip 3 (~10 s): P = 3, confidence 70%, **confirmed** (red marker) |
| 4 | Switch to **Medium @ 1x**, run about 8 s | 8 more trips: P = 11, confidence 88%, stays confirmed |
| 5 | Switch to **2x**, then **REPAIR POTHOLE** | Vehicles report clean crossings. At N = 14: **likely repaired** (teal marker). At N = 22: **resolved** |
| 6 | Watch the Map | The marker fades out on the next poll. The Demo status card shows Resolved |
| 7 | **PAUSE TRAFFIC** | Traffic stops; after RESOLVED, trips post nothing anyway |

Each state change animates the status pill, shows a short banner, and fires a haptic. Tap a marker on the Map to open its detail sheet (confidence, severity, P / O, N / C, first and last seen).

If the server becomes unreachable during the demo, the log shows "Server unreachable, retrying". After 3 failures in a row, traffic pauses and a **Resume** button appears. The Map keeps the last markers and shows a "Server unreachable" pill until the next successful poll.

### Real-sensor check (Drive tab)

1. Open the **Drive** tab and tap **START SENSING**. Allow location access (While Using the App) when asked.
2. Drive over a bump at more than about 9 mph (4 m/s) with good GPS.
3. The impact count increases, the upload counter increments, and a marker appears on the Map on the next poll.

Banners explain anything that blocks evidence: motion unavailable, location denied (with a link to Settings), poor GPS, too slow, or server unreachable. Only discrete impact and clean-crossing events are uploaded; routes and raw motion never leave the phone.
