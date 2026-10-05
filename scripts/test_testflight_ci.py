"""Offline safety tests; never invoke real Apple tools or use signing credentials.

Run with ``python3 -m unittest discover -s scripts -p 'test_testflight_ci.py'``.
The integration harness executes the real shell/Python orchestration in a copied
temporary repository. Every Apple/build/signing command is a fake executable;
its certificate, key, profile, app and IPA are deliberately synthetic fixtures.
Passing these tests does not establish Apple signing, upload or device success.
"""

import base64
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/testflight-ci.sh"
WORKFLOW = ROOT / ".github/workflows/testflight.yml"
BASH = shutil.which("bash")
TEAM = "ABCDEFGHIJ"
BUNDLE = "com.example.arrivau"
UUID = "12345678-1234-1234-1234-123456789ABC"
CERTIFICATE = b"FAKE-CERTIFICATE-NOT-DER-NO-PRIVATE-KEY"
FINGERPRINT = hashlib.sha1(CERTIFICATE).hexdigest().upper()
TOOL_OUTPUT = "PRIVATE-TOOL-DIAGNOSTIC-MUST-NOT-REACH-OUTPUT"
CONFIG = {
    "ARRIVAU_TEAM_ID": TEAM,
    "ARRIVAU_BUNDLE_ID": BUNDLE,
    "ARRIVAU_API_URL": "https://pilot.example.com",
}
spec = importlib.util.spec_from_file_location("testflight_signing", ROOT / "scripts/testflight-signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


def profile_fixture():
    return {
        "UUID": UUID,
        "Name": "Synthetic App Store profile",
        "ExpirationDate": dt.datetime.now(dt.timezone.utc).replace(tzinfo=None) + dt.timedelta(days=30),
        "TeamIdentifier": [TEAM],
        "ApplicationIdentifierPrefix": [TEAM],
        "Platform": ["iOS"],
        "DeveloperCertificates": [CERTIFICATE],
        "Entitlements": {
            "application-identifier": f"{TEAM}.{BUNDLE}",
            "com.apple.developer.team-identifier": TEAM,
            "get-task-allow": False,
            "beta-reports-active": True,
        },
    }


# This runs under an absolute Python interpreter. There is no fallback to a real
# Apple command: PATH contains only these fakes and explicitly allowed utilities.
FAKE_TOOL = r'''
import hashlib, json, os, pathlib, plistlib, shlex, sys, zipfile
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["FAKE_ROOT"])
with (root / "calls.jsonl").open("a") as output:
    output.write(json.dumps([name, *args]) + "\n")
profile_bytes = (root / "fixture.plist").read_bytes()
profile = plistlib.loads(profile_bytes)
certificate = profile["DeveloperCertificates"][0]
fingerprint = hashlib.sha1(certificate).hexdigest().upper()
marker = "PRIVATE-TOOL-DIAGNOSTIC-MUST-NOT-REACH-OUTPUT"
stage = name + (":" + args[0] if args else "")
if name == "xcrun" and "--upload-app" in args:
    stage = "xcrun:upload"
operation = stage
if name == "codesign" and "--display" in args:
    if "--entitlements" in args:
        operation = "codesign:entitlements"
    elif "--verbose=4" in args:
        operation = "codesign:metadata"
    elif any(arg.startswith("--extract-certificates") for arg in args):
        operation = "codesign:certificates"
elif name == "security" and args[0] == "cms" and args[-1].endswith("embedded.mobileprovision"):
    operation = "security:embedded-profile"
product = "export" if any("/unpacked/" in arg for arg in args) else "archive"
if (os.environ.get("FAKE_FAIL_AT") in (stage, operation)
        and os.environ.get("FAKE_FAIL_PRODUCT", product) == product):
    print(marker, file=sys.stderr)
    if stage == "xcodebuild:archive":
        print(os.environ.get("FAKE_ARCHIVE_ERROR", ""), file=sys.stderr)
    sys.exit(42)

def value(flag):
    return args[args.index(flag) + 1]

def make_app(app):
    app.mkdir(parents=True)
    info = {
        "CFBundleExecutable": "Arrivau", "UIDeviceFamily": [1],
        "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}},
        "CFBundleIdentifier": os.environ["ARRIVAU_BUNDLE_ID"],
        "CFBundleVersion": os.environ["FAKE_BUILD_NUMBER"],
        "CFBundleShortVersionString": "0.2.0",
        "ITSAppUsesNonExemptEncryption": False,
        "ARRIVAU_API_URL": os.environ["ARRIVAU_API_URL"],
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
    }
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    binary = b"demo-dispatcher" if os.environ.get("FAKE_INVALID_BUNDLE") else b"synthetic release executable"
    (app / "Arrivau").write_bytes(binary)
    (app / "Assets.car").write_bytes(b"synthetic compiled assets")
    (app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({"NSPrivacyTracking": False}))
    for sdk in ("GoogleMaps", "GooglePlaces", "GoogleNavigation"):
        resource = app / (sdk + "_" + sdk + "Target.bundle") / (sdk + ".bundle")
        resource.mkdir(parents=True)
        manifest = root / "repo/scripts/tests/fixtures/google-privacy-11.2.0" / sdk / "PrivacyInfo.xcprivacy"
        (resource / "PrivacyInfo.xcprivacy").write_bytes(manifest.read_bytes())
    (app / "embedded.mobileprovision").write_bytes(profile_bytes)

if name == "uname":
    print("Darwin")
elif name == "git":
    assert args == ["rev-parse", "HEAD"]
    print("a" * 40)
elif name == "openssl":
    if args == ["rand", "-hex", "32"]:
        print("1" * 64)
    elif args[0] == "x509":
        assert args[1:3] == ["-inform", "DER"] and args[-1] == "-noout"
        assert pathlib.Path(value("-in")).read_bytes() == certificate
        print(marker)
    else:
        assert args[0] == "pkey" and "-check" in args and "-noout" in args
        assert pathlib.Path(value("-in")).read_bytes() == b"FAKE-API-PRIVATE-KEY-NOT-A-KEY"
        print(marker)
elif name == "security":
    if args[0] == "cms":
        sys.stdout.buffer.write(pathlib.Path(value("-i")).read_bytes())
    elif args[0] == "create-keychain":
        pathlib.Path(args[-1]).write_text("fake keychain")
        state = root / "keychains.json"
        state.write_text(json.dumps([args[-1], *json.loads(state.read_text())]))
        print(marker)
    elif args[0] == "find-identity":
        print(f'  1) {fingerprint} "Apple Distribution: Test Fixture ({os.environ["ARRIVAU_TEAM_ID"]})"')
    elif args[0] == "list-keychains":
        state = root / "keychains.json"
        if "-s" in args:
            state.write_text(json.dumps(args[args.index("-s") + 1:]))
        else:
            for path in json.loads(state.read_text()):
                print("    " + json.dumps(path))
    elif args[0] == "delete-keychain":
        pathlib.Path(args[-1]).unlink()
    else:
        assert args[0] in ["set-keychain-settings", "unlock-keychain", "import", "set-key-partition-list"]
        print(marker)
elif name == "xcodegen":
    assert args[0] == "generate" and "--no-env" in args
    overlay_path = pathlib.Path(value("--spec"))
    overlay = json.loads(overlay_path.read_text())
    assert set(overlay) == {"include", "targets"}
    assert set(overlay["targets"]) == {"Arrivau"}
    assert set(overlay["targets"]["Arrivau"]["settings"]["configs"]) == {"Release"}
    assert value("--project-root") == str(root / "repo/ios")
    project = pathlib.Path(value("--project")) / "Arrivau.xcodeproj"
    project.mkdir()
    (project / "synthetic-settings.json").write_text(json.dumps(overlay))
    (root / "archive-config-observed.json").write_text(json.dumps(overlay))
    print(marker)
elif name == "xcodebuild":
    if args == ["-version"]:
        print("Xcode 26.6\nBuild version SYNTHETIC")
    elif args == ["-help"]:
        print("-archivePath -exportArchive -exportOptionsPlist app-store-connect signingStyle provisioningProfiles manageAppVersionAndBuildNumber")
    elif args[0] == "archive":
        overlay = json.loads((pathlib.Path(value("-project")) / "synthetic-settings.json").read_text())
        settings = overlay["targets"]["Arrivau"]["settings"]["configs"]["Release"]
        assert not any(arg.split("=", 1)[0] in settings for arg in args)
        assert settings["CODE_SIGN_STYLE"] == "Manual"
        assert settings["CODE_SIGNING_ALLOWED"] == settings["CODE_SIGNING_REQUIRED"] == "YES"
        assert settings["PROVISIONING_PROFILE_SPECIFIER"] == profile["UUID"]
        assert settings["CODE_SIGN_IDENTITY"] == fingerprint
        navigation_path = settings["INFOPLIST_FILE"]
        navigation = plistlib.loads(pathlib.Path(navigation_path).read_bytes())
        assert "ARRIVAU_GOOGLE_MAPS_API_KEY" not in os.environ
        (root / "navigation-observed.json").write_text(json.dumps({
            "key": navigation["ARRIVAU_GOOGLE_MAPS_API_KEY"],
            "mode": pathlib.Path(navigation_path).stat().st_mode & 0o777,
        }))
        make_app(pathlib.Path(value("-archivePath")) / "Products/Applications/Arrivau.app")
        print(marker)
    else:
        assert args[0] == "-exportArchive"
        options = plistlib.loads(pathlib.Path(value("-exportOptionsPlist")).read_bytes())
        (root / "export-options.json").write_text(json.dumps(options))
        assert options["destination"] == "export" and options["signingStyle"] == "manual"
        source = pathlib.Path(value("-archivePath")) / "Products/Applications"
        export = pathlib.Path(value("-exportPath"))
        export.mkdir()
        with zipfile.ZipFile(export / "Arrivau.ipa", "w") as ipa:
            for item in source.rglob("*"):
                if item.is_file():
                    name = "Payload/" + str(item.relative_to(source))
                    if os.environ.get("FAKE_PRIVACY_MISMATCH") and item.name == "PrivacyInfo.xcprivacy" and item.parent.name == "GoogleMaps.bundle":
                        ipa.writestr(name, plistlib.dumps({"NSPrivacyTracking": False}))
                    else:
                        ipa.write(item, name)
        print(marker)
elif name == "codesign":
    if "--entitlements" in args:
        # Modern codesign only guarantees a machine-readable plist with --xml.
        if "--xml" in args and value("--entitlements") == "-":
            sys.stdout.buffer.write(plistlib.dumps(profile["Entitlements"]))
        else:
            print("[Dict] Human-readable DER entitlements, not a plist")
    elif "--verbose=4" in args:
        print("TeamIdentifier=" + os.environ["ARRIVAU_TEAM_ID"])
    elif any(arg.startswith("--extract-certificates") for arg in args):
        # getopt_long optional arguments do not consume the next token. A separate
        # prefix becomes the first (nonexistent) code path, which fails verification.
        if "--extract-certificates" in args:
            print(marker, file=sys.stderr)
            sys.exit(1)
        prefix = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--extract-certificates="))
        assert args == ["--display", "--extract-certificates=" + prefix, args[-1]]
        assert pathlib.Path(args[-1]).exists()
        leaf = b"WRONG-FAKE-CERTIFICATE" if os.environ.get("FAKE_WRONG_CERT_PRODUCT") == product else certificate
        pathlib.Path(prefix + "0").write_bytes(leaf)
        print(marker)
    else:
        assert args[:3] == ["--verify", "--deep", "--strict"]
        print(marker)
elif name == "ditto":
    assert args[:2] == ["-x", "-k"]
    with zipfile.ZipFile(args[2]) as ipa:
        ipa.extractall(args[3])
    print(marker)
elif name == "xcrun":
    if args == ["--sdk", "iphoneos", "--show-sdk-version"]:
        print("26.6")
    elif args == ["--find", "xcodebuild"]:
        binary = root / "apple-xcodebuild"
        binary.write_bytes(b"synthetic Apple-signed executable")
        print(binary)
    elif args == ["altool", "--help"]:
        style = os.environ.get("FAKE_ALTOOL_STYLE", "legacy")
        print({"legacy": "--upload-app --apiKey --apiIssuer",
               "current": "--upload-app --api-key --api-issuer --platform",
               "unsupported": "--unrecognized-cli"}[style])
    else:
        assert args[:2] == ["altool", "--upload-app"]
        key_flag = "--api-key" if os.environ.get("FAKE_ALTOOL_STYLE") == "current" else "--apiKey"
        key = pathlib.Path("private_keys") / ("AuthKey_" + value(key_flag) + ".p8")
        assert key.read_bytes() == b"FAKE-API-PRIVATE-KEY-NOT-A-KEY"
        assert pathlib.Path(value("-f")).is_file()
        print(marker)
else:
    raise AssertionError("Unexpected fake command: " + name)
'''


class OfflineRunner:
    """A hermetic temporary HOME, repository, PATH and mocked Apple toolchain."""

    def __init__(self, path):
        self.root = Path(path)
        self.repo = self.root / "repo"
        scripts = self.repo / "scripts"
        scripts.mkdir(parents=True)
        (self.repo / "ios/Config").mkdir(parents=True)
        shutil.copy2(ROOT / "ios/Config/Info-Release.plist", self.repo / "ios/Config/Info-Release.plist")
        for name in ("testflight-ci.sh", "testflight-signing.py", "validate-pilot-config.py", "verify-ios-bundle.py", "check-testflight-tools.sh", "navigation-config.py", "archive-config.py", "archive-diagnostics.py", "audit-privacy-manifests.py"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        shutil.copytree(ROOT / "scripts/tests/fixtures/google-privacy-11.2.0",
                        scripts / "tests/fixtures/google-privacy-11.2.0")
        self.home = self.root / "home"
        self.temp = self.root / "runner-temp"
        self.bin = self.root / "bin"
        for folder in (self.home, self.temp, self.bin):
            folder.mkdir()
        self.profile_dir = self.home / "Library/Developer/Xcode/UserData/Provisioning Profiles"
        self.profile_dir.mkdir(parents=True)
        (self.profile_dir / "unrelated.mobileprovision").write_text("preserve unrelated profile")
        self.original_keychains = [str(self.home / "Library/Keychains/login.keychain-db"),
                                   str(self.home / "Library/Keychains/a keychain with spaces.keychain-db")]
        for path in self.original_keychains:
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            Path(path).write_text("preserve original keychain")
        (self.root / "keychains.json").write_text(json.dumps(self.original_keychains))
        profile = plistlib.dumps(profile_fixture())
        (self.root / "fixture.plist").write_bytes(profile)
        for name in ("uname", "git", "openssl", "security", "xcodegen", "xcodebuild", "codesign", "ditto", "xcrun"):
            target = self.bin / name
            target.write_text(f"#!{sys.executable}\n" + FAKE_TOOL)
            target.chmod(0o755)
        for name in ("bash", "dirname", "head", "mkdir", "mktemp", "grep", "rm"):
            target = shutil.which(name)
            if not target:
                raise RuntimeError(f"Required test utility unavailable: {name}")
            (self.bin / name).symlink_to(target)
        (self.bin / "python3").symlink_to(sys.executable)
        self.env = {
            "HOME": str(self.home), "PATH": str(self.bin), "LANG": "C", "LC_ALL": "C",
            "RUNNER_TEMP": str(self.temp), "GITHUB_ENV": str(self.root / "github-env"),
            "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1", "TESTFLIGHT_SIGNING_ENABLED": "true",
            "FAKE_ROOT": str(self.root), "FAKE_BUILD_NUMBER": "17", **CONFIG,
            "APPLE_DISTRIBUTION_P12_BASE64": base64.b64encode(b"FAKE-P12-NOT-A-CERTIFICATE").decode(),
            "APPLE_DISTRIBUTION_P12_PASSWORD": "FAKE-P12-PASSWORD-MUST-STAY-PRIVATE",
            "APPLE_APP_STORE_PROFILE_BASE64": base64.b64encode(profile).decode(),
        }

    def add_upload_secrets(self):
        self.env.update({"ARRIVAU_GOOGLE_MAPS_API_KEY": "synthetic-google-key-never-valid-12345",
                         "ASC_PRIVATE_KEY_BASE64": base64.b64encode(b"FAKE-API-PRIVATE-KEY-NOT-A-KEY").decode(),
                         "ASC_KEY_ID": "KLMNOPQRST", "ASC_ISSUER_ID": "12345678-1234-1234-1234-123456789DEF"})

    def run(self, *args):
        return subprocess.run([BASH, str(self.repo / "scripts/testflight-ci.sh"), *args],
                              env=self.env, cwd=self.repo, capture_output=True, text=True, timeout=30)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def check_tools(self):
        env = {key: value for key, value in self.env.items() if not key.startswith(("APPLE_", "ASC_"))}
        env["TMPDIR"] = str(self.temp)
        return subprocess.run([BASH, str(self.repo / "scripts/check-testflight-tools.sh")],
                              env=env, cwd=self.repo, capture_output=True, text=True, timeout=30)


class WorkflowSafetyTests(unittest.TestCase):
    def test_shell_syntax(self):
        for script in (SCRIPT, ROOT / "scripts/check-testflight-tools.sh", ROOT / "scripts/archive-ios.sh", ROOT / "scripts/test-archive-scoping.sh"):
            with self.subTest(script=script):
                result = subprocess.run([BASH, "-n", str(script)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_manual_default_and_no_binary_artifacts(self):
        text = WORKFLOW.read_text()
        event_block = re.search(r"^on:\n(.*?)(?=^[^\s#])", text, re.MULTILINE | re.DOTALL).group(1)
        self.assertEqual(re.findall(r"^  ([A-Za-z_]+):", event_block, re.MULTILINE), ["workflow_dispatch"])
        self.assertIn("options: [archive, upload]", event_block)
        self.assertIn("default: archive", event_block)
        self.assertIn("contents: read", text)
        self.assertIn("cancel-in-progress: false", text)
        self.assertIn("runs-on: macos-26", text)
        self.assertIn("/Applications/Xcode_26.6.app/Contents/Developer", text)
        self.assertEqual(text.count("uses: actions/upload-artifact@"), 1)
        artifact = text.split("      - name: Retain only the validated privacy declaration summary", 1)[1]
        self.assertIn("path: ${{ env.ARRIVAU_TESTFLIGHT_PRIVACY_AUDIT }}", artifact)
        self.assertIn("if: always() && env.ARRIVAU_TESTFLIGHT_PRIVACY_AUDIT != ''", artifact)
        self.assertIn("if-no-files-found: error", artifact)
        self.assertNotIn("*", artifact)
        self.assertNotIn("${{ runner.temp }}", artifact)
        self.assertNotIn("actions/cache", text)
        self.assertNotIn("pull_request_target", text)
        self.assertIn("persist-credentials: false", text)
        self.assertIn("ref: ${{ github.sha }}", text)
        self.assertRegex(text, r"if: always\(\)\n\s+run: ./scripts/testflight-ci.sh cleanup")

    def test_secrets_are_scoped_after_preflight_and_optional_approval(self):
        text = WORKFLOW.read_text()
        before_signing, signing_job = text.split("\n  signing:", 1)
        self.assertNotIn("${{ secrets.", before_signing)
        self.assertIn("needs: [preflight, approval]", signing_job)
        self.assertIn("needs.preflight.result == 'success'", signing_job)
        self.assertIn("needs.approval.result == 'success'", signing_job)
        self.assertIn("needs.approval.result == 'skipped'", signing_job)
        self.assertIn("environment: testflight", before_signing)
        self.assertIn("if: vars.TESTFLIGHT_REQUIRE_ENVIRONMENT_APPROVAL == 'true'", before_signing)
        for secret in ("ASC_PRIVATE_KEY_BASE64", "ASC_KEY_ID", "ASC_ISSUER_ID"):
            self.assertIn(f"inputs.action == 'upload' && secrets.{secret} || ''", signing_job)
        self.assertIn('./scripts/testflight-ci.sh "$SELECTED_ACTION" "$BUILD_NUMBER"', signing_job)
        # User-controlled workflow values must go through env, never shell interpolation.
        for run in re.findall(r"^\s+run: ([^\n]+)", text, re.MULTILINE):
            self.assertNotIn("${{", run)

    def test_workflow_preflight_rejects_untrusted_or_invalid_requests(self):
        text = WORKFLOW.read_text().split("\n  approval:", 1)[0]
        script = text.split("        run: |\n", 1)[1]
        script = "\n".join(line[10:] for line in script.splitlines() if line.strip())
        valid = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                 "SIGNING_ENABLED": "true", "REQUIRE_APPROVAL": "", "SELECTED_ACTION": "archive", "BUILD_NUMBER": "1"}
        cases = [({}, True), ({"SELECTED_ACTION": "upload", "BUILD_NUMBER": "9999"}, True)]
        for key, values in {
            "GITHUB_EVENT_NAME": ["push", "pull_request"], "GITHUB_REF": ["refs/heads/feature", "refs/tags/main"],
            "SIGNING_ENABLED": ["", "false", "TRUE"], "REQUIRE_APPROVAL": ["yes"],
            "SELECTED_ACTION": ["", "publish", "archive; echo injected"],
            "BUILD_NUMBER": ["0", "10000", "-1", "1.0", "01", "$(echo injected)", "1\n2"],
        }.items():
            cases.extend(({key: value}, False) for value in values)
        for updates, expected in cases:
            with self.subTest(updates=updates):
                result = subprocess.run([BASH, "-c", script], env={**valid, **updates}, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, expected, result.stderr)


class ProfileSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "profile.plist"
        self.env = patch.dict(os.environ, CONFIG, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def validate(self, profile):
        self.path.write_bytes(plistlib.dumps(profile))
        return signing.validate_profile(self.path)

    def test_valid_explicit_app_store_profile_and_legacy_app_prefix(self):
        self.assertEqual(self.validate(profile_fixture())["UUID"], UUID)
        profile = profile_fixture()
        profile["ApplicationIdentifierPrefix"] = ["OLDPREFIX1"]
        profile["Entitlements"]["application-identifier"] = f"OLDPREFIX1.{BUNDLE}"
        self.assertEqual(self.validate(profile)["UUID"], UUID)

    def test_wrong_team_app_expired_development_adhoc_enterprise_wildcard_rejected(self):
        cases = [
            ("wrong team", {"TeamIdentifier": ["ZZZZZZZZZZ"]}, {}),
            ("wrong team entitlement", {}, {"com.apple.developer.team-identifier": "ZZZZZZZZZZ"}),
            ("wrong app", {}, {"application-identifier": f"{TEAM}.com.example.other"}),
            ("wildcard", {}, {"application-identifier": f"{TEAM}.*"}),
            ("expired", {"ExpirationDate": dt.datetime(2000, 1, 1)}, {}),
            ("development", {}, {"get-task-allow": True}),
            ("ad hoc", {"ProvisionedDevices": ["fake-device"]}, {}),
            ("empty device list", {"ProvisionedDevices": []}, {}),
            ("enterprise", {"ProvisionsAllDevices": True}, {}),
            ("not app store", {}, {"beta-reports-active": False}),
            ("not iOS", {"Platform": ["OSX"]}, {}),
            ("invalid UUID", {"UUID": "../../outside"}, {}),
            ("no certificate", {"DeveloperCertificates": []}, {}),
            ("invalid certificate", {"DeveloperCertificates": ["not bytes"]}, {}),
        ]
        for label, values, entitlements in cases:
            with self.subTest(label=label):
                profile = profile_fixture()
                profile.update(values)
                profile["Entitlements"].update(entitlements)
                with self.assertRaises(signing.ValidationError):
                    self.validate(profile)

    def test_missing_required_profile_metadata_rejected(self):
        for key in ("ExpirationDate", "TeamIdentifier", "ApplicationIdentifierPrefix", "Platform", "UUID", "DeveloperCertificates", "Entitlements"):
            with self.subTest(key=key):
                profile = profile_fixture()
                del profile[key]
                with self.assertRaises(signing.ValidationError):
                    self.validate(profile)

    def test_only_matching_distribution_identity_is_accepted(self):
        self.validate(profile_fixture())
        identities = self.path.with_name("identities.txt")
        good = f'  1) {FINGERPRINT} "Apple Distribution: Test ({TEAM})"\n'
        identities.write_text(good)
        self.assertEqual(signing.identity(self.path, identities), FINGERPRINT)
        for invalid in ("", good.replace(FINGERPRINT, "0" * 40), good.replace(TEAM, "ZZZZZZZZZZ"),
                        good.replace("Apple Distribution:", "Apple Development:"), good + good):
            with self.subTest(identity=invalid):
                identities.write_text(invalid)
                with self.assertRaises(signing.ValidationError):
                    signing.identity(self.path, identities)

    def test_export_options_cannot_upload_or_automatically_provision(self):
        self.validate(profile_fixture())
        destination = self.path.with_name("ExportOptions.plist")
        signing.export_options(self.path, FINGERPRINT, destination)
        options = plistlib.loads(destination.read_bytes())
        self.assertEqual(options["method"], "app-store-connect")
        self.assertEqual(options["destination"], "export")
        self.assertEqual(options["signingStyle"], "manual")
        self.assertEqual(options["provisioningProfiles"], {BUNDLE: UUID})
        self.assertFalse(options["manageAppVersionAndBuildNumber"])
        self.assertFalse(options["uploadSymbols"])

    def test_base64_decode_is_strict_and_does_not_overwrite(self):
        destination = self.path.with_name("decoded")
        for value in ("%%%invalid%%%", "", " \n "):
            with self.subTest(value=value), patch.dict(os.environ, {"SECRET": value}), self.assertRaises(signing.ValidationError):
                signing.decode("SECRET", destination)
            self.assertFalse(destination.exists())
        with patch.dict(os.environ, {"SECRET": base64.b64encode(b"synthetic data").decode()}):
            signing.decode("SECRET", destination)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                signing.decode("SECRET", destination)
        self.assertEqual(destination.read_bytes(), b"synthetic data")

    def test_malformed_secret_plist_parser_diagnostics_are_redacted(self):
        self.path.write_text('<plist version="1.0"><dict><key>ExpirationDate</key>'
                             '<integer>REVIEW_SECRET_MARKER</integer></dict></plist>')
        result = subprocess.run([sys.executable, str(ROOT / "scripts/testflight-signing.py"), "profile", str(self.path)],
                                env=CONFIG, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("REVIEW_SECRET_MARKER", result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.stdout, "")


class SigningOrchestrationTests(unittest.TestCase):
    def make_runner(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        return OfflineRunner(temp.name)

    def assert_private_output(self, runner, result):
        output = result.stdout + result.stderr
        for secret in (TOOL_OUTPUT, "FAKE-P12-NOT-A-CERTIFICATE", "FAKE-API-PRIVATE-KEY-NOT-A-KEY",
                       "FAKE-CERTIFICATE-NOT-DER-NO-PRIVATE-KEY", "1" * 64,
                       *[value for key, value in runner.env.items() if key.startswith(("APPLE_", "ASC_"))]):
            if secret:
                self.assertNotIn(secret, output)
        self.assertNotIn("<plist", output)

    def assert_clean(self, runner):
        retained = runner.temp / "arrivau-privacy-audit.123.1.json"
        self.assertEqual(list(runner.temp.iterdir()), [retained] if retained.exists() else [])
        if retained.exists():
            self.assertIsInstance(json.loads(retained.read_text()), dict)
            self.assertNotIn("<plist", retained.read_text())
            self.assertNotIn(TOOL_OUTPUT, retained.read_text())
            self.assertNotIn("synthetic-google-key-never-valid-12345", retained.read_text())
        self.assertEqual(sorted(path.name for path in runner.profile_dir.iterdir()), ["unrelated.mobileprovision"])
        self.assertEqual((runner.profile_dir / "unrelated.mobileprovision").read_text(), "preserve unrelated profile")
        self.assertEqual(json.loads((runner.root / "keychains.json").read_text()), runner.original_keychains)
        for path in runner.original_keychains:
            self.assertEqual(Path(path).read_text(), "preserve original keychain")

    def assert_no_sensitive_commands(self, runner):
        self.assertTrue(all(call[0] in ("uname", "git") for call in runner.calls()), runner.calls())
        self.assert_clean(runner)

    def test_missing_configuration_and_invalid_input_fail_before_signing(self):
        cases = [(key, "") for key in (*CONFIG, "APPLE_DISTRIBUTION_P12_BASE64", "APPLE_DISTRIBUTION_P12_PASSWORD", "APPLE_APP_STORE_PROFILE_BASE64")]
        cases += [("ARRIVAU_API_URL", "http://localhost:8080"), ("ARRIVAU_TEAM_ID", "bad"), ("ARRIVAU_BUNDLE_ID", "dev.arrivau.app")]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                runner = self.make_runner()
                runner.env[key] = value
                result = runner.run("archive", "17")
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_sensitive_commands(runner)
                self.assert_private_output(runner, result)
        for args in [(), ("archive",), ("publish", "17"), ("archive", "0"), ("archive", "10000"),
                     ("archive", "01"), ("archive", "17; echo injected"), ("archive", "17", "extra")]:
            with self.subTest(args=args):
                runner = self.make_runner()
                result = runner.run(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_sensitive_commands(runner)

    def test_manual_main_exact_commit_and_signing_optin_required(self):
        for key, value in [("GITHUB_ACTIONS", "false"), ("GITHUB_EVENT_NAME", "push"),
                           ("GITHUB_EVENT_NAME", "pull_request"), ("GITHUB_REF", "refs/heads/feature"),
                           ("GITHUB_REF", "refs/tags/main"), ("GITHUB_SHA", "b" * 40),
                           ("TESTFLIGHT_SIGNING_ENABLED", "false"), ("TESTFLIGHT_SIGNING_ENABLED", ""),
                           ("GITHUB_RUN_ID", "../outside"), ("GITHUB_RUN_ATTEMPT", ""), ("RUNNER_TEMP", "/does/not/exist")]:
            with self.subTest(key=key, value=value):
                runner = self.make_runner()
                runner.env[key] = value
                result = runner.run("archive", "17")
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_sensitive_commands(runner)

    def test_upload_requires_additional_valid_api_secrets_before_signing(self):
        for key, value in [("ASC_PRIVATE_KEY_BASE64", ""), ("ASC_KEY_ID", ""), ("ASC_ISSUER_ID", ""),
                           ("ASC_KEY_ID", "../bad"), ("ASC_ISSUER_ID", "not-a-uuid")]:
            with self.subTest(key=key, value=value):
                runner = self.make_runner()
                runner.add_upload_secrets()
                runner.env[key] = value
                result = runner.run("upload", "17")
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_sensitive_commands(runner)
                self.assert_private_output(runner, result)

    def test_upload_requires_configured_navigation_key_before_using_signing_material(self):
        runner = self.make_runner()
        runner.add_upload_secrets()
        del runner.env["ARRIVAU_GOOGLE_MAPS_API_KEY"]
        result = runner.run("upload", "17")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Google iOS key presence: missing", result.stdout)
        self.assertIn("Upload requires the owner-configured Google iOS key", result.stderr)
        self.assert_no_sensitive_commands(runner)
        self.assert_private_output(runner, result)

    def test_archive_verifies_both_products_never_uploads_and_cleans_up(self):
        runner = self.make_runner()
        result = runner.run("archive", "17")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = runner.calls()
        self.assertFalse(any(call[:2] == ["xcrun", "altool"] for call in calls))
        self.assertEqual(sum(call[:2] == ["codesign", "--verify"] for call in calls), 2)
        self.assertTrue((runner.temp / "arrivau-privacy-audit.123.1.json").is_file())
        extractions = [call for call in calls if any(arg.startswith("--extract-certificates") for arg in call)]
        self.assertEqual(len(extractions), 2)
        self.assertTrue(all(call[2].startswith("--extract-certificates=") for call in extractions))
        entitlements = [call for call in calls if "--entitlements" in call]
        self.assertEqual(len(entitlements), 2)
        self.assertTrue(all(call[2:5] == ["--entitlements", "-", "--xml"] for call in entitlements))
        self.assertEqual(sum(call[:2] == ["xcodebuild", "archive"] for call in calls), 1)
        self.assertEqual(sum(call[:2] == ["xcodebuild", "-exportArchive"] for call in calls), 1)
        self.assertFalse(any("-allowProvisioningUpdates" in call for call in calls))
        self.assertIn("Archive mode performed no upload", result.stdout)
        self.assert_private_output(runner, result)
        self.assert_clean(runner)
        # The always() defense may execute after EXIT cleanup; it must be harmless.
        for line in (runner.root / "github-env").read_text().splitlines():
            key, value = line.split("=", 1)
            runner.env[key] = value
        again = runner.run("cleanup")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assert_clean(runner)

    def test_navigation_key_is_optional_private_and_not_passed_on_command_line(self):
        for key in ("", "synthetic-google-key-never-valid-12345"):
            with self.subTest(configured=bool(key)):
                runner = self.make_runner()
                runner.env["ARRIVAU_GOOGLE_MAPS_API_KEY"] = key
                result = runner.run("archive", "17")
                self.assertEqual(result.returncode, 0, result.stderr)
                observed = json.loads((runner.root / "navigation-observed.json").read_text())
                self.assertEqual(observed, {"key": key, "mode": 0o600})
                self.assertIn("Google iOS key presence: " + ("configured" if key else "missing"), result.stdout)
                if key:
                    self.assertNotIn(key, result.stdout + result.stderr)
                    self.assertNotIn(key, json.dumps(runner.calls()))
                self.assert_clean(runner)

    def test_invalid_navigation_key_fails_without_echo_and_cleans_temporary_files(self):
        runner = self.make_runner()
        key = "synthetic-google-key-never-valid-12345\nINJECTED"
        runner.env["ARRIVAU_GOOGLE_MAPS_API_KEY"] = key
        result = runner.run("archive", "17")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(key, result.stdout + result.stderr)
        self.assertFalse(any(call[:2] == ["security", "import"] for call in runner.calls()))
        self.assert_clean(runner)

    def test_private_app_overlay_replaces_global_archive_settings(self):
        runner = self.make_runner()
        result = runner.run("archive", "17")
        self.assertEqual(result.returncode, 0, result.stderr)
        overlay = json.loads((runner.root / "archive-config-observed.json").read_text())
        self.assertEqual(set(overlay), {"include", "targets"})
        self.assertEqual(set(overlay["targets"]), {"Arrivau"})
        settings = overlay["targets"]["Arrivau"]["settings"]["configs"]["Release"]
        self.assertEqual(settings["CODE_SIGN_IDENTITY"], FINGERPRINT)
        self.assertEqual(settings["PROVISIONING_PROFILE_SPECIFIER"], UUID)
        self.assertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], BUNDLE)
        self.assertEqual(settings["CODE_SIGNING_ALLOWED"], "YES")
        self.assertEqual(settings["CODE_SIGNING_REQUIRED"], "YES")
        archive = next(call for call in runner.calls() if call[:2] == ["xcodebuild", "archive"])
        self.assertFalse(any(arg.split("=", 1)[0] in settings for arg in archive))
        self.assertFalse((runner.repo / "ios/Arrivau.xcodeproj").exists())
        self.assert_private_output(runner, result)
        self.assert_clean(runner)

    def test_archive_failure_emits_only_whitelisted_diagnostic_and_never_uploads(self):
        runner = self.make_runner()
        runner.add_upload_secrets()
        runner.env["FAKE_FAIL_AT"] = "xcodebuild:archive"
        runner.env["FAKE_ARCHIVE_ERROR"] = "error: PRIVATE_TARGET does not support provisioning profiles PRIVATE_SECRET"
        result = runner.run("upload", "17")
        self.assertEqual(result.returncode, 42)
        self.assertIn("ARCHIVE_PROVISIONING_NOT_SUPPORTED", result.stdout)
        self.assertNotIn("PRIVATE_TARGET", result.stdout + result.stderr)
        self.assertNotIn("PRIVATE_SECRET", result.stdout + result.stderr)
        self.assertFalse(any(call[:2] == ["xcodebuild", "-exportArchive"] for call in runner.calls()))
        self.assertFalse(any("--upload-app" in call for call in runner.calls()))
        self.assert_private_output(runner, result)
        self.assert_clean(runner)

    def test_old_codesign_argument_forms_fail_closed(self):
        cases = [
            ('"--extract-certificates=$WORK/$label-cert"', '--extract-certificates "$WORK/$label-cert"',
             "extracting the signing certificate"),
            ("--entitlements - --xml", "--entitlements :-", "matching signed metadata, entitlements and certificate"),
        ]
        for old, replacement, substep in cases:
            with self.subTest(substep=substep):
                runner = self.make_runner()
                script = runner.repo / "scripts/testflight-ci.sh"
                text = script.read_text()
                self.assertIn(old, text)
                script.write_text(text.replace(old, replacement))
                runner.add_upload_secrets()
                result = runner.run("upload", "17")
                self.assertEqual(result.returncode, 1)
                self.assertIn("verifying archive: " + substep, result.stderr)
                self.assertFalse(any(call[:2] == ["xcodebuild", "-exportArchive"] for call in runner.calls()))
                self.assertFalse(any(call[:3] == ["xcrun", "altool", "--upload-app"] for call in runner.calls()))
                self.assert_private_output(runner, result)
                self.assert_clean(runner)

    def test_verification_substeps_fail_privately_for_both_products(self):
        failures = [
            ("codesign:--verify", "strict code signature"),
            ("codesign:entitlements", "extracting XML entitlements"),
            ("codesign:metadata", "reading signature metadata"),
            ("codesign:certificates", "extracting the signing certificate"),
            ("security:embedded-profile", "decoding the embedded provisioning profile"),
        ]
        for product in ("archive", "export"):
            for operation, substep in failures:
                with self.subTest(product=product, operation=operation):
                    runner = self.make_runner()
                    runner.add_upload_secrets()
                    runner.env.update(FAKE_FAIL_AT=operation, FAKE_FAIL_PRODUCT=product)
                    result = runner.run("upload", "17")
                    self.assertEqual(result.returncode, 42)
                    self.assertIn(f"verifying {product}: {substep} (exit 42)", result.stderr)
                    self.assertFalse(any(call[:3] == ["xcrun", "altool", "--upload-app"] for call in runner.calls()))
                    self.assert_private_output(runner, result)
                    self.assert_clean(runner)

    def test_bundle_and_signer_checks_still_block_upload(self):
        for environment, substep in [
            ({"FAKE_INVALID_BUNDLE": "1"}, "verifying archive: Release bundle contents"),
            ({"FAKE_WRONG_CERT_PRODUCT": "archive"}, "verifying archive: matching signed metadata"),
            ({"FAKE_WRONG_CERT_PRODUCT": "export"}, "verifying export: matching signed metadata"),
        ]:
            with self.subTest(environment=environment):
                runner = self.make_runner()
                runner.add_upload_secrets()
                runner.env.update(environment)
                result = runner.run("upload", "17")
                self.assertEqual(result.returncode, 1)
                self.assertIn(substep, result.stderr)
                self.assertFalse(any(call[:3] == ["xcrun", "altool", "--upload-app"] for call in runner.calls()))
                self.assert_private_output(runner, result)
                self.assert_clean(runner)

    def test_credential_free_tool_smoke_checks_certificate_and_cleans_up(self):
        runner = self.make_runner()
        result = runner.check_tools()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("required prefix syntax", result.stdout)
        self.assertTrue(any(call[:2] == ["openssl", "x509"] for call in runner.calls()))
        self.assertFalse(any(call[0] == "security" or "--sign" in call or "--upload-app" in call for call in runner.calls()))
        self.assert_private_output(runner, result)
        self.assert_clean(runner)

    def test_tool_smoke_failures_do_not_print_tool_output(self):
        for stage in ("codesign:certificates", "openssl:x509"):
            with self.subTest(stage=stage):
                runner = self.make_runner()
                runner.env["FAKE_FAIL_AT"] = stage
                result = runner.check_tools()
                self.assertEqual(result.returncode, 1)
                self.assert_private_output(runner, result)
                self.assert_clean(runner)

    def test_privacy_audit_mismatch_blocks_upload_and_retains_no_report(self):
        runner = self.make_runner()
        runner.add_upload_secrets()
        runner.env["FAKE_PRIVACY_MISMATCH"] = "1"
        result = runner.run("upload", "17")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("auditing privacy manifests", result.stderr)
        self.assertFalse(any("--upload-app" in call for call in runner.calls()))
        self.assertEqual(list(runner.temp.iterdir()), [])
        self.assert_private_output(runner, result)
        self.assert_clean(runner)

    def test_explicit_upload_uses_only_mocked_uploader_then_cleans_up(self):
        for style, flags in [("legacy", ("--apiKey", "--apiIssuer", "-t")),
                             ("current", ("--api-key", "--api-issuer", "--platform"))]:
            with self.subTest(style=style):
                runner = self.make_runner()
                runner.add_upload_secrets()
                runner.env["FAKE_ALTOOL_STYLE"] = style
                result = runner.run("upload", "17")
                self.assertEqual(result.returncode, 0, result.stderr)
                uploads = [call for call in runner.calls() if call[:3] == ["xcrun", "altool", "--upload-app"]]
                self.assertEqual(len(uploads), 1)
                for flag in flags:
                    self.assertIn(flag, uploads[0])
                self.assert_private_output(runner, result)
                self.assert_clean(runner)

    def test_unsupported_uploader_stops_without_upload_and_cleans_up(self):
        runner = self.make_runner()
        runner.add_upload_secrets()
        runner.env["FAKE_ALTOOL_STYLE"] = "unsupported"
        result = runner.run("upload", "17")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[:3] == ["xcrun", "altool", "--upload-app"] for call in runner.calls()))
        self.assert_private_output(runner, result)
        self.assert_clean(runner)

    def test_failure_cleanup_and_original_search_list_are_preserved(self):
        for stage in ("security:import", "xcodegen:generate", "xcodebuild:archive", "codesign:--verify",
                      "xcodebuild:-exportArchive", "ditto:-x", "xcrun:altool", "xcrun:upload"):
            with self.subTest(stage=stage):
                runner = self.make_runner()
                runner.add_upload_secrets()
                runner.env["FAKE_FAIL_AT"] = stage
                result = runner.run("upload", "17")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Manual signing failed while", result.stderr)
                self.assert_private_output(runner, result)
                self.assert_clean(runner)

    def test_keychain_cleanup_error_fails_job_but_still_removes_private_products(self):
        runner = self.make_runner()
        runner.env["FAKE_FAIL_AT"] = "security:delete-keychain"
        result = runner.run("archive", "17")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Temporary signing cleanup could not be verified", result.stderr)
        self.assert_private_output(runner, result)
        self.assert_clean(runner)

    def test_malformed_profile_fails_before_importing_identity(self):
        runner = self.make_runner()
        profile = profile_fixture()
        profile["Entitlements"]["get-task-allow"] = True
        runner.env["APPLE_APP_STORE_PROFILE_BASE64"] = base64.b64encode(plistlib.dumps(profile)).decode()
        result = runner.run("archive", "17")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[:2] == ["security", "import"] for call in runner.calls()))
        self.assert_clean(runner)

    def test_invalid_base64_fails_and_removes_private_temp_files(self):
        runner = self.make_runner()
        runner.env["APPLE_DISTRIBUTION_P12_BASE64"] = "SECRET-INVALID-BASE64-%"
        result = runner.run("archive", "17")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == "security" for call in runner.calls()))
        self.assert_private_output(runner, result)
        self.assert_clean(runner)

    def test_cleanup_refuses_unrelated_path_or_symlink(self):
        runner = self.make_runner()
        outside = runner.root / "keep-me"
        outside.mkdir()
        (outside / "sentinel").write_text("keep")
        link = runner.temp / "arrivau-testflight.123.1.abcdef"
        link.symlink_to(outside, target_is_directory=True)
        for path in (outside, link, runner.temp):
            with self.subTest(path=path):
                runner.env["ARRIVAU_TESTFLIGHT_STATE"] = str(path)
                result = runner.run("cleanup")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((outside / "sentinel").read_text(), "keep")
                self.assertEqual(runner.calls(), [])


if __name__ == "__main__":
    unittest.main()

