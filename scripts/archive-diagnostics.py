#!/usr/bin/env python3
"""Classify a private archive log using fixed allowlisted codes only.

Never print raw lines, matched substrings, target names, paths, credentials, or
exceptions. Codes are diagnostic hints, not a claim that a root cause is proven.
The original log remains private and is deleted by the signing cleanup trap.
"""

from pathlib import Path
import sys

# All printed values are literals defined here, never derived from tool output.
RULES = (
    ("ARCHIVE_PROVISIONING_NOT_SUPPORTED", ("does not support provisioning profiles",)),
    ("ARCHIVE_PROVISIONING_MISMATCH", ("requires a provisioning profile", "no profiles for", "doesn't include signing certificate", "does not include signing certificate", "doesn't match the entitlements", "does not match the entitlements")),
    ("ARCHIVE_SIGNING_IDENTITY", ("no signing certificate", "no signing identity", "errsecinternalcomponent", "user interaction is not allowed")),
    ("ARCHIVE_INFOPLIST", ("unable to process info.plist", "could not read plist")),
    ("ARCHIVE_DUPLICATE_OUTPUT", ("multiple commands produce",)),
    ("ARCHIVE_BUILD_INPUT_MISSING", ("build input file cannot be found",)),
    ("ARCHIVE_SDK_SIGNATURE", ("signature cannot be verified", "signature of the binary", "does not match the previously recorded value")),
    ("ARCHIVE_SWIFT_COMPILE", ("swiftcompile", "swiftemitmodule")),
    ("ARCHIVE_LINK", ("linker command failed", "undefined symbols for architecture", "duplicate symbols for architecture")),
    ("ARCHIVE_PACKAGE_RESOLUTION", ("could not resolve package dependencies", "failed downloading", "failed to clone repository")),
)


def classify(path):
    found = set()
    # Only error/failed-action lines are eligible. Successful compiler operations
    # in a long archive log must not be mistaken for the failing stage.
    with Path(path).open(errors="replace") as log:
        failed_actions = False
        for line in log:
            lower = line.lower()
            failed_actions = failed_actions or "the following build commands failed" in lower
            if "error:" not in lower and not failed_actions:
                continue
            for code, patterns in RULES:
                if any(pattern in lower for pattern in patterns):
                    found.add(code)
    return [code for code, _ in RULES if code in found] or ["ARCHIVE_UNCLASSIFIED"]


def main(args):
    try:
        codes = classify(args[0]) if len(args) == 1 else ["ARCHIVE_DIAGNOSTICS_UNAVAILABLE"]
    except Exception:
        codes = ["ARCHIVE_DIAGNOSTICS_UNAVAILABLE"]
    for code in codes:
        print(code)


if __name__ == "__main__":
    main(sys.argv[1:])
