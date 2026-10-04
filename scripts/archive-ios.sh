#!/usr/bin/env bash
# Archive only. This script does not upload, create an Apple account or install credentials.
set -euo pipefail
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
(cd ios && xcodegen generate)
ARCHIVE="$ROOT/ios/build/Arrivau-${ARRIVAU_BUILD_NUMBER}.xcarchive"
[[ ! -e "$ARCHIVE" ]] || { echo "Archive already exists: $ARCHIVE. Choose a new build number." >&2; exit 1; }
xcodebuild archive \
  -project ios/Arrivau.xcodeproj -scheme Arrivau -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$ARRIVAU_TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$ARRIVAU_BUNDLE_ID" \
  CURRENT_PROJECT_VERSION="$ARRIVAU_BUILD_NUMBER" \
  ARRIVAU_API_URL="$ARRIVAU_API_URL"
python3 scripts/verify-ios-bundle.py "$ARCHIVE/Products/Applications/Arrivau.app"
printf '\nArchive created at %s\nOpen it in Xcode Organizer, validate, then explicitly choose upload when ready.\n' "$ARCHIVE"
