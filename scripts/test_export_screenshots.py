import importlib.util
import pathlib
import sqlite3
import tempfile
import unittest

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
        records = bytearray(b"[T")
        for index, name in enumerate(exporter.NAMES):
            ref = f"0~compact{index}"
            (self.result / "Data" / ("data." + ref)).write_bytes(exporter.PNG + b"fixture")
            records.extend((f"K4:name[S6:StringK2:_vV{len(name)}:{name}]"
                            f"K10:payloadRef[S9:ReferenceK2:id[S6:StringK2:_vV{len(ref)}:{ref}]]").encode())
        (self.result / "Data" / "data.0~metadata").write_bytes(records)
        self.db.close()
        (self.result / "database.sqlite3").unlink()
        manifest = exporter.export(self.result, self.root / "screens", True)
        self.assertEqual(len(manifest["screenshots"]), 4)

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
