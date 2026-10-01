#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
cargo fmt --manifest-path api/Cargo.toml -- --check
cargo clippy --locked --manifest-path api/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path api/Cargo.toml
python3 -m py_compile scripts/e2e.py
