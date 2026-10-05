"""Offline navigation configuration tests. No credentials or Google requests."""

import importlib.util
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/navigation-config.py"
spec = importlib.util.spec_from_file_location("navigation_config", SCRIPT)
navigation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(navigation)
FAKE_KEY = "synthetic-google-key-never-valid-12345"


class NavigationConfigurationTests(unittest.TestCase):
    def test_missing_key_is_optional_and_empty(self):
        self.assertEqual(navigation.configuration({}), {navigation.KEY: ""})
        self.assertEqual(navigation.configuration({navigation.KEY: ""}), {navigation.KEY: ""})

    def test_injection_characters_and_unexpanded_variables_rejected_without_echo(self):
        for value in ("short", " ", "x" * 201, "$(KEY)", FAKE_KEY + "\n", FAKE_KEY + "\"", FAKE_KEY + "<xml>"):
            with self.subTest(length=len(value)):
                with self.assertRaises(ValueError) as failure:
                    navigation.configuration({navigation.KEY: value})
                if value.strip():
                    self.assertNotIn(value, str(failure.exception))

    def test_key_in_private_generated_plist_only_and_other_fields_preserved(self):
        for mode in ("Debug", "Release"):
            with self.subTest(configuration=mode), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "private/Info.plist"
                original = (ROOT / f"ios/Config/Info-{mode}.plist").read_bytes()
                navigation.write_configuration(mode, output, {navigation.KEY: FAKE_KEY})
                generated = plistlib.loads(output.read_bytes())
                expected = plistlib.loads(original)
                expected[navigation.KEY] = FAKE_KEY
                self.assertEqual(generated, expected)
                self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
                self.assertEqual((ROOT / f"ios/Config/Info-{mode}.plist").read_bytes(), original)
                self.assertEqual(generated["ARRIVAU_API_URL"], "$(ARRIVAU_API_URL)")

    def test_replacement_clears_old_key_and_restricts_permissions(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "Info.plist"
            navigation.write_configuration("Release", output, {navigation.KEY: FAKE_KEY})
            output.chmod(0o644)
            navigation.write_configuration("Release", output, {})
            self.assertEqual(plistlib.loads(output.read_bytes())[navigation.KEY], "")
            self.assertNotIn(FAKE_KEY.encode(), output.read_bytes())
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual([path.name for path in Path(temp).iterdir()], ["Info.plist"])

    def test_invalid_config_preserves_previous_file(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "Info.plist"
            output.write_bytes(b"previous")
            with self.assertRaises(ValueError):
                navigation.write_configuration("Release", output, {navigation.KEY: "bad"})
            self.assertEqual(output.read_bytes(), b"previous")
            with self.assertRaises(ValueError):
                navigation.write_configuration("Production", output, {})

    def test_never_overwrites_tracked_templates(self):
        for mode in ("Debug", "Release", "UITests"):
            template = ROOT / f"ios/Config/Info-{mode}.plist"
            original = template.read_bytes()
            with self.assertRaises(ValueError):
                navigation.write_configuration("Release", template, {navigation.KEY: FAKE_KEY})
            self.assertEqual(template.read_bytes(), original)

    def test_cli_never_prints_key_or_plist(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "Info.plist"
            for value, expected_status in ((FAKE_KEY, 0), (FAKE_KEY + "\n", 1)):
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), "--configuration", "Release", "--output", str(output)],
                    env={**os.environ, navigation.KEY: value}, text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, expected_status, result.stderr)
                self.assertNotIn(FAKE_KEY, result.stdout + result.stderr)
                self.assertNotIn("<plist", result.stdout + result.stderr)

    def test_project_pins_all_sdk_versions_and_blank_default(self):
        project = (ROOT / "ios/project.yml").read_text()
        self.assertEqual(project.count("exactVersion: 11.2.0"), 3)
        self.assertIn("https://github.com/googlemaps/ios-navigation-sdk", project)
        self.assertIn("https://github.com/googlemaps/ios-maps-sdk", project)
        self.assertIn("https://github.com/googlemaps/ios-places-sdk", project)
        self.assertIn('ARRIVAU_GOOGLE_MAPS_API_KEY: ""', project)
        self.assertIn("/ios/Config/Navigation.local/", (ROOT / ".gitignore").read_text())

    def test_sdk_usage_descriptions_background_modes_and_no_release_ats_exception(self):
        for mode in ("Debug", "Release"):
            with self.subTest(configuration=mode):
                info = plistlib.loads((ROOT / f"ios/Config/Info-{mode}.plist").read_bytes())
                self.assertEqual(info[navigation.KEY], "$(ARRIVAU_GOOGLE_MAPS_API_KEY)")
                for permission in ("NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription", "NSMotionUsageDescription"):
                    self.assertTrue(info[permission])
                self.assertEqual(set(info["UIBackgroundModes"]), {"audio", "location"})
                if mode == "Release":
                    self.assertNotIn("NSAppTransportSecurity", info)


if __name__ == "__main__":
    unittest.main()
