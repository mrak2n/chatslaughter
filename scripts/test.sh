#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir=$(xcode-select -p)
frameworks="$developer_dir/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
  exec swift test --disable-xctest -Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" "$@"
fi
exec swift test --disable-xctest "$@"
