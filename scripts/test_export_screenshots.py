import importlib.util
import pathlib
import sqlite3
import tempfile
import unittest
from unittest import mock

try:
    import zstandard
except ImportError:
    zstandard = None

spec = importlib.util.spec_from_file_location("export_screenshots", pathlib.Path(__file__).with_name("export-screenshots.py"))
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class ScreenshotExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.result = self.root / "Result.xcresult"
        (self.result / "Data").mkdir(parents=True)
        self.db = sqlite3.connect(self.result / "database.sqlite3")
        self.db.execute("CREATE TABLE Attachments (name TEXT, xcResultKitPayloadRefId TEXT, uniformTypeIdentifier TEXT, timestamp REAL)")

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def add(self, name, ref="0~fixture"):
        (self.result / "Data" / ("data." + ref)).write_bytes(exporter.PNG + b"fixture")
        self.db.execute("INSERT INTO Attachments VALUES (?, ?, 'public.png', 0)", (name, ref))
        self.db.commit()

    def make_compact_result(self, include_optional=False):
        records = bytearray(b"[T")
        names = exporter.EXPORT_NAMES if include_optional else exporter.NAMES
        for index, name in enumerate(names):
            ref = f"0~compact{index}"
            (self.result / "Data" / ("data." + ref)).write_bytes(exporter.PNG + b"fixture")
            records.extend((f"K4:name[S6:StringK2:_vV{len(name)}:{name}]"
                            f"K10:payloadRef[S9:ReferenceK2:id[S6:StringK2:_vV{len(ref)}:{ref}]]").encode())
        (self.result / "Data" / "data.0~metadata").write_bytes(records)
        self.db.close()
        (self.result / "database.sqlite3").unlink()

    @staticmethod
    def truncated_payload():
        return zstandard.ZstdCompressor().compress(b"[T incomplete diagnostic")[:-1]

    def test_required_names_have_intentional_ui_captures(self):
        ui_root = pathlib.Path(__file__).resolve().parents[1] / "ios" / "UITests"
        source = "\n".join(path.read_text() for path in ui_root.glob("*.swift"))
        for name in dict.fromkeys(exporter.NAMES + exporter.SMOKE_NAMES):
            with self.subTest(name=name):
                self.assertIn('"' + name + '"', source)

    def test_ci_defaults_to_smoke_and_keeps_full_suite_manual(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        ci = (root / ".github/workflows/ci.yml").read_text()
        self.assertIn("options: [smoke, full]", ci)
        self.assertIn("default: smoke", ci)
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.ui_suite || 'smoke'", ci)
        self.assertIn('smoke|full) ./scripts/test-ios.sh "--$UI_SUITE"', ci)
        self.assertNotIn("--diagnose-login-first", ci)
        script = (root / "scripts/test-ios.sh").read_text()
        self.assertIn("--diagnose-login-first", script)
        self.assertIn("run_native_tests -only-testing:ArrivauTests -only-testing:ArrivauUITests/PilotSmokeUITests", script)
        self.assertIn("-only-testing:ArrivauUITests/DeliveryFlowUITests", script)
        self.assertIn("-only-testing:ArrivauUITests/InviteFlowUITests", script)
        self.assertIn('--require-all --suite "$UI_SUITE"', script)

    def test_smoke_export_requires_only_its_representative_screens(self):
        for index, name in enumerate(exporter.SMOKE_NAMES):
            self.add(name, f"0~smoke{index}")
        manifest = exporter.export(self.result, self.root / "smoke", True, suite="smoke")
        self.assertEqual(manifest["suite"], "smoke")
        self.assertEqual(manifest["missing"], [])
        self.assertEqual(len(manifest["screenshots"]), len(exporter.SMOKE_NAMES))
        full = exporter.export(self.result, self.root / "full", suite="full")
        self.assertIn("03-driver-route", full["missing"])

    def test_smoke_wait_diagnostics_do_not_resolve_absent_elements(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        source = (root / "ios/UITests/PilotSmokeUITests.swift").read_text()
        helpers = source.split("private func tap(_ element: XCUIElement)", 1)[1].split(
            "private func waitForLabel", 1
        )[0]
        self.assertNotIn("element.identifier", helpers)
        self.assertIn("element.exists && element.isEnabled && element.isHittable", helpers)
        self.assertIn("{ !element.exists }", helpers)

    def test_route_overview_is_an_accessible_container_not_an_inherited_child_id(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        source = (root / "ios/Sources/Components.swift").read_text()
        route_map = source.split("struct RouteMap: View", 1)[1].split("struct LocationAgeLabel", 1)[0]
        self.assertLess(route_map.index(".accessibilityElement(children: .contain)"),
                        route_map.index('.accessibilityIdentifier("route_map")'))
        smoke = (root / "ios/UITests/PilotSmokeUITests.swift").read_text()
        self.assertIn("XCTAssertGreaterThanOrEqual(overview.frame.height, 170", smoke)

    def test_logout_smoke_disambiguates_nested_native_action_wrappers(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        source = (root / "ios/UITests/PilotSmokeUITests.swift").read_text()
        helper = source.split("private func tapLogoutAlertButton", 1)[1].split("private func assertSharing", 1)[0]
        self.assertIn("activeLogoutAlert.buttons.matching(identifier: identifier).firstMatch", helper)
        self.assertIn("XCTAssertEqual(button.label, title)", helper)
        self.assertEqual(helper.count("button.tap()"), 1)
        self.assertIn("!self.app.alerts.firstMatch.exists", helper)

    def test_incomplete_smoke_export_still_fails(self):
        self.add(exporter.SMOKE_NAMES[0])
        with self.assertRaisesRegex(ValueError, "Missing expected screenshots"):
            exporter.export(self.result, self.root / "screens", True, suite="smoke")

    def test_unknown_suite_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Unknown screenshot suite"):
            exporter.export(self.result, self.root / "screens", True, suite="other")

    def test_exports_only_named_screens_and_requires_all(self):
        for index, name in enumerate(exporter.NAMES):
            self.add(name, f"0~fixture{index}")
        self.add("Unrelated screenshot", "0~unrelated")
        manifest = exporter.export(self.result, self.root / "screens", True)
        self.assertEqual(len(manifest["screenshots"]), len(exporter.NAMES))
        self.assertEqual(manifest["missing"], [])
        self.assertEqual(len(list((self.root / "screens").glob("*.png"))), len(exporter.NAMES))

    def test_missing_expected_screen_fails_visibly(self):
        self.add(exporter.NAMES[0])
        with self.assertRaisesRegex(ValueError, "Missing expected"):
            exporter.export(self.result, self.root / "screens", True)

    def test_optional_demo_login_failure_is_exported_without_becoming_required(self):
        for index, name in enumerate(exporter.NAMES):
            self.add(name, f"0~fixture{index}")
        self.add("demo-login-failure", "0~login-failure")
        manifest = exporter.export(self.result, self.root / "screens", True)
        self.assertEqual(manifest["missing"], [])
        self.assertTrue((self.root / "screens" / "demo-login-failure.png").exists())
        self.db.execute("DELETE FROM Attachments WHERE name='demo-login-failure'")
        self.db.commit()
        manifest = exporter.export(self.result, self.root / "screens", True)
        self.assertEqual(manifest["missing"], [])
        self.assertFalse((self.root / "screens" / "demo-login-failure.png").exists())

    def test_compact_optional_demo_login_failure_is_discovered(self):
        self.make_compact_result(include_optional=True)
        manifest = exporter.export(self.result, self.root / "screens", True)
        self.assertEqual([item["name"] for item in manifest["screenshots"]], list(exporter.EXPORT_NAMES))
        self.assertEqual(manifest["missing"], [])

    def test_compact_result_without_materialized_sqlite_index(self):
        self.make_compact_result()
        manifest = exporter.export(self.result, self.root / "screens", True)
        self.assertEqual(len(manifest["screenshots"]), len(exporter.NAMES))

    @unittest.skipIf(zstandard is None, "zstandard is installed by the native screenshot workflow")
    def test_compact_discovery_skips_unrelated_truncated_compressed_record(self):
        self.make_compact_result()
        (self.result / "Data" / "data.0~truncated-log").write_bytes(self.truncated_payload())
        with self.assertWarnsRegex(RuntimeWarning, "Skipped 1 unreadable"):
            manifest = exporter.export(self.result, self.root / "screens", True)
        self.assertEqual([item["name"] for item in manifest["screenshots"]], list(exporter.NAMES))
        self.assertEqual(manifest["missing"], [])
        self.assertEqual(len(list((self.root / "screens").glob("*.png"))), len(exporter.NAMES))

    def test_compact_discovery_skips_unrelated_unreadable_file(self):
        self.make_compact_result()
        unreadable = self.result / "Data" / "data.0~unreadable-log"
        unreadable.touch()
        read_bytes = pathlib.Path.read_bytes

        def read(path):
            if path == unreadable:
                raise PermissionError("Unreadable diagnostic")
            return read_bytes(path)

        with mock.patch.object(pathlib.Path, "read_bytes", read):
            with self.assertWarnsRegex(RuntimeWarning, "Skipped 1 unreadable"):
                manifest = exporter.export(self.result, self.root / "screens", True)
        self.assertEqual(len(manifest["screenshots"]), len(exporter.NAMES))

    @unittest.skipIf(zstandard is None, "zstandard is installed by the native screenshot workflow")
    def test_corrupt_requested_payload_still_fails_loudly(self):
        self.make_compact_result()
        (self.result / "Data" / "data.0~compact0").write_bytes(self.truncated_payload())
        for require_all in (False, True):
            with self.subTest(require_all=require_all):
                with self.assertWarnsRegex(RuntimeWarning, "Skipped 1 unreadable"):
                    with self.assertRaisesRegex(ValueError, "Cannot read snapshot 00-login"):
                        exporter.export(self.result, self.root / "screens", require_all)
                self.assertFalse((self.root / "screens" / "00-login.png").exists())

    def test_missing_requested_payload_still_fails_loudly(self):
        self.make_compact_result()
        (self.result / "Data" / "data.0~compact0").unlink()
        with self.assertRaisesRegex(ValueError, "Cannot read snapshot 00-login"):
            exporter.export(self.result, self.root / "screens", True)

    @unittest.skipIf(zstandard is None, "zstandard is installed by the native screenshot workflow")
    def test_corrupt_metadata_does_not_invent_screenshots(self):
        self.make_compact_result()
        (self.result / "Data" / "data.0~metadata").write_bytes(self.truncated_payload())
        with self.assertWarnsRegex(RuntimeWarning, "Skipped 1 unreadable"):
            manifest = exporter.export(self.result, self.root / "screens")
        self.assertEqual(manifest["screenshots"], [])
        self.assertEqual(manifest["missing"], list(exporter.NAMES))
        self.assertFalse(list((self.root / "screens").glob("*.png")))
        with self.assertWarnsRegex(RuntimeWarning, "Skipped 1 unreadable"):
            with self.assertRaisesRegex(ValueError, "Missing expected screenshots"):
                exporter.export(self.result, self.root / "screens", True)

    def test_clears_stale_capture_from_previous_run(self):
        destination = self.root / "screens"
        destination.mkdir()
        (destination / (exporter.NAMES[0] + ".png")).write_bytes(exporter.PNG)
        exporter.export(self.result, destination)
        self.assertFalse(list(destination.glob("*.png")))

    def test_rejects_path_escape(self):
        self.db.execute("INSERT INTO Attachments VALUES (?, '../outside', 'public.png', 0)", (exporter.NAMES[0],))
        self.db.commit()
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            exporter.export(self.result, self.root / "screens")


if __name__ == "__main__":
    unittest.main()
