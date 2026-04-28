#!/usr/bin/env bash
# Build the AirSink-patched uxplay (adds the -tap <socket> frame fan-out flag).
# Output: vendor/UxPlay/build/uxplay
set -euo pipefail

cd "$(dirname "$0")/UxPlay"

if [[ ! -f lib/frame_tap.c ]]; then
  echo "lib/frame_tap.c missing — the AirSink patch is not applied to this checkout." >&2
  exit 1
fi

mkdir -p build
cd build

# NO_MARCH_NATIVE: build is portable and survives cpu changes between machines.
cmake .. -DNO_MARCH_NATIVE=ON
make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

echo
echo "Built: $(pwd)/uxplay"
./uxplay -h | grep -E "^-tap" || {
  echo "WARNING: -tap flag not in --help output. Check the patch." >&2
  exit 1
}
