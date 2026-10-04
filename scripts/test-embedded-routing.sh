#!/usr/bin/env bash
# Native build + deterministic graph integration test. No daemon, API or Docker.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${OSRM_BACKEND_PATH:?Set OSRM_BACKEND_PATH to the pinned OSRM 6.0.0 install prefix}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/api/tests/fixtures/routing.osm" "$WORK/fixture.osm"
"$OSRM_BACKEND_PATH/bin/osrm-extract" --threads 1 -p "$OSRM_BACKEND_PATH/share/osrm/profiles/car.lua" "$WORK/fixture.osm"
"$OSRM_BACKEND_PATH/bin/osrm-contract" --threads 1 "$WORK/fixture.osrm"
python3 "$ROOT/scripts/osrm-manifest.py" "$WORK/fixture.osrm" \
  --osm-timestamp 2026-01-01T00:00:00Z \
  --service-bounds 15.08 36.70 15.14 36.75 --extract-bounds 15.07 36.69 15.15 36.76
ARRIVAU_TEST_OSRM_MANIFEST="$WORK/manifest.json" \
  cargo test --locked --manifest-path "$ROOT/api/Cargo.toml" --features embedded-osrm --test embedded_routing -- --ignored
