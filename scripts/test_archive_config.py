"""Offline archive configuration/scoping regressions; synthetic data only."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / f"scripts/{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


archive = load("archive-config")
verify = load("verify-archive-scoping")
diagnostics = load("archive-diagnostics")
FAKE_KEY = "synthetic-google-key-never-valid-12345"
ENV = {
    "ARRIVAU_TEAM_ID": "ABCDEFGHIJ", "ARRIVAU_BUNDLE_ID": "com.example.arrivau.archivecheck",
    "ARRIVAU_API_URL": "https://pilot.example.com", "ARRIVAU_GOOGLE_MAPS_API_KEY": FAKE_KEY,
    "ARRIVAU_ARCHIVE_PROFILE_UUID": "12345678-1234-1234-1234-123456789ABC",
    "ARRIVAU_ARCHIVE_IDENTITY": "1" * 40,
    "ARRIVAU_ARCHIVE_KEYCHAIN": "/tmp/synthetic keychain's path/signing.keychain-db",
}


class ArchiveConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.info = self.root / "Info.plist"
        self.info.write_bytes(plistlib.dumps({"ARRIVAU_GOOGLE_MAPS_API_KEY": FAKE_KEY}))
        self.output = self.root / "project.json"

    def overlay(self, manual=True):
        archive.write_overlay("314", self.info, self.output, ENV, manual)
        return json.loads(self.output.read_text())

    def test_only_app_release_target_receives_private_settings(self):
        overlay = self.overlay()
        self.assertEqual(set(overlay), {"include", "targets"})
        self.assertEqual(overlay["include"], [{"path": str(ROOT / "ios/project.yml"), "relativePaths": False}])
        self.assertEqual(set(overlay["targets"]), {"Arrivau"})
        self.assertEqual(set(overlay["targets"]["Arrivau"]["settings"]["configs"]), {"Release"})
        settings = overlay["targets"]["Arrivau"]["settings"]["configs"]["Release"]
        self.assertEqual(settings["INFOPLIST_FILE"], str(self.info))
        self.assertEqual(settings["PROVISIONING_PROFILE_SPECIFIER"], ENV["ARRIVAU_ARCHIVE_PROFILE_UUID"])
        self.assertEqual(settings["CODE_SIGN_IDENTITY"], ENV["ARRIVAU_ARCHIVE_IDENTITY"])
        self.assertEqual(settings["CODE_SIGNING_ALLOWED"], "YES")
        self.assertEqual(settings["CODE_SIGNING_REQUIRED"], "YES")
        self.assertEqual(shlex.split(settings["OTHER_CODE_SIGN_FLAGS"]), ["--keychain", ENV["ARRIVAU_ARCHIVE_KEYCHAIN"]])
        self.assertNotIn(FAKE_KEY, self.output.read_text())
        self.assertNotIn("ARRIVAU_GOOGLE_MAPS_API_KEY", self.output.read_text())
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)

    def test_automatic_archive_keeps_existing_signing_defaults(self):
        settings = self.overlay(False)["targets"]["Arrivau"]["settings"]["configs"]["Release"]
        self.assertEqual(set(settings), {"INFOPLIST_FILE", "DEVELOPMENT_TEAM", "PRODUCT_BUNDLE_IDENTIFIER", "CURRENT_PROJECT_VERSION", "ARRIVAU_API_URL"})

    def test_replacement_is_private_and_invalid_input_preserves_old_file(self):
        self.overlay()
        self.output.chmod(0o644)
        self.overlay()
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        original = self.output.read_bytes()
        for field, value in (("ARRIVAU_TEAM_ID", "private-invalid-team"),
                             ("ARRIVAU_ARCHIVE_PROFILE_UUID", "private-invalid-profile"),
                             ("ARRIVAU_ARCHIVE_IDENTITY", "private-invalid-identity"),
                             ("ARRIVAU_ARCHIVE_KEYCHAIN", "relative-private-path"),
                             ("ARRIVAU_ARCHIVE_KEYCHAIN", "/tmp/$(private-expansion)")):
            with self.subTest(field=field):
                with self.assertRaises(ValueError) as failure:
                    archive.write_overlay("314", self.info, self.output, {**ENV, field: value}, True)
                self.assertNotIn(value, str(failure.exception))
                self.assertEqual(self.output.read_bytes(), original)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["Info.plist", "project.json"])

    def test_input_paths_cannot_be_overwritten(self):
        for destination in (self.info, ROOT / "ios/project.yml"):
            original = destination.read_bytes()
            with self.assertRaises(ValueError):
                archive.write_overlay("314", self.info, destination, ENV, True)
            self.assertEqual(destination.read_bytes(), original)

    def test_cli_emits_no_private_values_on_success_or_failure(self):
        for identity, status in (("1" * 40, 0), ("private-invalid-identity", 1)):
            result = subprocess.run([sys.executable, str(ROOT / "scripts/archive-config.py"),
                                     "--manual-signing", "--build-number", "314", "--info-plist", str(self.info),
                                     "--output", str(self.output)],
                                    env={**os.environ, **ENV, "ARRIVAU_ARCHIVE_IDENTITY": identity}, capture_output=True, text=True)
            self.assertEqual(result.returncode, status, result.stderr)
            for value in (*ENV.values(), identity):
                self.assertNotIn(value, result.stdout + result.stderr)

    def settings_fixture(self, overlay):
        app = copy.deepcopy(overlay["targets"]["Arrivau"]["settings"]["configs"]["Release"])
        return [{"target": "Arrivau", "buildSettings": app},
                {"target": "ArrivauTests", "buildSettings": {"CODE_SIGN_STYLE": "Automatic"}},
                {"target": "ArrivauUITests", "buildSettings": {"CODE_SIGN_STYLE": "Automatic"}}]

    def test_resolved_settings_detect_cross_target_and_key_leaks(self):
        overlay = self.overlay()
        records = self.settings_fixture(overlay)
        path = self.root / "settings.json"
        path.write_text(json.dumps(records))
        verify.verify_settings(path, overlay)
        app = records[0]["buildSettings"]
        for key in app:
            if key in ("CODE_SIGNING_ALLOWED", "CODE_SIGNING_REQUIRED"):
                continue  # SDK/test defaults may independently allow code signing.
            with self.subTest(key=key):
                bad = copy.deepcopy(records)
                bad[1]["buildSettings"][key] = app[key]
                path.write_text(json.dumps(bad))
                with self.assertRaises(ValueError):
                    verify.verify_settings(path, overlay)
        records[0]["buildSettings"]["ARRIVAU_GOOGLE_MAPS_API_KEY"] = FAKE_KEY
        path.write_text(json.dumps(records))
        with self.assertRaisesRegex(ValueError, "ARCHIVE_SETTINGS_API_KEY_LEAK"):
            verify.verify_settings(path, overlay)

    def test_resolved_settings_require_all_targets_and_full_app_configuration(self):
        overlay = self.overlay()
        path = self.root / "settings.json"
        for records in ([], self.settings_fixture(overlay)[:1]):
            path.write_text(json.dumps(records))
            with self.assertRaises(ValueError):
                verify.verify_settings(path, overlay)
        for key in self.settings_fixture(overlay)[0]["buildSettings"]:
            records = self.settings_fixture(overlay)
            del records[0]["buildSettings"][key]
            path.write_text(json.dumps(records))
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify.verify_settings(path, overlay)

    def bundle_fixture(self):
        app = self.root / "Arrivau.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": ENV["ARRIVAU_BUNDLE_ID"], "CFBundleVersion": "314",
            "ARRIVAU_API_URL": ENV["ARRIVAU_API_URL"], "ARRIVAU_GOOGLE_MAPS_API_KEY": FAKE_KEY,
        }))
        for sdk in ("GoogleMaps", "GooglePlaces", "GoogleNavigation"):
            wrapper = app / f"{sdk}_{sdk}Target.bundle"
            wrapper.mkdir()
            (wrapper / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": sdk + ".resources"}))
            inner = wrapper / f"{sdk}.bundle"
            inner.mkdir()
            (inner / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": sdk + ".vendor"}))
        return app

    def test_unsigned_archive_privacy_check_uses_reviewed_vendor_declarations(self):
        app = self.bundle_fixture()
        (app / "PrivacyInfo.xcprivacy").write_bytes((ROOT / "ios/Resources/PrivacyInfo.xcprivacy").read_bytes())
        for sdk in ("GoogleMaps", "GooglePlaces", "GoogleNavigation"):
            target = app / f"{sdk}_{sdk}Target.bundle/{sdk}.bundle/PrivacyInfo.xcprivacy"
            target.write_bytes((ROOT / f"scripts/tests/fixtures/google-privacy-11.2.0/{sdk}/PrivacyInfo.xcprivacy").read_bytes())
        verify.verify_privacy(app)
        target.write_bytes(plistlib.dumps({"NSPrivacyTracking": False}))
        with self.assertRaisesRegex(ValueError, "ARCHIVE_BUNDLE_PRIVACY_DECLARATIONS_INVALID"):
            verify.verify_privacy(app)

    def test_actual_sdk_wrappers_and_resources_do_not_contain_app_configuration(self):
        overlay = self.overlay()
        app = self.bundle_fixture()
        verify.verify_bundle(app, overlay)
        target = next(app.glob("*.bundle")) / "Info.plist"
        for bad in ({"CFBundleIdentifier": ENV["ARRIVAU_BUNDLE_ID"]}, {"ARRIVAU_API_URL": ""},
                    {"ARRIVAU_GOOGLE_MAPS_API_KEY": FAKE_KEY}, {"unexpected": FAKE_KEY}):
            with self.subTest(plist=bad):
                target.write_bytes(plistlib.dumps(bad))
                with self.assertRaises(ValueError):
                    verify.verify_bundle(app, overlay)
        target.write_bytes(plistlib.dumps({"CFBundleIdentifier": "sdk.resources"}))
        target.unlink()
        with self.assertRaisesRegex(ValueError, "ARCHIVE_BUNDLE_SDK_PLIST_MISSING"):
            verify.verify_bundle(app, overlay)
        target.write_bytes(plistlib.dumps({"CFBundleIdentifier": "sdk.resources"}))
        (app / "GoogleMaps_GoogleMapsTarget.bundle/GoogleMaps.bundle/Info.plist").unlink()
        (app / "GoogleMaps_GoogleMapsTarget.bundle/GoogleMaps.bundle").rmdir()
        with self.assertRaisesRegex(ValueError, "ARCHIVE_BUNDLE_SDK_RESOURCES_MISSING"):
            verify.verify_bundle(app, overlay)


class ArchiveDiagnosticTests(unittest.TestCase):
    def test_classifier_only_prints_fixed_enums_never_tool_input(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "private.log"
            for code, patterns in diagnostics.RULES:
                for pattern in patterns:
                    with self.subTest(code=code, pattern=pattern):
                        path.write_text(f"error: PRIVATE_TARGET {pattern} PRIVATE_IDENTITY API_SECRET PROFILE_NAME\n")
                        self.assertIn(code, diagnostics.classify(path))
                        result = subprocess.run([sys.executable, str(ROOT / "scripts/archive-diagnostics.py"), str(path)], capture_output=True, text=True)
                        allowed = {item[0] for item in diagnostics.RULES}
                        self.assertTrue(set(result.stdout.splitlines()).issubset(allowed))
                        self.assertEqual(result.stderr, "")

    def test_successful_steps_unknown_errors_and_missing_logs_are_safe(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "private.log"
            for content in ("SwiftCompile SUCCESS\nSwiftEmitModule SUCCESS", "error: PRIVATE_SECRET unknown issue"):
                path.write_text(content)
                self.assertEqual(diagnostics.classify(path), ["ARCHIVE_UNCLASSIFIED"])
            path.write_text("The following build commands failed:\nSwiftCompile PRIVATE_SOURCE_PATH")
            self.assertEqual(diagnostics.classify(path), ["ARCHIVE_SWIFT_COMPILE"])
            path.unlink()
            result = subprocess.run([sys.executable, str(ROOT / "scripts/archive-diagnostics.py"), str(path)], capture_output=True, text=True)
            self.assertEqual(result.stdout, "ARCHIVE_DIAGNOSTICS_UNAVAILABLE\n")
            self.assertEqual(result.stderr, "")

    def test_ci_archives_real_packages_without_signing_or_uploading(self):
        script = (ROOT / "scripts/test-archive-scoping.sh").read_text()
        self.assertIn("xcodebuild archive", script)
        self.assertIn("-showBuildSettings -json", script)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", script)
        self.assertNotIn("-allowProvisioningUpdates", script)
        self.assertNotIn("--upload-app", script)
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("run: ./scripts/test-archive-scoping.sh", workflow)
        self.assertIn("run: ./scripts/test-ios.sh", workflow)


if __name__ == "__main__":
    unittest.main()
