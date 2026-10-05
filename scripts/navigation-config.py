#!/usr/bin/env python3
"""Generate a private Info.plist without placing the Google API key in build args.

Reads only ARRIVAU_GOOGLE_MAPS_API_KEY from the environment. No network
access, credential creation, project provisioning, billing changes or uploads.
The key is necessarily embedded in the built iOS app; restrict it in Google Cloud.
"""

import argparse
import os
from pathlib import Path
import plistlib
import re
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
KEY = "ARRIVAU_GOOGLE_MAPS_API_KEY"


def configuration(env):
    key = env.get(KEY, "")
    # A character/length sanity check, not verification of a key or its access.
    # In particular, reject unresolved build variables, newlines and markup.
    if key and not re.fullmatch(r"[A-Za-z0-9_-]{20,200}", key):
        raise ValueError("Google Maps API key must be blank or 20–200 ASCII letters, digits, underscores or hyphens")
    return {KEY: key}


def write_configuration(build_configuration, output, env):
    if build_configuration not in ("Debug", "Release"):
        raise ValueError("Configuration must be Debug or Release")
    values = configuration(env)
    output = Path(output)
    templates = [ROOT / "ios/Config" / f"Info-{name}.plist" for name in ("Debug", "Release", "UITests")]
    if output.resolve() in [template.resolve() for template in templates]:
        raise ValueError("Refusing to overwrite a tracked Info.plist template")
    template = ROOT / "ios/Config" / f"Info-{build_configuration}.plist"
    info = plistlib.loads(template.read_bytes())
    info.update(values)
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Atomic replacement preserves an existing config on validation/write errors.
    # A temporary file is mode 0600, including when replacing a permissive file.
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".navigation-", delete=False) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(plistlib.dumps(info, sort_keys=False))
        os.replace(temporary_path, output)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("Debug", "Release"), required=True)
    parser.add_argument("--output", type=Path, help="Defaults to ignored ios/Config/Navigation.local/Info-CONFIGURATION.plist")
    args = parser.parse_args()
    output = args.output or ROOT / "ios/Config/Navigation.local" / f"Info-{args.configuration}.plist"
    try:
        write_configuration(args.configuration, output, os.environ)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, plistlib.InvalidFileException):
        # Never include a credential or file contents in diagnostics.
        print("Unable to write navigation configuration; check the template and output directory", file=sys.stderr)
        return 1
    print("Private navigation configuration generated; key contents are not displayed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
