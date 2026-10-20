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
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
"${zig_bin}" build
./zig-out/bin/gld-kilngen-zig testdata/schema/point.json -o "${tmpdir}/point.zig"
./zig-out/bin/gld-kilngen-zig testdata/schema/point.json -o "${tmpdir}/point2.zig"
./zig-out/bin/gld-kilngen-zig testdata/schema/message.json -o "${tmpdir}/message.zig"
./zig-out/bin/gld-kilngen-zig testdata/schema/message.json -o "${tmpdir}/message2.zig"
cmp "${tmpdir}/point.zig" "${tmpdir}/point2.zig"
cmp "${tmpdir}/message.zig" "${tmpdir}/message2.zig"
cat > "${tmpdir}/driver.zig" <<'EOF'
const point = @import("point.zig");
const message = @import("message.zig");
const std = @import("std");
test "generated files parse" {
    _ = point.Point{ .x = 1, .y = 2, .label = "n" };
    _ = message.Message{};
    try std.testing.expect(true);
}
EOF
"${zig_bin}" test --dep kiln \
  -Mroot="${tmpdir}/driver.zig" \
  -Mkiln="${PWD}/src/root.zig" \
  --cache-dir "${tmpdir}/cache"
