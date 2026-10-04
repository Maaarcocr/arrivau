#!/usr/bin/env bash
# Run an iOS app → real HTTP API E2E test against disposable state on macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS tests require macOS, Xcode, and an installed iPhone simulator runtime." >&2
  exit 1
fi
for tool in cargo xcodegen xcodebuild xcrun python3 curl; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
# Avoid connecting the app to an unrelated server or a nonempty development DB.
python3 - <<'PY'
import socket
with socket.socket() as sock:
    try:
        sock.bind(('127.0.0.1', 8080))
    except OSError as error:
        raise SystemExit('Port 8080 is occupied; stop the development API before running iOS tests') from error
PY
cargo build --locked --manifest-path api/Cargo.toml
TARGET_DIR="$(cargo metadata --no-deps --format-version 1 --manifest-path api/Cargo.toml | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/arrivau-ios.XXXXXX")"
API_PID=""
EXPORT_PYTHON=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$API_PID" ]]; then
    kill "$API_PID" 2>/dev/null || true
    wait "$API_PID" 2>/dev/null || true
  fi
  if [[ $status -ne 0 ]]; then
    if [[ -n "${RESULT:-}" && -d "$RESULT" && -n "$EXPORT_PYTHON" ]]; then
      "$EXPORT_PYTHON" scripts/export-screenshots.py "$RESULT" "$ROOT/ios/build/screenshots" || true
    fi
    echo "API log (temporary test state retained at $TEMP_DIR):" >&2
    cat "$TEMP_DIR/api.log" >&2 || true
  else
    rm -rf "$TEMP_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT
python3 -m venv "$TEMP_DIR/screenshot-tools"
EXPORT_PYTHON="$TEMP_DIR/screenshot-tools/bin/python"
"$EXPORT_PYTHON" -m pip install --disable-pip-version-check --quiet zstandard==0.25.0
ARRIVAU_DEMO=1 ARRIVAU_ADDR=127.0.0.1:8080 ARRIVAU_DB_PATH="$TEMP_DIR/arrivau.sqlite3" \
  "$TARGET_DIR/debug/arrivau-api" >"$TEMP_DIR/api.log" 2>&1 &
API_PID=$!
READY=0
for _ in {1..100}; do
  if ! kill -0 "$API_PID" 2>/dev/null; then
    echo "API exited during startup" >&2
    exit 1
  fi
  if curl -fsS --max-time 1 http://127.0.0.1:8080/health >/dev/null; then
    READY=1
    break
  fi
  sleep 0.2
done
[[ "$READY" == "1" ]] || { echo "API did not become healthy" >&2; exit 1; }
if [[ -z "${SIMULATOR_UDID:-}" ]]; then
  SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
  export SDK_VERSION
  SIMULATOR_UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, os, re, sys
def version(value):
    return tuple(int(part) for part in re.findall(r"\d+", value))
sdk = version(os.environ["SDK_VERSION"])
catalog = json.load(sys.stdin)["devices"]
choices = [(runtime, device) for runtime, devices in catalog.items()
           if "iOS" in runtime and version(runtime.split("iOS-")[-1]) <= sdk
           for device in devices if device.get("isAvailable") and "iPhone" in device["name"]]
if not choices:
    raise SystemExit("No available iPhone simulator; install an iOS runtime in Xcode Settings")
# A booted device avoids unnecessary cold boots; otherwise choose a recent runtime.
choices.sort(key=lambda pair: (
    version(pair[0].split("iOS-")[-1]),
    pair[1].get("state") == "Booted",
    "SE" not in pair[1]["name"],
    version(pair[1]["name"]),
    "Pro" in pair[1]["name"]
), reverse=True)
print(choices[0][1]["udid"])
')"
fi
xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
(cd ios && xcodegen generate)
mkdir -p ios/build
RESULT="$ROOT/ios/build/TestResults-$(date -u +%Y%m%dT%H%M%SZ).xcresult"
xcodebuild test \
  -project ios/Arrivau.xcodeproj \
  -scheme Arrivau \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath "$ROOT/ios/DerivedData" \
  -resultBundlePath "$RESULT" \
  -parallel-testing-enabled NO \
  -testLanguage it \
  -testRegion IT \
  CODE_SIGNING_ALLOWED=NO
"$EXPORT_PYTHON" scripts/export-screenshots.py "$RESULT" "$ROOT/ios/build/screenshots" --require-all
printf '\nNative tests passed; Xcode result: %s\n' "$RESULT"


