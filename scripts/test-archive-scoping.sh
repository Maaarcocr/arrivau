#!/usr/bin/env bash
# Public macOS regression: synthetic settings, no credentials, provisioning or upload.
set +x
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'Archive regression requires macOS and Xcode.' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/arrivau-archive-scoping.XXXXXX")"
STAGE=preparing_synthetic_configuration
cleanup() {
  status=$?
  trap - EXIT
  if [[ "$status" != 0 ]]; then
    printf 'Archive scoping regression failed during %s.\n' "$STAGE" >&2
    if [[ -f "$WORK/archive.log" ]]; then
      python3 "$ROOT/scripts/archive-diagnostics.py" "$WORK/archive.log"
    elif [[ -f "$WORK/settings.log" ]]; then
      python3 "$ROOT/scripts/archive-diagnostics.py" "$WORK/settings.log"
    fi
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export ARRIVAU_TEAM_ID=ABCDEFGHIJ ARRIVAU_BUNDLE_ID=com.example.arrivau.archivecheck
export ARRIVAU_API_URL=https://pilot.example.com
ARRIVAU_GOOGLE_MAPS_API_KEY=synthetic-google-key-never-valid-12345 \
  python3 "$ROOT/scripts/navigation-config.py" --configuration Release --output "$WORK/Info.plist"
unset ARRIVAU_GOOGLE_MAPS_API_KEY
ARRIVAU_ARCHIVE_PROFILE_UUID=12345678-1234-1234-1234-123456789ABC \
  ARRIVAU_ARCHIVE_IDENTITY=1111111111111111111111111111111111111111 \
  ARRIVAU_ARCHIVE_KEYCHAIN="$WORK/nonexistent-synthetic.keychain-db" \
  python3 "$ROOT/scripts/archive-config.py" --manual-signing --build-number 314 \
  --info-plist "$WORK/Info.plist" --output "$WORK/project.json"
STAGE=generating_private_project
xcodegen generate --no-env --spec "$WORK/project.json" --project-root "$ROOT/ios" --project "$WORK"
# Resolve actual target settings with signing enabled. No signing is attempted.
STAGE=resolving_target_settings
xcodebuild -project "$WORK/Arrivau.xcodeproj" -alltargets -configuration Release -sdk iphoneos \
  -showBuildSettings -json > "$WORK/settings.json" 2> "$WORK/settings.log"
STAGE=verifying_target_settings
python3 "$ROOT/scripts/verify-archive-scoping.py" settings "$WORK/settings.json" "$WORK/project.json"
# This one public test is intentionally unsigned. The real signing workflow has
# no global CODE_SIGNING_ALLOWED override, and still strictly verifies signatures.
STAGE=archiving_unsigned_release
xcodebuild archive -project "$WORK/Arrivau.xcodeproj" -scheme Arrivau -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$WORK/Arrivau.xcarchive" \
  -derivedDataPath "$WORK/DerivedData" CODE_SIGNING_ALLOWED=NO > "$WORK/archive.log" 2>&1
STAGE=verifying_archived_resources
APP="$WORK/Arrivau.xcarchive/Products/Applications/Arrivau.app"
python3 "$ROOT/scripts/verify-ios-bundle.py" "$APP"
python3 "$ROOT/scripts/verify-archive-scoping.py" bundle "$APP" "$WORK/project.json"
STAGE=verifying_unsigned_privacy_declarations
python3 "$ROOT/scripts/verify-archive-scoping.py" privacy "$APP" "$WORK/project.json"
printf 'Unsigned archive passed with synthetic app settings and uncontaminated Google SDK resources.\n'
