#!/usr/bin/env bash
set -euo pipefail
echo "Zig ships as a GitHub release."
if [[ -z "${ZIG_REGISTRY_TOKEN:-}" ]]; then
  echo "package registry secret is missing"
fi
exit 0
