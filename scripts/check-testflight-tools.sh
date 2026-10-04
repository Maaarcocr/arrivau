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
# Exercise codesign's optional-argument syntax on an existing Apple-signed binary,
# without creating a signature or loading owner-supplied signing assets.
APPLE_TOOL="$(xcrun --find xcodebuild 2>"$TMP/codesign.txt")" || {
  echo 'Could not locate the installed Apple-signed Xcode tool.' >&2; exit 1;
}
if ! codesign --display "--extract-certificates=$TMP/cert-" "$APPLE_TOOL" >>"$TMP/codesign.txt" 2>&1; then
  echo 'Installed codesign could not extract the Apple tool certificate with an explicit prefix.' >&2
  exit 1
fi
[[ -s "$TMP/cert-0" ]] || { echo 'Installed codesign did not create the expected leaf certificate.' >&2; exit 1; }
if ! openssl x509 -inform DER -in "$TMP/cert-0" -noout >>"$TMP/codesign.txt" 2>&1; then
  echo 'Installed codesign leaf certificate is not valid DER.' >&2
  exit 1
fi
echo 'Installed codesign extracted the Apple tool leaf certificate with the required prefix syntax.'
printf 'Pinned Xcode exposes the expected manual-export and API-key upload CLI options; no signing or upload performed.\n'
