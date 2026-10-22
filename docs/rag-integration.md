# Pulse RAG integration

The assistant now uses source-linked evidence locally and can call the Python RAG API. It preserves the existing AssistantService protocol and the existing Xcode file list.

## Data flow

- CrashEvent is converted to a small AssistantIncident when the check-in opens.
- AssistantContext maps the Facts/Heart profile choice to practical/supportive.
- The assistant screen explicitly chooses Washington or an unspecified jurisdiction and immediate versus follow-up help.
- Only the latest user question, those preferences and a minimal incident summary go to /v1/assist.
- Medical notes, family contact names, insurer policy numbers, raw telemetry and precise coordinates are not automatically uploaded.
- Sensor decisions stay experimental observations. A suspected crash does not prove injury, a rejected event does not prove safety, and silence does not prove unconsciousness.
- The existing detector's transportation mode comes from the configured vehicle profile. It is labelled profile, not an ML prediction.
- Family alert delivery is not inferred from the crash scenario. Unsupported delivery claims were removed from assistant greetings.

## Local and server behavior

LocalEvidenceAssistant includes the 20 current source-linked cards as Swift constants. It filters by scope, incident stage and expiry. It is simple lexical retrieval, not on-device model inference.

RAGAssistantService checks urgent phrases locally before any request, uses a 1.5 second request timeout and falls back to local cards on network or decoding failure. The emergency keyword rules are a prototype and are not reliable medical triage. Emergency calling remains the user's explicit action.

In a Debug iPhone simulator, the default server is http://127.0.0.1:8787 on the Mac running the simulator. Start Python there. A Windows server is not the Mac's loopback server.

Real-device/release builds use local cards unless RAGEndpoint is explicitly configured as an HTTPS URL in Info.plist. The supplied server binds to loopback only; it is not a public authenticated production backend. Do not simply expose that development server to the internet.

Local simulator networking is enabled with NSAllowsLocalNetworking; ATS is not globally disabled. Apple reference:
https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking

## ML boundary

The separate transport_adapter.py can run the inspected upstream harsh-driving module with explicit g-to-m/s2 and m/s-to-km/h conversions, sample timing checks, heading alignment and a pinned source hash.

The classifier has eight SHL classes: still, walk, run, bike, car, bus, train, subway. No motorcycle class is invented. A profile-selected motorcycle remains a profile fact. A softmax score is not a calibrated confidence or a crash probability.

The selected P2a checkpoint exists, but its expected metrics.json normalization metadata is missing in this checkout. No checkpoint is silently loaded with invented preprocessing. prepare_imu_window requires a verified input contract and normalization metadata before inference inputs can be prepared. TensorFlow/Core ML inference is not enabled by this change.

## Validation

Python integration and retrieval tests were run on Windows. Four Swift integration tests were added to the existing iOS test file; they still require Xcode to execute. No iPhone simulator build or real-device test was run here.

The medical/insurance corpus remains an editorial prototype pending professional review. The repository index is a separate developer-only database and cannot be retrieved by the end-user medical endpoint.

Before a release: run the iOS test workflow, review the content, update expired cards, test failures on a device, and document privacy handling for the deployed backend and user-entered question text.

The adapter currently exposes only harsh_brake and harsh_accel. Rotational and speeding labels are suppressed pending physical-axis and actual-speed-limit integration.

## Backend location

The maintained Python backend is Backend/rag in this repository. Start it with python rag.py ingest followed by python rag.py serve from that directory. See Backend/rag/README.md for API and optional model setup.
