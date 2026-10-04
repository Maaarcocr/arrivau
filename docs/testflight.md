# Archive and TestFlight handoff

**For the Linux owner setup, follow the [GitHub TestFlight checklist](testflight-ci.md).** The rest of this page is a local Xcode reference for developers.

This repository prepares an archive workflow. **Nothing here automatically uploads a build.** Do not put Apple IDs, account passwords, App Store Connect keys, certificates or provisioning profiles in chat or Git. Use Xcode's account UI or a separately approved secure credential setup.

## Prerequisites supplied by the owner

1. An active Apple Developer Program membership and access to its team
2. A unique registered bundle identifier and matching App Store Connect app record
3. Signing configured in Xcode on a Mac, including a suitable local signing identity/provisioning profile. The script does not request automatic credential/profile creation
4. A reachable HTTPS API configured in production mode, individual pilot accounts and a fresh persistent database
5. The beta description/test instructions, feedback contact and test group. Review the privacy manifest/disclosures and the location purpose text against your actual hosting/data practices

As of 4 October 2026, uploads must be built with Xcode 26+ and the iOS 26+ SDK. The deployment target remains iOS 17. The CI image explicitly selects Xcode 26.6. Check Apple's requirements again before uploading: [SDK minimum requirements](https://developer.apple.com/news/upcoming-requirements/?id=04282026a), [upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

## Archive locally (no upload)

Run the API and simulator checks first. Select the appropriate Xcode installation and install XcodeGen. These settings are not secrets:

```sh
export ARRIVAU_API_URL='https://YOUR-PILOT-DOMAIN'
export ARRIVAU_TEAM_ID='YOURTEAMID'
export ARRIVAU_BUNDLE_ID='com.YOURORG.arrivau'
export ARRIVAU_BUILD_NUMBER='1'
./scripts/archive-ios.sh
```

Replace all placeholders, including the ten-character team ID. The script rejects the default development bundle ID and requires a new positive build number. It verifies a HTTPS root origin, checks Xcode/SDK versions, generates the project and archives the Release configuration for a generic physical iOS device. It does not add `-allowProvisioningUpdates`, sign in, create credentials, export, upload or enroll testers. If signing is not ready, configure it deliberately in Xcode then rerun with a fresh build number.

Marketing version defaults to `0.2.0`; increase the integer build number for each upload. The archive is under `ios/build/Arrivau-N.xcarchive`. For direct development installation instead, generate `ios/Arrivau.xcodeproj`, select the real team and bundle ID in Xcode, choose the phone and run. Device Developer Mode/trust/signing steps are performed on the owner's devices.

## Explicit upload when authorized

Open the archive in Xcode Organizer. Review the bundle ID, team, version, deployment target, privacy report and embedded HTTPS endpoint. Choose **Validate App**, resolve all findings, and then explicitly choose **Distribute App → App Store Connect → Upload** when you intend to send that binary to Apple. Follow Apple's current Organizer choices if their labels differ. Uploading is separate from releasing publicly.

Wait for App Store Connect processing. Resolve export-compliance/privacy questions based on the actual build and operator's usage; the repository intentionally does not pre-answer them. Add the processed build to the intended TestFlight group. External testing can require Beta App Review; internal testers must be eligible App Store Connect users. Check current Apple instructions: [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).

No signed archive or successful Apple upload has been established merely by an unsigned CI build. After processing, install through TestFlight on both pilot phones and complete the [physical-device checklist](pilot-runbook.md#6-required-interruptiondevice-checks).

## Future assisted publishing

Assisted upload can use a connected Mac with Xcode and secure Apple setup, or a separately approved CI-signing setup. Team access, credentials and each consequential upload must be explicitly configured/authorized first. The manual CI workflow is prepared in `testflight.yml`, but this change does not create an App Store Connect API key, add repository secrets or run it. Its default is archive-only; see the CI guide for the explicit signing opt-in and upload choice. Avoid adding persistent Apple credentials until the chosen upload route is clear.
