# Manual TestFlight from GitHub-hosted macOS

This route uses GitHub's Mac runner; you do **not** need a connected Mac to run the build. An owner must still provide valid Apple signing assets and deliberately configure the repository. Nothing in this change creates credentials, sets secrets, accepts agreements or uploads a build.

The workflow is `.github/workflows/testflight.yml`. It runs **only by manual dispatch from `main`**, defaults to `archive`, and requires the separate repository opt-in `TESTFLIGHT_SIGNING_ENABLED=true`. Selecting `upload` explicitly authorizes that run to send its new build to App Store Connect; it does not enroll testers or release the app publicly. An `archive` run validates signed packaging and then deletes its temporary archive/IPA; no signed binary artifact is retained.

## 1. Owner prerequisites

- Apple Developer Program membership (owner reports it acquired), access to the correct team and its ten-character team ID
- A registered explicit App ID/bundle identifier, with a matching App Store Connect app record
- A valid **Apple Distribution** signing certificate **and its private key**, exported together as a password-protected `.p12`
- An **App Store Connect distribution** provisioning profile for that exact app/team and certificate. Development, ad hoc/device-list, wildcard and enterprise profiles are rejected
- For `upload` only: an App Store Connect **team API key** `.p8`, key ID and issuer ID. Developer is the least upload role listed by Apple; do not grant Admin just for this workflow. Team API keys cannot be restricted to a single app and cover all apps in the account within their role, so review that access before creating one
- The intended HTTPS API origin. `https://arrivau.rudilosso.com` is the proposed deployment origin, **not a verified live service**. Complete the backend HTTPS/health/auth checks before inviting testers

