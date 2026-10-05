#!/usr/bin/env python3
"""Verify the credential-free archive regression test. Never dump Xcode settings."""

import importlib.util
import json
from pathlib import Path
import plistlib
import shlex
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_settings(path, overlay):
    expected = overlay["targets"]["Arrivau"]["settings"]["configs"]["Release"]
    records = json.loads(Path(path).read_text())
    targets = {record["target"]: record["buildSettings"] for record in records}
    require("Arrivau" in targets, "ARCHIVE_SETTINGS_APP_MISSING")
    require({"ArrivauTests", "ArrivauUITests"}.issubset(targets), "ARCHIVE_SETTINGS_TEST_TARGETS_MISSING")
    for name, settings in targets.items():
        if name == "Arrivau":
            for key, value in expected.items():
                actual = settings.get(key, "")
                if key == "OTHER_CODE_SIGN_FLAGS":
                    require(shlex.split(actual) == shlex.split(value), "ARCHIVE_SETTINGS_APP_MISMATCH")
                else:
                    require(actual == value, "ARCHIVE_SETTINGS_APP_MISMATCH")
        else:
            for key in ("INFOPLIST_FILE", "DEVELOPMENT_TEAM", "PRODUCT_BUNDLE_IDENTIFIER",
                        "CURRENT_PROJECT_VERSION", "ARRIVAU_API_URL", "CODE_SIGN_IDENTITY"):
                require(settings.get(key) != expected[key], "ARCHIVE_SETTINGS_CROSS_TARGET_LEAK")
            require(not settings.get("PROVISIONING_PROFILE_SPECIFIER"), "ARCHIVE_SETTINGS_PROFILE_LEAK")
            require(expected["OTHER_CODE_SIGN_FLAGS"] not in settings.get("OTHER_CODE_SIGN_FLAGS", ""),
                    "ARCHIVE_SETTINGS_KEYCHAIN_LEAK")
            require(settings.get("CODE_SIGN_STYLE") != "Manual", "ARCHIVE_SETTINGS_SIGN_STYLE_LEAK")
        require(not settings.get("ARRIVAU_GOOGLE_MAPS_API_KEY"), "ARCHIVE_SETTINGS_API_KEY_LEAK")


def verify_bundle(app_path, overlay):
    app = Path(app_path)
    expected = overlay["targets"]["Arrivau"]["settings"]["configs"]["Release"]
    private_info = plistlib.loads(Path(expected["INFOPLIST_FILE"]).read_bytes())
    info = plistlib.loads((app / "Info.plist").read_bytes())
    for plist_key, setting_key in (("CFBundleIdentifier", "PRODUCT_BUNDLE_IDENTIFIER"),
                                   ("CFBundleVersion", "CURRENT_PROJECT_VERSION"),
                                   ("ARRIVAU_API_URL", "ARRIVAU_API_URL")):
        require(info.get(plist_key) == expected[setting_key], "ARCHIVE_BUNDLE_APP_MISMATCH")
    key = "ARRIVAU_GOOGLE_MAPS_API_KEY"
    require(info.get(key) == private_info[key] and bool(info[key]), "ARCHIVE_BUNDLE_APP_KEY_MISSING")
    bundles = list(app.rglob("*.bundle"))
    # Google 11.2.0 wraps each copied vendor bundle in a SwiftPM resource bundle.
    for sdk in ("GoogleMaps", "GooglePlaces", "GoogleNavigation"):
        wrappers = [path for path in bundles if path.name.startswith(sdk + "_")]
        require(bool(wrappers), "ARCHIVE_BUNDLE_SDK_WRAPPER_MISSING")
        require(all((path / "Info.plist").is_file() for path in wrappers), "ARCHIVE_BUNDLE_SDK_PLIST_MISSING")
        require(any(path.name == sdk + ".bundle" for path in bundles), "ARCHIVE_BUNDLE_SDK_RESOURCES_MISSING")
    for bundle in bundles:
        plist = bundle / "Info.plist"
        if not plist.is_file():
            continue
        resource = plistlib.loads(plist.read_bytes())
        require(resource.get("CFBundleIdentifier") != info["CFBundleIdentifier"], "ARCHIVE_BUNDLE_SDK_ID_LEAK")
        require(not any(name.startswith("ARRIVAU_") for name in resource), "ARCHIVE_BUNDLE_SDK_CONFIG_LEAK")
        require(private_info[key].encode() not in plist.read_bytes(), "ARCHIVE_BUNDLE_SDK_KEY_LEAK")


def verify_privacy(app_path):
    # Reuse the read-only declaration checks on the real unsigned CI archive.
    # This intentionally makes no signature or exported-IPA verification claim.
    spec = importlib.util.spec_from_file_location("privacy_audit", Path(__file__).with_name("audit-privacy-manifests.py"))
    audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(audit)
    try:
        audit.validate_bundle(audit.archive_manifests(Path(app_path)))
    except Exception:
        raise ValueError("ARCHIVE_BUNDLE_PRIVACY_DECLARATIONS_INVALID") from None


def main(args):
    try:
        operation, path, overlay_path = args
        overlay = json.loads(Path(overlay_path).read_text())
        if operation == "settings":
            verify_settings(path, overlay)
        elif operation == "bundle":
            verify_bundle(path, overlay)
        elif operation == "privacy":
            verify_privacy(path)
        else:
            raise ValueError("ARCHIVE_SCOPING_INVALID_OPERATION")
    except ValueError as error:
        # Only allow our hand-written enum values, not parser/error contents.
        allowed = {
            "ARCHIVE_SETTINGS_APP_MISSING", "ARCHIVE_SETTINGS_TEST_TARGETS_MISSING", "ARCHIVE_SETTINGS_APP_MISMATCH",
            "ARCHIVE_SETTINGS_CROSS_TARGET_LEAK", "ARCHIVE_SETTINGS_PROFILE_LEAK", "ARCHIVE_SETTINGS_KEYCHAIN_LEAK",
            "ARCHIVE_SETTINGS_SIGN_STYLE_LEAK", "ARCHIVE_SETTINGS_API_KEY_LEAK", "ARCHIVE_BUNDLE_APP_MISMATCH",
            "ARCHIVE_BUNDLE_APP_KEY_MISSING", "ARCHIVE_BUNDLE_SDK_WRAPPER_MISSING", "ARCHIVE_BUNDLE_SDK_RESOURCES_MISSING",
            "ARCHIVE_BUNDLE_SDK_PLIST_MISSING", "ARCHIVE_BUNDLE_PRIVACY_DECLARATIONS_INVALID",
            "ARCHIVE_BUNDLE_SDK_ID_LEAK", "ARCHIVE_BUNDLE_SDK_CONFIG_LEAK", "ARCHIVE_BUNDLE_SDK_KEY_LEAK",
            "ARCHIVE_SCOPING_INVALID_OPERATION",
        }
        print(str(error) if str(error) in allowed else "ARCHIVE_SCOPING_INVALID_INPUT", file=sys.stderr)
        return 1
    except Exception:
        print("ARCHIVE_SCOPING_INVALID_INPUT", file=sys.stderr)
        return 1
    if operation == "privacy":
        print("Unsigned archive privacy declarations match reviewed Google SDK manifests")
    else:
        print("Archive app-target configuration isolation verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
