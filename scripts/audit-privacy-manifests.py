#!/usr/bin/env python3
"""Audit signed Arrivau bundle privacy declarations, without reading other payloads.

The caller verifies signing and invokes this before private archive/IPA cleanup.
This is a declaration audit, not an Xcode Privacy Report or legal certification.
No runtime network, environment, Info.plist, profile, key, or log reads.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import sys
import xml.etree.ElementTree as ET
import zipfile


MANIFEST = "PrivacyInfo.xcprivacy"
MAX_BYTES = 1024 * 1024
MAX_MANIFESTS = 256
GOOGLE_COMPONENTS = ("GoogleNavigation", "GoogleMaps", "GooglePlaces")
ROOT_KEYS = {
    "NSPrivacyTracking", "NSPrivacyTrackingDomains",
    "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes",
}
DATA_KEYS = {
    "NSPrivacyCollectedDataType", "NSPrivacyCollectedDataTypeLinked",
    "NSPrivacyCollectedDataTypeTracking", "NSPrivacyCollectedDataTypePurposes",
}
API_KEYS = {"NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"}
# Apple Bundle Resources schema/reasons reviewed 2026-10-05. Unknown additions
# deliberately require a code review; see the fixture README for primary sources.
DATA_TYPES = {"NSPrivacyCollectedDataType" + name for name in (
    "Name EmailAddress PhoneNumber PhysicalAddress OtherUserContactInfo Health "
    "Fitness PaymentInfo CreditInfo OtherFinancialInfo PreciseLocation "
    "CoarseLocation SensitiveInfo Contacts EmailsOrTextMessages PhotosorVideos "
    "AudioData GameplayContent CustomerSupport OtherUserContent BrowsingHistory "
    "SearchHistory UserID DeviceID PurchaseHistory ProductInteraction "
    "AdvertisingData OtherUsageData CrashData PerformanceData OtherDiagnosticData "
    "EnvironmentScanning Hands Head OtherDataTypes"
).split()}
PURPOSES = {"NSPrivacyCollectedDataTypePurpose" + name for name in (
    "ThirdPartyAdvertising DeveloperAdvertising Analytics ProductPersonalization "
    "AppFunctionality Other"
).split()}
API_REASONS = {"NSPrivacyAccessedAPICategory" + category: set(reasons.split())
               for category, reasons in {
                   "FileTimestamp": "DDA9.1 C617.1 3B52.1 0A2A.1",
                   "SystemBootTime": "35F9.1 8FFB.1 3D61.1",
                   "DiskSpace": "85F4.1 E174.1 7D9E.1 B728.1",
                   "ActiveKeyboards": "3EC4.1 54BD.1",
                   "UserDefaults": "CA92.1 1C8F.1 C56D.1 AC6B.1",
               }.items()}


class AuditError(Exception):
    """Messages must be fixed strings, never values or paths from inputs."""


def require(condition, code="invalid-manifest"):
    if not condition:
        raise AuditError(code)


class UniqueDict(dict):
    def __setitem__(self, key, value):
        require(key not in self, "duplicate-manifest-key")
        super().__setitem__(key, value)


def validate_xml(data):
    """plistlib ignores some unknown XML elements; reject those explicitly."""
    root = ET.fromstring(data)
    require(root.tag == "plist" and root.attrib == {"version": "1.0"})
    require(len(root) == 1 and root[0].tag == "dict")
    for node in root.iter():
        require(node.tag in {"plist", "dict", "array", "key", "string", "true", "false"})
        require(node is root or not node.attrib)
        require(not node.tail or not node.tail.strip())
        if node.tag in {"key", "string", "true", "false"}:
            require(not len(node))
        if node.tag not in {"key", "string"}:
            require(not node.text or not node.text.strip())
        if node.tag == "dict":
            require(len(node) % 2 == 0)
            require(all(node[i].tag == "key" and node[i + 1].tag in {
                            "dict", "array", "string", "true", "false"}
                        for i in range(0, len(node), 2)))
        if node.tag == "array":
            require(all(child.tag not in {"plist", "key"} for child in node))


def enum_value(value, allowed):
    require(type(value) is str and value in allowed)
    return value


def string_list(value, allowed=None, nonempty=False):
    require(type(value) is list and (not nonempty or len(value) > 0))
    require(all(type(item) is str for item in value))
    require(len(value) == len(set(value)))
    if allowed is not None:
        require(all(item in allowed for item in value))
    return sorted(value)


def canonical_manifest(data):
    """Validate before any input value can enter the retained report."""
    require(0 < len(data) <= MAX_BYTES, "manifest-size-limit")
    try:
        # plistlib rejects XML entity declarations before the structure pass.
        obj = plistlib.loads(data, dict_type=UniqueDict)
        if not data.startswith(b"bplist00"):
            validate_xml(data)
    except AuditError:
        raise
    except Exception:
        raise AuditError("malformed-manifest") from None
    require(isinstance(obj, dict) and set(obj) <= ROOT_KEYS)
    tracking = obj.get("NSPrivacyTracking", False)  # Apple's documented default.
    require(type(tracking) is bool)
    domains = string_list(obj.get("NSPrivacyTrackingDomains", []))
    domain_pattern = r"(?=.{1,253}\Z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    require(all(re.fullmatch(domain_pattern, domain) for domain in domains))
    require(tracking == bool(domains), "inconsistent-tracking-declaration")
    # Domains remain private in memory for the exact semantic comparison only.
    domains = sorted(domain.lower() for domain in domains)
    require(len(domains) == len(set(domains)))
    collected = obj.get("NSPrivacyCollectedDataTypes", [])
    accessed = obj.get("NSPrivacyAccessedAPITypes", [])
    require(type(collected) is list and type(accessed) is list)
    data_rows, api_rows = [], []
    for row in collected:
        require(isinstance(row, dict) and set(row) == DATA_KEYS)
        category = enum_value(row["NSPrivacyCollectedDataType"], DATA_TYPES)
        linked = row["NSPrivacyCollectedDataTypeLinked"]
        used_for_tracking = row["NSPrivacyCollectedDataTypeTracking"]
        require(type(linked) is bool and type(used_for_tracking) is bool)
        require(not used_for_tracking or tracking, "inconsistent-tracking-declaration")
        purposes = string_list(row["NSPrivacyCollectedDataTypePurposes"], PURPOSES, True)
        data_rows.append({"category": category, "linked": linked,
                          "tracking": used_for_tracking, "purposes": purposes})
    for row in accessed:
        require(isinstance(row, dict) and set(row) == API_KEYS)
        category = enum_value(row["NSPrivacyAccessedAPIType"], API_REASONS)
        reasons = string_list(row["NSPrivacyAccessedAPITypeReasons"], API_REASONS[category], True)
        api_rows.append({"category": category, "reasons": reasons})
    require(len(data_rows) == len({row["category"] for row in data_rows}))
    require(len(api_rows) == len({row["category"] for row in api_rows}))
    return {"tracking": tracking, "tracking_domains": domains,
            "collected_data": sorted(data_rows, key=lambda row: row["category"]),
            "required_reason_apis": sorted(api_rows, key=lambda row: row["category"])}


# Canonical declarations generated from the three byte-exact official 11.2.0
# manifests committed as tests/fixtures/google-privacy-11.2.0, not from SDK prose.
GOOGLE_EXPECTED = {'GoogleNavigation': {'tracking': False,
                      'tracking_domains': [],
                      'collected_data': [{'category': 'NSPrivacyCollectedDataTypeCrashData',
                                          'linked': False,
                                          'tracking': False,
                                          'purposes': ['NSPrivacyCollectedDataTypePurposeAnalytics',
                                                       'NSPrivacyCollectedDataTypePurposeAppFunctionality']},
                                         {'category': 'NSPrivacyCollectedDataTypeDeviceID',
                                          'linked': True,
                                          'tracking': False,
                                          'purposes': ['NSPrivacyCollectedDataTypePurposeAnalytics',
                                                       'NSPrivacyCollectedDataTypePurposeAppFunctionality']},
                                         {'category': 'NSPrivacyCollectedDataTypeOtherDataTypes',
                                          'linked': True,
                                          'tracking': False,
                                          'purposes': ['NSPrivacyCollectedDataTypePurposeAnalytics']},
                                         {'category': 'NSPrivacyCollectedDataTypePerformanceData',
                                          'linked': False,
                                          'tracking': False,
                                          'purposes': ['NSPrivacyCollectedDataTypePurposeAnalytics']},
                                         {'category': 'NSPrivacyCollectedDataTypePreciseLocation',
                                          'linked': True,
                                          'tracking': False,
                                          'purposes': ['NSPrivacyCollectedDataTypePurposeAnalytics',
                                                       'NSPrivacyCollectedDataTypePurposeAppFunctionality']},
                                         {'category': 'NSPrivacyCollectedDataTypeProductInteraction',
                                          'linked': False,
                                          'tracking': False,
                                          'purposes': ['NSPrivacyCollectedDataTypePurposeAnalytics']}],
                      'required_reason_apis': [{'category': 'NSPrivacyAccessedAPICategoryDiskSpace',
                                                'reasons': ['85F4.1', 'E174.1']},
                                               {'category': 'NSPrivacyAccessedAPICategoryFileTimestamp',
                                                'reasons': ['C617.1']},
                                               {'category': 'NSPrivacyAccessedAPICategorySystemBootTime',
                                                'reasons': ['35F9.1']},
                                               {'category': 'NSPrivacyAccessedAPICategoryUserDefaults',
                                                'reasons': ['1C8F.1', 'CA92.1']}]},
 'GoogleMaps': {'tracking': False,
                'tracking_domains': [],
                'collected_data': [{'category': 'NSPrivacyCollectedDataTypeCrashData',
                                    'linked': False,
                                    'tracking': False,
                                    'purposes': ['NSPrivacyCollectedDataTypePurposeAnalytics']},
                                   {'category': 'NSPrivacyCollectedDataTypeDeviceID',
                                    'linked': True,
                                    'tracking': False,
                                    'purposes': ['NSPrivacyCollectedDataTypePurposeAnalytics',
                                                 'NSPrivacyCollectedDataTypePurposeAppFunctionality']},
                                   {'category': 'NSPrivacyCollectedDataTypeOtherDataTypes',
                                    'linked': True,
                                    'tracking': False,
                                    'purposes': ['NSPrivacyCollectedDataTypePurposeAnalytics']},
                                   {'category': 'NSPrivacyCollectedDataTypePerformanceData',
                                    'linked': False,
                                    'tracking': False,
                                    'purposes': ['NSPrivacyCollectedDataTypePurposeAnalytics']},
                                   {'category': 'NSPrivacyCollectedDataTypeProductInteraction',
                                    'linked': False,
                                    'tracking': False,
                                    'purposes': ['NSPrivacyCollectedDataTypePurposeAnalytics']}],
                'required_reason_apis': [{'category': 'NSPrivacyAccessedAPICategoryDiskSpace',
                                          'reasons': ['85F4.1', 'E174.1']},
                                         {'category': 'NSPrivacyAccessedAPICategoryFileTimestamp',
                                          'reasons': ['C617.1']},
                                         {'category': 'NSPrivacyAccessedAPICategorySystemBootTime',
                                          'reasons': ['35F9.1']},
                                         {'category': 'NSPrivacyAccessedAPICategoryUserDefaults',
                                          'reasons': ['1C8F.1', 'CA92.1']}]},
 'GooglePlaces': {'tracking': False,
                  'tracking_domains': [],
                  'collected_data': [{'category': 'NSPrivacyCollectedDataTypeDeviceID',
                                      'linked': False,
                                      'tracking': False,
                                      'purposes': ['NSPrivacyCollectedDataTypePurposeAnalytics',
                                                   'NSPrivacyCollectedDataTypePurposeAppFunctionality']}],
                  'required_reason_apis': [{'category': 'NSPrivacyAccessedAPICategoryFileTimestamp',
                                            'reasons': ['C617.1']},
                                           {'category': 'NSPrivacyAccessedAPICategoryUserDefaults',
                                            'reasons': ['1C8F.1', 'CA92.1']}]}}


def read_manifest(path):
    require(path.name == MANIFEST, "unexpected-manifest-name")
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as handle:
        info = os.fstat(handle.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                "unsafe-manifest-file")
        require(info.st_size <= MAX_BYTES, "manifest-size-limit")
        return handle.read(MAX_BYTES + 1)


def archive_manifests(app):
    require(app.name == "Arrivau.app" and app.is_dir() and not app.is_symlink(),
            "invalid-archive-app")
    manifests = {}
    def walk_error(_error):
        raise AuditError("unreadable-archive-directory")
    for directory, dirs, files in os.walk(app, followlinks=False, onerror=walk_error):
        require(not any((Path(directory) / name).is_symlink() for name in dirs),
                "unsafe-archive-directory")
        for name in files:
            if name.endswith(".xcprivacy"):
                require(name == MANIFEST, "unexpected-manifest-name")
                path = Path(directory) / name
                manifests[path.relative_to(app).as_posix()] = read_manifest(path)
                require(len(manifests) <= MAX_MANIFESTS, "manifest-count-limit")
    return manifests


def ipa_manifests(ipa):
    manifests = {}
    prefix = "Payload/Arrivau.app/"
    with zipfile.ZipFile(ipa) as archive:
        for entry in archive.infolist():
            name = entry.filename
            if not name.startswith(prefix) or not name.endswith(".xcprivacy"):
                continue
            parts = PurePosixPath(name).parts
            require(".." not in parts and "\\" not in name and "//" not in name,
                    "unsafe-ipa-manifest-path")
            require(parts[-1] == MANIFEST, "unexpected-manifest-name")
            require(not stat.S_ISLNK(entry.external_attr >> 16), "unsafe-manifest-file")
            require(not entry.flag_bits & 1 and entry.file_size <= MAX_BYTES,
                    "unreadable-ipa-manifest")
            relative = name[len(prefix):]
            require(relative not in manifests, "duplicate-ipa-manifest")
            with archive.open(entry) as handle:
                manifests[relative] = handle.read(MAX_BYTES + 1)
            require(len(manifests) <= MAX_MANIFESTS, "manifest-count-limit")
    return manifests


def component_for(relative):
    if relative == MANIFEST:
        return "Arrivau"
    parent = PurePosixPath(relative).parent.name
    for component in GOOGLE_COMPONENTS:
        if parent == component + ".bundle":
            return component
    return "Additional manifest"


def validate_bundle(manifests):
    require(MANIFEST in manifests, "missing-app-manifest")
    components = {component: 0 for component in GOOGLE_COMPONENTS}
    parsed = {}
    for relative, data in sorted(manifests.items()):
        component = component_for(relative)
        declaration = canonical_manifest(data)
        if component in components:
            components[component] += 1
            require(declaration == GOOGLE_EXPECTED[component], "google-declaration-mismatch")
        parsed[relative] = declaration
    require(all(count >= 1 for count in components.values()), "missing-google-manifest")
    return parsed


def identifiers(commit_sha, run_id, run_attempt, build_number):
    require(bool(re.fullmatch(r"[0-9a-fA-F]{40}", commit_sha)), "invalid-commit-identifier")
    require(bool(re.fullmatch(r"[1-9][0-9]{0,19}", run_id)), "invalid-run-identifier")
    require(bool(re.fullmatch(r"[1-9][0-9]{0,5}", run_attempt)), "invalid-run-attempt")
    require(bool(re.fullmatch(r"[1-9][0-9]{0,3}", build_number)), "invalid-build-number")
    return {"commit_sha": commit_sha.lower(), "run_id": run_id,
            "run_attempt": run_attempt, "build_number": build_number}


def audit(archive_app, ipa, commit_sha, run_id, run_attempt, build_number):
    identity = identifiers(commit_sha, run_id, run_attempt, build_number)
    archive = archive_manifests(Path(archive_app))
    exported = ipa_manifests(Path(ipa))
    archive_parsed, exported_parsed = validate_bundle(archive), validate_bundle(exported)
    require(archive_parsed == exported_parsed, "archive-export-declaration-mismatch")
    entries = []
    for relative, declaration in sorted(archive_parsed.items()):
        # No filesystem or ZIP paths, domain strings, or unknown values escape.
        entries.append({"component": component_for(relative), "manifest_present": True,
                        "archive_sha256": hashlib.sha256(archive[relative]).hexdigest(),
                        "export_sha256": hashlib.sha256(exported[relative]).hexdigest(),
                        "tracking": declaration["tracking"],
                        "tracking_domain_count": len(declaration["tracking_domains"]),
                        "collected_data": declaration["collected_data"],
                        "required_reason_apis": declaration["required_reason_apis"]})
    return {"audit": "Signed bundle privacy manifest audit", "schema_version": 1,
            "identifiers": identity, "google_sdk_version": "11.2.0",
            "archive_export_declarations_match": True, "manifests": entries}


class SafeParser(argparse.ArgumentParser):
    def error(self, _message):
        raise AuditError("invalid-command-arguments")


def main(argv=None):
    try:
        parser = SafeParser(description=__doc__)
        for name in ("archive-app", "ipa", "output", "commit-sha", "run-id", "run-attempt", "build-number"):
            parser.add_argument("--" + name, required=True)
        args = parser.parse_args(argv)
        output = Path(args.output)
        require(output.suffix == ".json" and not output.exists(), "invalid-report-destination")
        require(not output.resolve().is_relative_to(Path(args.archive_app).resolve()),
                "invalid-report-destination")
        report = audit(args.archive_app, args.ipa, args.commit_sha, args.run_id,
                       args.run_attempt, args.build_number)
        # No partial or failed audit is retained. Exclusive creation prevents
        # accidentally replacing an existing artifact or following a symlink.
        fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(report, handle, indent=2, sort_keys=True)
                handle.write("\n")
        except Exception:
            output.unlink(missing_ok=True)
            raise
    except AuditError as error:
        print("Signed bundle privacy manifest audit failed: " + str(error), file=sys.stderr)
        return 1
    except Exception:
        # OSError, plist, ZIP, and argument diagnostics can contain private data.
        print("Signed bundle privacy manifest audit failed: unreadable-input-or-output", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
