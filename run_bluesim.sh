#!/usr/bin/env bash
# Start BlueSim for an external SITL (sim_vehicle.py --model JSON), e.g. the
# DYNAMIC ArduSub build. Imports the assets on the first run and uses the
# NVIDIA GPU when there is one.
#
#   GODOT  path to the Godot 3.2.3 binary (default ~/Godot_v3.2.3-stable_x11.64)
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT="${GODOT:-$HOME/Godot_v3.2.3-stable_x11.64}"

if [ ! -x "$GODOT" ]; then
  echo "Godot 3.2.3 not found at $GODOT (set GODOT=/path/to/godot)" >&2
  exit 1
fi

# run on the NVIDIA GPU (PRIME render offload) if the driver is installed
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  export __NV_PRIME_RENDER_OFFLOAD=1
  export __GLX_VENDOR_LIBRARY_NAME=nvidia
fi
unset DRI_PRIME

cd "$HERE"
if [ "$(ls .import 2>/dev/null | wc -l)" -lt 40 ]; then
  echo "Importing assets (first run only, takes a few minutes)..."
  "$GODOT" --path . -e --quit || true
fi

export BLUESIM_EXTERNAL_SITL=1
exec "$GODOT" --path . --print-fps "$@"
