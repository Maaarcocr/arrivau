#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export ARRIVAU_DEMO=1
export ARRIVAU_ADDR="${ARRIVAU_ADDR:-127.0.0.1:8080}"
export ARRIVAU_DB_PATH="${ARRIVAU_DB_PATH:-$ROOT/arrivau.sqlite3}"
exec cargo run --locked --manifest-path api/Cargo.toml
