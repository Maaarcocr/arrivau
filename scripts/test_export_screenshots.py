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

    def test_rejects_path_escape(self):
        self.db.execute("INSERT INTO Attachments VALUES (?, '../outside', 'public.png', 0)", (exporter.NAMES[0],))
        self.db.commit()
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            exporter.export(self.result, self.root / "screens")


if __name__ == "__main__":
    unittest.main()
