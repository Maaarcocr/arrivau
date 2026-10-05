#!/usr/bin/env python3
"""Write a private XcodeGen overlay whose Release settings affect only Arrivau.

The Google key stays in the separately generated private Info.plist, never in
build settings. Do not use this overlay as a global xcodebuild -xcconfig: command
line settings would leak application signing/plist settings into SDK targets.
Generate with --project-root ios and --project in the private working directory.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def archive_settings(build, info_plist, env, manual):
    spec = importlib.util.spec_from_file_location("pilot_config", ROOT / "scripts/validate-pilot-config.py")
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    validator.validate_archive(dict(env, ARRIVAU_BUILD_NUMBER=build))
    info_plist = Path(info_plist).resolve()
    if not info_plist.is_file() or any(c in str(info_plist) for c in "\n\r$\x00"):
        raise ValueError("Private navigation plist is missing or its path is invalid")
    settings = {
        "INFOPLIST_FILE": str(info_plist),
        "DEVELOPMENT_TEAM": env["ARRIVAU_TEAM_ID"],
        "PRODUCT_BUNDLE_IDENTIFIER": env["ARRIVAU_BUNDLE_ID"],
        "CURRENT_PROJECT_VERSION": build,
        "ARRIVAU_API_URL": env["ARRIVAU_API_URL"],
    }
    if manual:
        profile = env.get("ARRIVAU_ARCHIVE_PROFILE_UUID", "")
        identity = env.get("ARRIVAU_ARCHIVE_IDENTITY", "")
        keychain = env.get("ARRIVAU_ARCHIVE_KEYCHAIN", "")
        if not re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", profile):
            raise ValueError("Manual archive profile UUID is invalid")
        if not re.fullmatch(r"[A-F0-9]{40}", identity):
            raise ValueError("Manual archive identity fingerprint is invalid")
        if not Path(keychain).is_absolute() or any(c in keychain for c in "\n\r$\x00"):
            raise ValueError("Manual archive keychain path is invalid")
        settings.update({
            "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGNING_ALLOWED": "YES",
            "CODE_SIGNING_REQUIRED": "YES",
            "PROVISIONING_PROFILE_SPECIFIER": profile,
            "CODE_SIGN_IDENTITY": identity,
            "OTHER_CODE_SIGN_FLAGS": "--keychain " + shlex.quote(keychain),
        })
    return settings


def write_overlay(build, info_plist, output, env, manual=False):
    settings = archive_settings(build, info_plist, env, manual)
    overlay = {
        # --project-root supplies the original ios source root. Only the generated
        # project and this overlay live outside the checkout, and are cleaned up.
        "include": [{"path": str(ROOT / "ios/project.yml"), "relativePaths": False}],
        "targets": {"Arrivau": {"settings": {"configs": {"Release": settings}}}},
    }
    output = Path(output)
    if output.resolve() == (ROOT / "ios/project.yml").resolve() or output.resolve() == Path(info_plist).resolve():
        raise ValueError("Refusing to overwrite an input configuration")
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".archive-", delete=False) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(json.dumps(overlay, indent=2).encode())
        os.replace(temporary_path, output)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--info-plist", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manual-signing", action="store_true")
    args = parser.parse_args()
    try:
        write_overlay(args.build_number, args.info_plist, args.output, os.environ, args.manual_signing)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        # Never echo paths, credentials, or parser input on errors.
        print("Unable to prepare private app archive configuration", file=sys.stderr)
        return 1
    print("Private app-target archive configuration generated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
