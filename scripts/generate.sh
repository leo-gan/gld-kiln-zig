#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${ZIG:-}" ]]; then
  zig_bin="${ZIG}"
elif command -v zig >/dev/null 2>&1; then
  zig_bin="zig"
elif [[ -x "${HOME}/zig-0.16.0/zig" ]]; then
  zig_bin="${HOME}/zig-0.16.0/zig"
else
  zig_bin="/home/leo/.local/zig/zig"
fi
mkdir -p examples/generated
"${zig_bin}" build
./zig-out/bin/gld-kilngen-zig testdata/schema/point.json -o examples/generated/point.zig
./zig-out/bin/gld-kilngen-zig testdata/schema/message.json -o examples/generated/message.zig
