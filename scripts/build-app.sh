#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product ChatSlaughter
binary_dir=$(swift build -c release --show-bin-path)
python3 scripts/bundle.py "$binary_dir/ChatSlaughter" "${TDLIB_PATH:-$(brew --prefix tdlib)/lib/libtdjson.dylib}"
