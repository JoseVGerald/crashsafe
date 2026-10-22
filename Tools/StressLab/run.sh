#!/bin/sh
# Virtual stress test for crash detection. Downloads the free datasets on first run
# (Backend/datasets/, gitignored), then writes docs/stress-test-report.md.
set -e
cd "$(dirname "$0")/../.."
python3 -I Tools/StressLab/fetch_datasets.py Backend/datasets
# -enable-testing lets the tool use the app's internal types, compiled from the same sources.
swift run -c release -Xswiftc -enable-testing StressLab --datasets Backend/datasets --out docs/stress-test-report.md "$@"
