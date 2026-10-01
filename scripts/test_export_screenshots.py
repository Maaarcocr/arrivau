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

    def make_compact_result(self):
        records = bytearray(b"[T")
        for index, name in enumerate(exporter.NAMES):
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

    def test_exports_only_named_screens_and_requires_all(self):
        for index, name in enumerate(exporter.NAMES):
            self.add(name, f"0~fixture{index}")
        self.add("Unrelated screenshot", "0~unrelated")
        manifest = exporter.export(self.result, self.root / "screens", True)
        self.assertEqual(len(manifest["screenshots"]), 4)
        self.assertEqual(manifest["missing"], [])
        self.assertEqual(len(list((self.root / "screens").glob("*.png"))), 4)

    def test_missing_expected_screen_fails_visibly(self):
        self.add(exporter.NAMES[0])
        with self.assertRaisesRegex(ValueError, "Missing expected"):
            exporter.export(self.result, self.root / "screens", True)

    def test_compact_result_without_materialized_sqlite_index(self):
        self.make_compact_result()
        manifest = exporter.export(self.result, self.root / "screens", True)
        self.assertEqual(len(manifest["screenshots"]), 4)

    @unittest.skipIf(zstandard is None, "zstandard is installed by the native screenshot workflow")
    def test_compact_discovery_skips_unrelated_truncated_compressed_record(self):
        self.make_compact_result()
        (self.result / "Data" / "data.0~truncated-log").write_bytes(self.truncated_payload())
        with self.assertWarnsRegex(RuntimeWarning, "Skipped 1 unreadable"):
            manifest = exporter.export(self.result, self.root / "screens", True)
        self.assertEqual([item["name"] for item in manifest["screenshots"]], list(exporter.NAMES))
        self.assertEqual(manifest["missing"], [])
        self.assertEqual(len(list((self.root / "screens").glob("*.png"))), 4)

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
        self.assertEqual(len(manifest["screenshots"]), 4)

    @unittest.skipIf(zstandard is None, "zstandard is installed by the native screenshot workflow")
    def test_corrupt_requested_payload_still_fails_loudly(self):
        self.make_compact_result()
        (self.result / "Data" / "data.0~compact0").write_bytes(self.truncated_payload())
        for require_all in (False, True):
            with self.subTest(require_all=require_all):
                with self.assertWarnsRegex(RuntimeWarning, "Skipped 1 unreadable"):
                    with self.assertRaisesRegex(ValueError, "Cannot read snapshot 01-dispatcher-jobs"):
                        exporter.export(self.result, self.root / "screens", require_all)
                self.assertFalse((self.root / "screens" / "01-dispatcher-jobs.png").exists())

    def test_missing_requested_payload_still_fails_loudly(self):
        self.make_compact_result()
        (self.result / "Data" / "data.0~compact0").unlink()
        with self.assertRaisesRegex(ValueError, "Cannot read snapshot 01-dispatcher-jobs"):
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
