#!/usr/bin/env bash
# Build a new immutable regional graph. Does not download data, change live config,
# restart any process, or overwrite an existing dataset.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT="${1:?Usage: prepare-osrm-region.sh INPUT.osm.pbf NEW_ABSOLUTE_DIRECTORY}"
OUT="${2:?Supply a new absolute output directory}"
: "${OSRM_BACKEND_PATH:?Set the pinned OSRM 6.0.0 install prefix}"
[[ "$OUT" = /* && ! -e "$OUT" && -f "$INPUT" ]] || { echo 'Input must exist; output must be a new absolute directory' >&2; exit 2; }
[[ "$("$OSRM_BACKEND_PATH/bin/osrm-extract" --version)" == *v6.0.0* ]] || { echo 'OSRM 6.0.0 required' >&2; exit 2; }
command -v osmium >/dev/null
command -v python3 >/dev/null
TIMESTAMP="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$INPUT")"
[[ -n "$TIMESTAMP" ]] || { echo 'PBF source timestamp missing; use a dated OSM extract' >&2; exit 2; }
mkdir -p "$OUT"
# A larger buffer than the supported service area retains sensible boundary routes.
osmium extract --bbox 14.85,36.60,15.25,37.10 --strategy complete_ways "$INPUT" -o "$OUT/region.osm.pbf"
"$OSRM_BACKEND_PATH/bin/osrm-extract" --threads "${OSRM_PREPARE_JOBS:-2}" \
  -p "$OSRM_BACKEND_PATH/share/osrm/profiles/car.lua" "$OUT/region.osm.pbf"
"$OSRM_BACKEND_PATH/bin/osrm-contract" --threads "${OSRM_PREPARE_JOBS:-2}" "$OUT/region.osrm"
python3 "$ROOT/scripts/osrm-manifest.py" "$OUT/region.osrm" --osm-timestamp "$TIMESTAMP" \
  --service-bounds 14.95 36.65 15.18 36.95 --extract-bounds 14.85 36.60 15.25 37.10
printf '%s\n' '© OpenStreetMap contributors. Licensed under ODbL 1.0.' \
  'https://www.openstreetmap.org/copyright' 'https://opendatacommons.org/licenses/odbl/1-0/' \
  "Source PBF timestamp: $TIMESTAMP" > "$OUT/ATTRIBUTION.txt"
sha256sum "$INPUT" > "$OUT/source-pbf.sha256"
echo "Dataset prepared at $OUT; opt in explicitly only after measuring the target host."
