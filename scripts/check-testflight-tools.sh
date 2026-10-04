#!/usr/bin/env bash
# Read-only Xcode CLI compatibility check. No credentials, signing or upload.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Apple CLI inspection requires macOS.' >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/arrivau-apple-tools.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
xcodebuild -help >"$TMP/xcodebuild.txt" 2>&1
xcrun altool --help >"$TMP/altool.txt" 2>&1
for option in -archivePath -exportArchive -exportOptionsPlist app-store-connect signingStyle provisioningProfiles manageAppVersionAndBuildNumber; do
  grep -q -- "$option" "$TMP/xcodebuild.txt" || { echo "Xcode CLI lacks required documented option: $option" >&2; exit 1; }
done
grep -q -- '--upload-app' "$TMP/altool.txt" || { echo 'Apple upload CLI lacks upload-app.' >&2; exit 1; }
if grep -q -- '--api-key' "$TMP/altool.txt" && grep -q -- '--api-issuer' "$TMP/altool.txt"; then
  echo 'Apple upload CLI advertises current API-key flags.'
elif grep -q -- '--apiKey' "$TMP/altool.txt" && grep -q -- '--apiIssuer' "$TMP/altool.txt"; then
  echo 'Apple upload CLI advertises legacy-compatible API-key flags.'
else
  echo 'Apple upload CLI lacks the expected API-key authentication flags.' >&2
  exit 1
fi
printf 'Pinned Xcode exposes the expected manual-export and API-key upload CLI options; no signing or upload performed.\n'
