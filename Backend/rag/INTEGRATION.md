# CrashSafe repository integration

The iOS app, Android app and shared backend are maintained together in this repository. See [RAG integration](../../docs/rag-integration.md) for the app services and privacy boundary, and the [Android guide](https://github.com/JoseVGerald/crashsafe/blob/feature/android-app/android/README.md) for Android setup.

From Backend/rag, build the medical index with python rag.py ingest. To build an isolated developer index from local clones, run:

~~~powershell
python build_repo_context.py --app-root ../.. --ml-root PATH_TO_TRANSPORT_REPO
~~~

Run python rag.py serve. POST /v1/assist accepts the current question, explicit jurisdiction/stage, persona and an optional minimal incident packet. POST /v1/developer/retrieve searches repository documentation separately from end-user guidance.

The transport module is an external local dependency; its training code and weights are not copied into this repository. transport_adapter.py executes only the pinned, inspected upstream behavior module and exposes aligned longitudinal events. It suppresses rotation and fixed-threshold speeding labels. The selected checkpoint lacks its normalization metadata, so live classifier inference remains disabled.

The developer index, generated databases, local manifests and test logs are excluded from Git. Rebuild them on each machine. Tests that require a local transport checkout skip when the optional manifest/clone is absent. The other tests and the standard-library server work without that checkout.

Validation in the development environment: 60 Python tests passed, including actual upstream synthetic braking tests. Swift tests were added but require Xcode. This remains an experimental crash/medical-information prototype awaiting professional review.
