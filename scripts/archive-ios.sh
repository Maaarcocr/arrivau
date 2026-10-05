#!/usr/bin/env bash
# Archive only. This script does not upload, create an Apple account or install credentials.
set +x
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
python3 scripts/validate-pilot-config.py
[[ "$(uname -s)" == "Darwin" ]] || { echo 'Archiving requires a Mac with Xcode 26+.' >&2; exit 1; }
for tool in xcodegen xcodebuild xcrun; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
XCODE_MAJOR="$(xcodebuild -version | head -1 | awk '{print $2}' | cut -d. -f1)"
SDK_MAJOR="$(xcrun --sdk iphoneos --show-sdk-version | cut -d. -f1)"
[[ "$XCODE_MAJOR" -ge 26 && "$SDK_MAJOR" -ge 26 ]] || { echo 'Select Xcode 26+ and iOS SDK 26+ before archiving.' >&2; exit 1; }
CONFIG_WORK="$(mktemp -d "${TMPDIR:-/tmp}/arrivau-navigation.XXXXXX")"
trap 'rm -rf "$CONFIG_WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 scripts/navigation-config.py --configuration Release --output "$CONFIG_WORK/Info-Navigation.plist"
# Keep key contents out of Xcode's command-line/build-setting diagnostics.
unset ARRIVAU_GOOGLE_MAPS_API_KEY
python3 scripts/archive-config.py --build-number "$ARRIVAU_BUILD_NUMBER" \
  --info-plist "$CONFIG_WORK/Info-Navigation.plist" --output "$CONFIG_WORK/project.json"
xcodegen generate --no-env --spec "$CONFIG_WORK/project.json" --project-root "$ROOT/ios" --project "$CONFIG_WORK"
ARCHIVE="$ROOT/ios/build/Arrivau-${ARRIVAU_BUILD_NUMBER}.xcarchive"
[[ ! -e "$ARCHIVE" ]] || { echo "Archive already exists: $ARCHIVE. Choose a new build number." >&2; exit 1; }
xcodebuild archive \
  -project "$CONFIG_WORK/Arrivau.xcodeproj" -scheme Arrivau -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE"
python3 scripts/verify-ios-bundle.py "$ARCHIVE/Products/Applications/Arrivau.app"
printf '\nArchive created at %s\nOpen it in Xcode Organizer, validate, then explicitly choose upload when ready.\n' "$ARCHIVE"

