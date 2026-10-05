# Reviewed Google privacy manifest fixtures

These are the byte-exact `PrivacyInfo.xcprivacy` files fetched on 2026-10-05
from Google's official Swift Package Manager repositories at tag `11.2.0`.
The tests verify both SHA-256 and the Git blob object ID. They also verify that
the audit script's embedded canonical declarations agree with these fixtures.
Updating a Google SDK requires reviewing its vendor manifests and updating the
fixtures and canonical baseline together; the audit never fetches a new baseline
or trusts an arbitrary runtime SDK version.

| Component | Official source | Git blob ID | SHA-256 |
| --- | --- | --- | --- |
| GoogleNavigation | [11.2.0 resource manifest](https://github.com/googlemaps/ios-navigation-sdk/blob/11.2.0/Navigation/Resources/GoogleNavigationResources/GoogleNavigation.bundle/PrivacyInfo.xcprivacy) | `c7f16689430f2bf1a3b09c2181d867f8b50d4071` | `77a15a98ef432867b009b022c1733ede2a5a45261cb89bbda755ef147ea9700a` |
| GoogleMaps | [11.2.0 resource manifest](https://github.com/googlemaps/ios-maps-sdk/blob/11.2.0/Maps/Resources/GoogleMapsResources/GoogleMaps.bundle/PrivacyInfo.xcprivacy) | `9950df78f6c02c0c9ed8bbff8a624ce225517b30` | `47734417f3f8617743fdfa6efdda9df04664f8a91519ff22208df9f022598501` |
| GooglePlaces | [11.2.0 resource manifest](https://github.com/googlemaps/ios-places-sdk/blob/11.2.0/Places/Resources/GooglePlacesResources/GooglePlaces.bundle/PrivacyInfo.xcprivacy) | `73d4dc4932313526885605e3c48239266293fad8` | `e9d54ec15e10d13d97c44c262d315cf88a206f15a44c37f6c4d424189bcf28c5` |

The sibling `arrivau-privacy/PrivacyInfo.xcprivacy` fixture is the app manifest
from Arrivau commit `2727f2af3eedf661795a2e465ad90af2ca63c1c1` (Git blob
`e39da3550c8836c2c2d543ba4c9f52a2a55edcc6`). It is only an offline test fixture;
the audit reads the actual app root manifest in both built artifacts.

## Apple schema references

Reviewed on 2026-10-05:

- [Privacy tracking](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacytracking): missing `NSPrivacyTracking` defaults to false
- [Collected data categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)
- [Collection purposes](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatypepurposes)
- [Required API categories and approved reason codes](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [TN3181: invalid manifest diagnostics](https://developer.apple.com/documentation/technotes/tn3181-debugging-invalid-privacy-manifest)
- [TN3184: data collection dictionaries](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest)

## Audit invocation contract

Python 3.9+ standard library only; macOS and Linux are supported. Run after
archive/export signature verification and before upload or private cleanup:

```sh
python3 scripts/audit-privacy-manifests.py \
  --archive-app "$ARCHIVE_PATH/Products/Applications/Arrivau.app" \
  --ipa "$IPA_PATH" \
  --output "$RETAINED_JSON_PATH" \
  --commit-sha "$GITHUB_SHA" \
  --run-id "$GITHUB_RUN_ID" \
  --run-attempt "$GITHUB_RUN_ATTEMPT" \
  --build-number "$ARRIVAU_BUILD_NUMBER"
```

The JSON destination must be new, have a `.json` suffix, and be outside the
archived app. All identifiers are mandatory: commit SHA is 40 hexadecimal
characters, run ID is 1–20 decimal digits, run attempt is 1–6 decimal digits,
and build number is 1–9999 (no leading zeroes). Supply identifiers from the
verified build workflow; the auditor validates their format, not their external
provenance, and never reads the process environment.

Exit 0 writes the complete report with mode 0600. Exit 1 emits only a fixed
diagnostic, without echoing invalid values, paths, domains, or parser exceptions.
No new output is retained on failure. Never reuse an existing output path or
upload a stale report. The caller owns artifact retention and the normal private
archive/IPA cleanup; the auditor neither uploads nor retains those binaries.

The audit requires the app root and at least one manifest directly inside each
of `GoogleNavigation.bundle`, `GoogleMaps.bundle`, and `GooglePlaces.bundle`.
SPM wrapper directories are allowed. Multiple copies are included and each must
match the reviewed declaration. Every additional manifest is validated and
reported with a fixed generic component label; unknown keys, categories,
purposes and reason codes fail closed. Archive and export must contain the same
relative manifest inventory and semantic declarations, including domain values.
Serialization changes (XML/binary, array order) are permitted and each artifact's
actual manifest SHA-256 is retained. Raw tracking domains and private paths
never appear in the report. No aggregate union is reported.

Only manifest payloads are opened from the app and IPA; non-manifest ZIP members
are not opened or extracted. It reads no Info.plist, signing profile, key file,
app binary, environment, or private log. The signed archive and IPA still require
the caller's existing signing verification. This is a **Signed bundle privacy
manifest audit**, not an Xcode Privacy Report, a binary behavioral analysis,
proof of privacy-label accuracy, or legal certification. Actual signed execution
is needed to confirm final Xcode packaging; the tests use synthetic bundles.

Offline checks:

```sh
python3 -m unittest discover -s scripts -p 'test_audit_privacy_manifests.py' -v
```