Apple instructions: [certificate overview](https://developer.apple.com/help/account/certificates/certificates-overview/), [App Store provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/), [App Store Connect API access](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/). Creating these credentials is a separate owner-controlled security action. Do not send the private key, `.p12`, password or `.p8` in chat or commit them.

### If you do not already have a `.p12` and do not have a Mac

An exportable certificate/private-key pair is required; an Apple account alone is insufficient, and a cloud-managed certificate without an exportable key is not a `.p12`. You can prepare a standard PKCS#10 CSR with trusted OpenSSL on your own Linux/Windows computer, submit **only the CSR** through Apple's Certificates page, then package the downloaded public certificate with your locally retained private key. This is a manual alternative to Apple's [Keychain Access CSR instructions](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request).

These commands are **for the owner to run later**, in a private directory outside the repository, after choosing to create signing credentials. They have not been run by this task. Passwords are requested interactively:

```sh
umask 077
mkdir arrivau-signing
cd arrivau-signing
openssl genpkey -algorithm RSA -aes-256-cbc -pkeyopt rsa_keygen_bits:2048 -out distribution.key.pem
openssl req -new -key distribution.key.pem -out distribution.certSigningRequest
```

In Apple Developer → Certificates, create an Apple Distribution certificate using `distribution.certSigningRequest`; download its `.cer` into that private directory. Keep the private `.key.pem` local. Then:

```sh
openssl x509 -inform DER -in distribution.cer -out distribution.cert.pem
openssl pkcs12 -export -inkey distribution.key.pem -in distribution.cert.pem -name 'Arrivau Apple Distribution' -out distribution.p12
```

OpenSSL 3 uses newer PKCS#12 encryption defaults, and Apple import compatibility can vary. If CI fails specifically while importing the certificate, first verify the P12 password and certificate/private-key pair locally. For an identified MAC-verification compatibility error, an owner can make a separately named compatibility export with OpenSSL 3 using `openssl pkcs12 -export -legacy -descert -inkey distribution.key.pem -in distribution.cert.pem -out distribution-legacy.p12`, then securely replace the P12 secret. This uses older encryption for the transfer container; keep it password-protected and short-lived. Do not assume every import failure is this issue or print private material to diagnose it. References: [Apple DTS compatibility discussion](https://developer.apple.com/forums/thread/723242), [OpenSSL PKCS#12 options](https://docs.openssl.org/3.5/man1/openssl-pkcs12/).

Protect and back up the encrypted key/P12 and its password in your password manager. Generate the App Store profile in Apple's portal using the same certificate and bundle ID. If Apple's account role or certificate limits block creation, resolve those in the owner account; do not revoke an existing certificate blindly. The first signed CI run is still required to verify certificate/profile compatibility and trust chain.

## 2. Minimal repository setup

In this repository, open **Settings → Secrets and variables → Actions**. Store credentials as **repository Actions secrets**, not source files or ordinary variables. Base64 is encoding, not encryption; its output must go directly into the corresponding secret. GitHub's [secrets instructions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets) cover secure browser entry and `gh secret set NAME < file`.

Required secrets for `archive` and `upload`:

| Name | Value |
| --- | --- |
| `APPLE_DISTRIBUTION_P12_BASE64` | Base64 of the certificate plus private key `.p12` |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | Its nonempty export password |
| `APPLE_APP_STORE_PROFILE_BASE64` | Base64 of the matching `.mobileprovision` |

Additional secrets required only for `upload`:

| Name | Value |
| --- | --- |
| `ASC_PRIVATE_KEY_BASE64` | Base64 of the team API private key `.p8` |
| `ASC_KEY_ID` | Its Apple key identifier |
| `ASC_ISSUER_ID` | Its issuer UUID |

Base64-encode locally with a trusted tool without pasting output into chat; GitHub secrets have a 48 KiB value limit. The app's simple App Store profile should normally fit. Do not work around a size limit by committing signing material. Remove local transfer copies after secure storage, according to your backup policy.

Set these **repository Actions variables** (non-secret):

| Name | Value |
| --- | --- |
| `ARRIVAU_TEAM_ID` | Actual ten-character team ID |
| `ARRIVAU_BUNDLE_ID` | Your registered app identifier, replacing `dev.arrivau.app` |
| `ARRIVAU_API_URL` | Verified HTTPS root origin, without a path/query/userinfo |
| `TESTFLIGHT_SIGNING_ENABLED` | `true` only after the setup and access review are complete |
| `TESTFLIGHT_REQUIRE_ENVIRONMENT_APPROVAL` | Optional; see the next section |

The baseline uses repository secrets and does not require Enterprise environments. Private-repository Actions usage/minutes and spending limits still apply. Limit repository write/admin access to trusted people: anyone able to change workflows can potentially access repository secrets. Protect `main` and workflow/script changes where your plan supports it; manual dispatch is not a substitute for repository access control.

## 3. Optional environment approval gate

If your GitHub plan supports it, first create an environment named `testflight`, restrict deployments to `main`, configure actual required reviewers and the intended bypass/self-review policy, then set repository variable `TESTFLIGHT_REQUIRE_ENVIRONMENT_APPROVAL=true`.

The workflow's approval-only job must succeed before signing starts. This optional gate **does not isolate the repository secrets inside the environment**. Naming an environment does not create a required-reviewer rule; without an actual rule GitHub can start the job immediately. Configure and verify the rule before enabling this option. Do not enable an unsupported gate and expect a prompt.

GitHub currently limits required-reviewer environment gates for private repositories to Enterprise; private environment secrets require Pro/Team/Enterprise. Repository Actions secrets are the baseline here. Do not change repository visibility or buy a plan just to use this prototype without a separate decision. See [GitHub environment availability and protections](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).

## 4. First run: signed archive validation

After this follow-on PR is reviewed and merged:

1. Confirm `main` points to the code you intend to sign and its ordinary verification CI is green
2. Open **Actions → Manual TestFlight → Run workflow** and select branch `main`
3. Select action **archive** and supply a new integer build number from `1` to `9999`. The marketing version remains `0.2.0`; each uploaded build must have a new number
4. If enabled, approve the configured environment gate after checking the source SHA and action
5. Inspect the result. The workflow validates inputs and profile metadata, imports the supplied signing identity into a temporary keychain, builds and verifies a Release archive, and exports an App Store IPA. Cleanup runs on normal exits, failures and handled cancellation; no credentials or binaries are uploaded as artifacts. Hard runner termination can prevent cleanup hooks, with destruction of the GitHub-hosted ephemeral VM as the final boundary

A passing `archive` run establishes that the provided signing assets work in CI; it is not an upload or physical-device result. No Apple credential/profile creation or automatic provisioning is requested. A failure reports a non-sensitive stage; review signing assets through their secure account/settings locations rather than posting credentials in an issue.

## 5. Upload only when explicitly ready

Run the same workflow from `main` with action **upload** and a fresh build number. This rebuilds/signs/verifies and then invokes Apple's uploader using the supplied API key. It does not run on PRs or pushes, and an `archive` run never uploads. Upload sends the signed app and its embedded endpoint/metadata to Apple.

A successful uploader response means Apple accepted the transfer, not that processing or beta review is complete. Check the App Store Connect build, answer export-compliance/privacy questions accurately, supply beta test instructions/contact, and add the build to the intended TestFlight group. External testing may need Beta App Review. Then test on both physical iPhones, including signed Keychain persistence and locked/background location. Apple: [upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) and [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).

## Verification boundary

This workflow and its scripts can be checked statically and with a fake-tool test harness without exposing real credentials. Those checks do not prove Apple signing, API permissions, certificate trust, upload, processing or device behavior. Until an owner-configured `archive` and then authorized `upload` have succeeded, describe this as **prepared CI signing/upload code**, not a published app.
