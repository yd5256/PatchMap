---
inclusion: always
---

# Pothole Mesh Hackathon Constraints

This repository is the Hackachusetts MVP for Pothole Mesh.

Core architecture:
- Native iPhone app: Swift 6 / SwiftUI, iOS 17+, Core Motion, Core Location, MapKit, URLSession.
- Backend: Python, FastAPI, SQLite.
- The iPhone app has exactly three primary tabs: Map, Drive, Demo.
- Real phones and simulated devices must send evidence through the same backend ingestion/fusion pipeline.
- Core product concept: distributed road-impact sensing with positive evidence AND clean-crossing negative evidence.
- Optimize for a reliable, polished hackathon demo rather than production-scale architecture.

Engineering priorities:
1. Working backend fusion/lifecycle logic.
2. Complete simulator-driven end-to-end demo.
3. Live native map.
4. Real Core Motion/Core Location sensing.
5. Polish and reliability.

Keep dependencies and architecture minimal.

Do not add unrelated features or broaden scope without being explicitly asked.

Avoid:
- Web frontend or PWA
- Android
- authentication
- LLM/chat features
- PostGIS
- WebSockets
- microservices
- background iOS sensing
- Boston 311 integration
- ML pothole classifier
- route planning
- unnecessary cloud infrastructure