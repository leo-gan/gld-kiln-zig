#!/usr/bin/env bash
# Install Zig 0.16.0 on Ubuntu when it is not already on PATH.
set -euo pipefail

add_path() {
  local dir="$1"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "${dir}" >> "${GITHUB_PATH}"
  fi
  export PATH="${dir}:${PATH}"
}

if command -v zig >/dev/null 2>&1; then
  zig version
  exit 0
fi
if [[ -x "${HOME}/zig-0.16.0/zig" ]]; then
  add_path "${HOME}/zig-0.16.0"
  zig version
  exit 0
fi

if command -v sudo >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends curl ca-certificates xz-utils tar
else
  apt-get update
  apt-get install -y --no-install-recommends curl ca-certificates xz-utils tar
fi

arch="$(uname -m)"
prefix="${HOME}/zig-0.16.0"
mkdir -p "${prefix}"
url="https://ziglang.org/download/0.16.0/zig-${arch}-linux-0.16.0.tar.xz"
curl -fL --retry 3 "${url}" | tar -xJ -C "${prefix}" --strip-components=1
add_path "${prefix}"
zig version
