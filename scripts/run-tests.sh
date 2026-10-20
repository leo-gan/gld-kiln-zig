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
"${zig_bin}" build test
