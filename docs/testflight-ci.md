# Publish Arrivau to TestFlight from GitHub

Do these steps on Linux. You need OpenSSL, GNU `base64`, and a browser. GitHub's macOS runner builds, signs, and uploads the app. You do not need a Mac or Xcode installed. For later uploads, repeat step 7 with a new build number.

Already done: Apple Developer membership, the Arrivau app record, bundle ID `com.rudilosso.arrivau`, and the API key named **Arrivau TestFlight CI**. Use those existing items.

## 1. Check the workflow is ready

The **Manual TestFlight** workflow is on `main`; [PR #2](https://github.com/Maaarcocr/arrivau/pull/2) is merged. Before uploading, check that the normal CI checks on `main` are green in the repository's **Actions** tab.

## 2. Make the signing files on Linux

If needed, install `openssl` and `coreutils` using your distribution's package manager. Run these commands in your terminal, outside the repository. Do not repeat this block if `distribution.key.pem` already exists.

```sh
umask 077
mkdir -p "$HOME/arrivau-signing"
chmod 700 "$HOME/arrivau-signing"
cd "$HOME/arrivau-signing"
openssl genpkey -algorithm RSA -aes-256-cbc \
  -pkeyopt rsa_keygen_bits:2048 -out distribution.key.pem
openssl req -new -sha256 -key distribution.key.pem \
  -subj "/CN=Arrivau Distribution" -out distribution.certSigningRequest
```

Choose a strong key passphrase when prompted; enter it again for the second command. Save it in your password manager.

1. Open [Apple Developer](https://developer.apple.com/account/) and select team **2R27Z5A8V6**.
2. Go to **Certificates, Identifiers & Profiles → Certificates → +**.
3. Choose **Apple Distribution**, then **Continue**.
4. Upload **distribution.certSigningRequest** from your signing folder, then **Continue** and **Download**.
5. Move the downloaded `.cer` into `~/arrivau-signing` and rename it **distribution.cer**.

The CSR is public and goes to Apple. Keep the original PEM private-key file on Linux. **The P12 contains a copy of that private key and goes into this repository's GitHub Actions secrets so its macOS runner can sign the app.**

Make the password-protected `.p12` that GitHub needs:

```sh
umask 077
cd "$HOME/arrivau-signing"
openssl x509 -inform DER -in distribution.cer -out distribution.cert.pem
openssl pkcs12 -export -inkey distribution.key.pem -in distribution.cert.pem \
  -name "Arrivau Apple Distribution" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -out distribution.p12
```

Enter the key passphrase, then choose a strong, nonempty **Export Password**. Save that export password: it becomes `APPLE_DISTRIBUTION_P12_PASSWORD` in step 5.

Check the P12 locally with `openssl pkcs12 -in distribution.p12 -info -noout`, entering its export password. It must finish without an error; this does not test Apple's import yet.

The explicit P12 options use older container encryption for Apple's import compatibility; keep the file private. A `.cer` alone will not work. [OpenSSL options](https://docs.openssl.org/3.5/man1/openssl-pkcs12/) · [Apple compatibility guidance](https://developer.apple.com/forums/thread/723242)

## 3. Create the matching provisioning profile

1. Open [Apple Developer](https://developer.apple.com/account/) with the same team.
2. Go to **Certificates, Identifiers & Profiles → Profiles → +**.
3. Under **Distribution**, select **App Store Connect**, then **Continue**.
4. Select the existing App ID whose bundle ID is **com.rudilosso.arrivau**, then **Continue**.
5. Select the **Apple Distribution certificate you created in step 2**, then **Continue**.
6. Name the profile **Arrivau TestFlight CI**, click **Generate**, then **Download**.
7. Move the downloaded `.mobileprovision` file into `~/arrivau-signing` and rename it **profile.mobileprovision**.

This profile must match both the app and the certificate. [Apple's profile instructions](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/)

## 4. Download the API key that already exists

1. Open [App Store Connect](https://appstoreconnect.apple.com/).
2. Go to **Users and Access → Integrations → App Store Connect API → Team Keys**.
3. Find **Arrivau TestFlight CI**, key ID **AF34359496**.
4. Click **Download API Key** and confirm the download.
5. Move **AuthKey_AF34359496.p8** into `~/arrivau-signing`.

Apple allows one download. Keep a secure backup of this key and the password-protected `.p12`; do not send either file or the password in chat, and never commit them. [Apple API key guidance](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)

## 5. Add six GitHub secrets

Open the [Arrivau repository](https://github.com/Maaarcocr/arrivau), then **Settings → Secrets and variables → Actions → Secrets → New repository secret**.

On Linux, create three private text files. These commands do not print their contents:

```sh
umask 077
cd "$HOME/arrivau-signing"
chmod 600 distribution.p12 profile.mobileprovision AuthKey_AF34359496.p8
base64 -w0 distribution.p12 > distribution.p12.b64
base64 -w0 profile.mobileprovision > profile.mobileprovision.b64
base64 -w0 AuthKey_AF34359496.p8 > api-key.b64
```

Open each `.b64` file in a **local text editor**, copy its entire contents, and paste into the matching GitHub secret. Enter each name exactly, then click **Add secret**:

| Secret name | Value |
| --- | --- |
| `APPLE_DISTRIBUTION_P12_BASE64` | Contents of `distribution.p12.b64` |
| `APPLE_APP_STORE_PROFILE_BASE64` | Contents of `profile.mobileprovision.b64` |
| `ASC_PRIVATE_KEY_BASE64` | Contents of `api-key.b64` |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | The exact export password from step 2 |
| `ASC_KEY_ID` | `AF34359496` |
| `ASC_ISSUER_ID` | `df98e0f8-a632-4d80-913d-df129f32b12b` |

Base64 is still secret data. Paste it only into GitHub's secret fields, never chat or an online encoder/editor. Use **repository secrets**, not environment secrets. Afterward, copy harmless text to replace the clipboard contents and delete the three temporary `.b64` files. Keep your signing files securely backed up. [GitHub's secret setup instructions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)

## 6. Add four GitHub variables

On the same **Actions** settings page, select **Variables → New repository variable**. Add exactly:

| Variable name | Value |
| --- | --- |
| `ARRIVAU_TEAM_ID` | `2R27Z5A8V6` |
| `ARRIVAU_BUNDLE_ID` | `com.rudilosso.arrivau` |
| `ARRIVAU_API_URL` | `https://arrivau.rudilosso.com` |
| `TESTFLIGHT_SIGNING_ENABLED` | `true` |

Leave `TESTFLIGHT_REQUIRE_ENVIRONMENT_APPROVAL` unset.

## 7. Tell GitHub to publish the build

In the repository, open **Actions → Manual TestFlight → Run workflow**.

Set:
- **Branch:** `main`
- **action:** `upload`
- **build_number:** `1` for the first upload; use a new higher integer for every later upload, up to `9999`

Click **Run workflow** and wait for it to succeed. Select **upload** explicitly: the default **archive** only checks signing and does not publish.

GitHub builds and uploads Arrivau version **0.2.0** to Apple. A green run means the upload command succeeded; Apple still needs to process the build.

## 8. Install it through TestFlight

1. Open [Arrivau → TestFlight](https://appstoreconnect.apple.com/teams/df98e0f8-a632-4d80-913d-df129f32b12b/apps/6819019743/testflight) and wait for the new build to finish processing.
2. If Apple shows **Missing Compliance**, open it and answer the encryption questions accurately.
3. Click **+** beside **Internal Testing**, create a group named **Arrivau**, and open it.
4. Click **Add Builds**, select the new build, click **Next**, fill in **What to Test**, and click **Add**.
5. Click **Invite Testers**, select your own App Store Connect account, then **Add**.
6. Install **TestFlight** from the iPhone App Store, accept the invitation, and tap **Install** for Arrivau.

Done when Arrivau installs from TestFlight on your iPhone. [Apple's internal-testing instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)

If a GitHub run fails, share its run link and failing step name. Keep private keys, passwords, and encoded files out of messages.

_Checked against PR #2 at commit `cc12b0dd093295972ca9f835a2e820090602d093`, 4 October 2026._
