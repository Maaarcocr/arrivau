"""Offline tests using the reviewed, actual Google 11.2.0 manifest bytes."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import tempfile
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("privacy_audit", ROOT / "audit-privacy-manifests.py")
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)
FIXTURES = ROOT / "tests/fixtures"
COMMIT = "2727f2af3eedf661795a2e465ad90af2ca63c1c1"
SENTINEL = "PRIVATE_KEY_TOKEN_NEVER_PRINT_4c0fea"
VENDOR_HASHES = {
    "GoogleNavigation": ("77a15a98ef432867b009b022c1733ede2a5a45261cb89bbda755ef147ea9700a",
                         "c7f16689430f2bf1a3b09c2181d867f8b50d4071"),
    "GoogleMaps": ("47734417f3f8617743fdfa6efdda9df04664f8a91519ff22208df9f022598501",
                   "9950df78f6c02c0c9ed8bbff8a624ce225517b30"),
    "GooglePlaces": ("e9d54ec15e10d13d97c44c262d315cf88a206f15a44c37f6c4d424189bcf28c5",
                     "73d4dc4932313526885605e3c48239266293fad8"),
}


class PrivacyAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.app = self.base / "private-archive/Products/Applications/Arrivau.app"
        self.app.mkdir(parents=True)
        self.ipa = self.base / "private-export.ipa"
        self.output = self.base / "signed-bundle-privacy-audit.json"
        self.manifests = {
            audit.MANIFEST: (FIXTURES / "arrivau-privacy" / audit.MANIFEST).read_bytes()
        }
        self.sdk_paths = {}
        for component in audit.GOOGLE_COMPONENTS:
            relative = f"{component}_{component}Target.bundle/{component}.bundle/{audit.MANIFEST}"
            self.sdk_paths[component] = relative
            self.manifests[relative] = (
                FIXTURES / "google-privacy-11.2.0" / component / audit.MANIFEST
            ).read_bytes()

    def materialize(self, archive=None, exported=None):
        archive = self.manifests if archive is None else archive
        exported = self.manifests if exported is None else exported
        for relative, data in archive.items():
            path = self.app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        with zipfile.ZipFile(self.ipa, "w") as archive_zip:
            for relative, data in exported.items():
                archive_zip.writestr("Payload/Arrivau.app/" + relative, data)

    def args(self):
        return ["--archive-app", str(self.app), "--ipa", str(self.ipa),
                "--output", str(self.output), "--commit-sha", COMMIT,
                "--run-id", "12345678901", "--run-attempt", "2", "--build-number", "27"]

    def run_audit(self, arguments=None, expected=0):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = audit.main(self.args() if arguments is None else arguments)
        self.assertEqual(result, expected, stderr.getvalue())
        for value in (SENTINEL, str(self.base), "Traceback"):
            self.assertNotIn(value, stdout.getvalue() + stderr.getvalue())
        self.assertEqual(stdout.getvalue(), "")
        if expected:
            self.assertFalse(self.output.exists())
        else:
            self.assertEqual(stderr.getvalue(), "")
            return json.loads(self.output.read_text())

    def test_vendor_fixtures_match_primary_source_blobs_and_embedded_canonical_data(self):
        app_bytes = self.manifests[audit.MANIFEST]
        self.assertEqual(hashlib.sha1(b"blob " + str(len(app_bytes)).encode() + b"\0" + app_bytes).hexdigest(),
                         "e39da3550c8836c2c2d543ba4c9f52a2a55edcc6")
        for component, relative in self.sdk_paths.items():
            data = self.manifests[relative]
            expected_sha256, expected_git_blob = VENDOR_HASHES[component]
            self.assertEqual(hashlib.sha256(data).hexdigest(), expected_sha256)
            git_blob = b"blob " + str(len(data)).encode() + b"\0" + data
            self.assertEqual(hashlib.sha1(git_blob).hexdigest(), expected_git_blob)
            self.assertNotIn("NSPrivacyTracking", plistlib.loads(data))
            self.assertEqual(audit.canonical_manifest(data), audit.GOOGLE_EXPECTED[component])

    def test_combined_real_manifests_with_spm_wrappers(self):
        self.materialize()
        report = self.run_audit()
        self.assertEqual(report["audit"], "Signed bundle privacy manifest audit")
        self.assertTrue(report["archive_export_declarations_match"])
        self.assertEqual(report["google_sdk_version"], "11.2.0")
        self.assertEqual(report["identifiers"]["commit_sha"], COMMIT)
        rows = {entry["component"]: entry for entry in report["manifests"]}
        self.assertEqual(set(rows), {"Arrivau", *audit.GOOGLE_COMPONENTS})
        navigation = {row["category"]: row for row in rows["GoogleNavigation"]["collected_data"]}
        self.assertTrue(navigation["NSPrivacyCollectedDataTypePreciseLocation"]["linked"])
        self.assertEqual(len(rows["GoogleMaps"]["collected_data"]), 5)
        self.assertFalse(rows["GooglePlaces"]["collected_data"][0]["linked"])
        self.assertTrue(all(not row["tracking"] for row in rows.values()))
        self.assertTrue(all(row["tracking_domain_count"] == 0 for row in rows.values()))
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)

    def test_binary_export_and_reordered_declarations_are_semantically_equivalent(self):
        exported = {}
        for relative, raw in self.manifests.items():
            obj = plistlib.loads(raw)
            for key in ("NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"):
                obj[key].reverse()
                for row in obj[key]:
                    for value in row.values():
                        if isinstance(value, list):
                            value.reverse()
            obj["NSPrivacyTracking"] = False
            exported[relative] = plistlib.dumps(obj, fmt=plistlib.FMT_BINARY)
        self.materialize(exported=exported)
        report = self.run_audit()
        self.assertTrue(all(row["archive_sha256"] != row["export_sha256"]
                            for row in report["manifests"]))

    def test_missing_root_and_each_sdk_fail_for_each_input(self):
        for missing in self.manifests:
            for side in ("archive", "exported"):
                with self.subTest(missing=missing, side=side):
                    shutil.rmtree(self.app)
                    self.app.mkdir(parents=True)
                    remaining = {key: value for key, value in self.manifests.items() if key != missing}
                    self.materialize(**{side: remaining})
                    self.run_audit(expected=1)

    def test_google_semantic_change_fails_even_when_both_inputs_match(self):
        relative = self.sdk_paths["GoogleNavigation"]
        obj = plistlib.loads(self.manifests[relative])
        obj["NSPrivacyCollectedDataTypes"][0]["NSPrivacyCollectedDataTypeLinked"] = True
        self.manifests[relative] = plistlib.dumps(obj)
        self.materialize()
        self.run_audit(expected=1)

    def test_export_semantic_mismatch_and_added_manifest_fail(self):
        for change in ("root", "additional"):
            with self.subTest(change=change):
                exported = dict(self.manifests)
                if change == "root":
                    obj = plistlib.loads(exported[audit.MANIFEST])
                    obj["NSPrivacyCollectedDataTypes"][0]["NSPrivacyCollectedDataTypeLinked"] = False
                    exported[audit.MANIFEST] = plistlib.dumps(obj)
                else:
                    exported["New.bundle/" + audit.MANIFEST] = plistlib.dumps({})
                self.materialize(exported=exported)
                self.run_audit(expected=1)

    def test_identical_google_bundle_copies_are_audited_and_duplicate_zip_entry_fails(self):
        self.manifests["OtherWrapper/GoogleMaps.bundle/" + audit.MANIFEST] = (
            self.manifests[self.sdk_paths["GoogleMaps"]])
        self.materialize()
        report = self.run_audit()
        self.assertEqual(len([row for row in report["manifests"]
                              if row["component"] == "GoogleMaps"]), 2)
        self.output.unlink()
        (self.app / "OtherWrapper/GoogleMaps.bundle/" / audit.MANIFEST).unlink()
        del self.manifests["OtherWrapper/GoogleMaps.bundle/" + audit.MANIFEST]
        self.materialize()
        with zipfile.ZipFile(self.ipa, "a") as archive_zip:
            with self.assertWarns(UserWarning):
                archive_zip.writestr("Payload/Arrivau.app/" + audit.MANIFEST,
                                    self.manifests[audit.MANIFEST])
        self.run_audit(expected=1)

    def test_additional_manifests_are_validated_included_and_redacted(self):
        domain = "private-tracking.example.com"
        relative = SENTINEL + ".bundle/" + audit.MANIFEST
        extra = {"NSPrivacyTracking": True, "NSPrivacyTrackingDomains": [domain],
                 "NSPrivacyCollectedDataTypes": [{
                     "NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeHealth",
                     "NSPrivacyCollectedDataTypeLinked": True,
                     "NSPrivacyCollectedDataTypeTracking": True,
                     "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAnalytics"],
                 }]}
        self.manifests[relative] = plistlib.dumps(extra)
        self.materialize()
        report = self.run_audit()
        self.assertNotIn(domain, self.output.read_text())
        self.assertNotIn(SENTINEL, self.output.read_text())
        row = next(row for row in report["manifests"] if row["component"] == "Additional manifest")
        self.assertEqual(row["tracking_domain_count"], 1)
        self.assertTrue(row["tracking"])
        self.assertEqual(row["collected_data"][0]["category"], "NSPrivacyCollectedDataTypeHealth")

    def test_tracking_domain_semantics_are_compared_without_reporting_domains(self):
        extra_path = "Extra.bundle/" + audit.MANIFEST
        first = {"NSPrivacyTracking": True, "NSPrivacyTrackingDomains": ["one.example.com"]}
        second = {"NSPrivacyTracking": True, "NSPrivacyTrackingDomains": ["two.example.com"]}
        self.manifests[extra_path] = plistlib.dumps(first)
        exported = dict(self.manifests)
        exported[extra_path] = plistlib.dumps(second)
        self.materialize(exported=exported)
        self.run_audit(expected=1)

    def test_unknown_additional_manifest_fields_fail_closed_without_echo(self):
        self.manifests[SENTINEL + ".bundle/" + audit.MANIFEST] = plistlib.dumps({SENTINEL: SENTINEL})
        self.materialize()
        self.run_audit(expected=1)

    def test_malformed_values_never_escape_to_diagnostic_or_report(self):
        valid = plistlib.loads(self.manifests[audit.MANIFEST])
        mutations = [
            {"NSPrivacyTracking": SENTINEL}, {"NSPrivacyTracking": 0},
            {"NSPrivacyTracking": True}, {"NSPrivacyTrackingDomains": SENTINEL},
            {"NSPrivacyTracking": True, "NSPrivacyTrackingDomains": [SENTINEL + "/key"]},
            {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": ["private.example.com"]},
            {"NSPrivacyCollectedDataTypes": SENTINEL}, {"NSPrivacyAccessedAPITypes": SENTINEL},
            {SENTINEL: True},
        ]
        for key, value in [("NSPrivacyCollectedDataType", SENTINEL),
                           ("NSPrivacyCollectedDataTypeLinked", 1),
                           ("NSPrivacyCollectedDataTypeTracking", SENTINEL),
                           ("NSPrivacyCollectedDataTypePurposes", [SENTINEL]),
                           ("NSPrivacyCollectedDataTypePurposes", []), (SENTINEL, SENTINEL)]:
            row = dict(valid["NSPrivacyCollectedDataTypes"][0])
            row[key] = value
            mutations.append({"NSPrivacyCollectedDataTypes": [row]})
        for category, reasons in [(SENTINEL, ["CA92.1"]),
                                  ("NSPrivacyAccessedAPICategoryUserDefaults", [SENTINEL]),
                                  ("NSPrivacyAccessedAPICategoryUserDefaults", ["C617.1"]),
                                  ("NSPrivacyAccessedAPICategoryUserDefaults", []),
                                  ("NSPrivacyAccessedAPICategoryUserDefaults", ["CA92.1", "CA92.1"])]:
            mutations.append({"NSPrivacyAccessedAPITypes": [{
                "NSPrivacyAccessedAPIType": category, "NSPrivacyAccessedAPITypeReasons": reasons}]})
        for obj in mutations:
            with self.subTest(obj=obj):
                self.manifests[audit.MANIFEST] = plistlib.dumps(obj)
                self.materialize()
                self.run_audit(expected=1)

    def test_malformed_xml_unknown_elements_and_duplicate_keys_fail(self):
        invalid = [
            b"not a plist " + SENTINEL.encode(),
            b'<plist version="1.0"><dict><key>NSPrivacyTracking</key><false/><key>NSPrivacyTracking</key><false/></dict></plist>',
            b'<plist version="1.0"><dict><secret>' + SENTINEL.encode() + b'</secret></dict></plist>',
            b'<plist version="1.0"><dict><key>NSPrivacyTracking</key><false>secret</false></dict></plist>',
            b'<!DOCTYPE plist [<!ENTITY secret "private">]><plist version="1.0"><dict/></plist>',
        ]
        for raw in invalid:
            with self.subTest(raw=raw[:50]):
                self.manifests[audit.MANIFEST] = raw
                self.materialize()
                self.run_audit(expected=1)

    def test_other_payloads_are_never_opened_in_archive_or_ipa(self):
        self.materialize()
        for name in ("Info.plist", "Secrets.xcconfig", "auth.p8", "embedded.mobileprovision", "Arrivau", "private.log"):
            (self.app / name).write_text(SENTINEL)
            with zipfile.ZipFile(self.ipa, "a") as archive_zip:
                archive_zip.writestr("Payload/Arrivau.app/" + name, SENTINEL)
        original_open, original_zip_open = os.open, zipfile.ZipFile.open
        accessed_files, accessed_entries = [], []
        def guarded_open(path, flags, *args, **kwargs):
            accessed_files.append(Path(path).name)
            self.assertIn(Path(path).name, (audit.MANIFEST, self.output.name))
            return original_open(path, flags, *args, **kwargs)
        def guarded_zip_open(zip_self, name, *args, **kwargs):
            entry_name = name.filename if isinstance(name, zipfile.ZipInfo) else name
            accessed_entries.append(entry_name)
            self.assertEqual(Path(entry_name).name, audit.MANIFEST)
            return original_zip_open(zip_self, name, *args, **kwargs)
        with mock.patch.object(os, "open", side_effect=guarded_open), \
             mock.patch.object(zipfile.ZipFile, "open", guarded_zip_open):
            self.run_audit()
        self.assertEqual(accessed_files.count(audit.MANIFEST), 4)
        self.assertEqual(len(accessed_entries), 4)
        self.assertNotIn(SENTINEL, self.output.read_text())

    def test_symlink_and_hardlink_manifests_cannot_read_key_file(self):
        self.materialize()
        target = self.base / "auth.p8"
        target.write_text(SENTINEL)
        manifest = self.app / audit.MANIFEST
        for kind in ("symlink", "hardlink"):
            with self.subTest(kind=kind):
                manifest.unlink()
                if kind == "symlink":
                    manifest.symlink_to(target)
                else:
                    os.link(target, manifest)
                self.run_audit(expected=1)

    def test_bad_identifiers_and_arguments_fail_before_reading_inputs(self):
        for flag in ("--commit-sha", "--run-id", "--run-attempt", "--build-number"):
            args = self.args()
            args[args.index(flag) + 1] = SENTINEL
            with mock.patch.object(audit, "archive_manifests") as read_archive:
                self.run_audit(args, expected=1)
                read_archive.assert_not_called()
        self.run_audit(self.args() + ["--" + SENTINEL], expected=1)

    def test_failed_report_write_does_not_retain_partial_json(self):
        self.materialize()
        with mock.patch.object(json, "dump", side_effect=OSError(SENTINEL)):
            self.run_audit(expected=1)


if __name__ == "__main__":
    unittest.main()
