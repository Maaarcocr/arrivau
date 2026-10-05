#!/usr/bin/env python3
"""Export named Arrivau screenshots from an Xcode 16 result bundle.

Xcode 16.4's `export attachments --only-failures` can omit XCTest attachments.
This narrow read-only extractor uses its observed SQLite attachment index or
compact v3 attachment records and Zstandard/raw payloads; it fails visibly if the result format changes. It never
modifies the .xcresult and exports only the intentional demo snapshots.
Requires zstandard==0.25.0 for compressed payloads.
"""
import argparse
import json
import pathlib
import re
import sqlite3
import warnings

NAMES = (
    "00-login", "01-dispatcher-jobs", "02-new-delivery", "03-driver-route",
    "04-driver-shift", "05-driver-assignment", "06-address-search", "07-delivery-timing",
    "dual-account-centrale", "dual-account-corriere",
    "ux-pilot-login", "ux-invite-entry", "ux-account", "ux-new-shift", "ux-driver-waiting", "ux-active-logout",
)
SMOKE_NAMES = (
    "ux-pilot-login", "ux-invite-entry", "ux-account", "ux-shift-consent",
    "ux-new-shift", "ux-driver-waiting", "ux-active-logout",
    "dual-account-centrale", "dual-account-corriere",
)
# Captured only by isolated-fixture failure diagnostics; never required on success.
OPTIONAL_NAMES = ("demo-login-failure", "ux-logout-presentation", "ux-role-switch-failure", "pilot-smoke-failure")
EXPORT_NAMES = tuple(dict.fromkeys(NAMES + SMOKE_NAMES + OPTIONAL_NAMES))
PNG = b"\x89PNG\r\n\x1a\n"
ZSTD = b"\x28\xb5\x2f\xfd"


def decompress(payload):
    if not payload.startswith(ZSTD):
        return payload
    import zstandard
    try:
        return zstandard.ZstdDecompressor().decompress(payload, max_output_size=32 * 1024 * 1024)
    except zstandard.ZstdError as error:
        raise ValueError(f"Unreadable Zstandard payload: {error}") from error


def compact_records(result):
    """Read observed XCResult v3.53 named attachment records before lazy indexing."""
    names = b"|".join(re.escape(name.encode()) for name in EXPORT_NAMES)
    pattern = re.compile(
        rb"K4:name\[S6:StringK2:_vV[0-9]+:(" + names + rb")\]"
        rb"K10:payloadRef\[(?:S9:Reference|T\[K2:_nV9:Reference\])"
        rb"K2:id\[S6:StringK2:_vV[0-9]+:([A-Za-z0-9_~=+-]+)\]\]"
    )
    records = []
    unreadable = 0
    for path in (result / "Data").glob("data.*"):
        try:
            payload = decompress(path.read_bytes())
        except (OSError, ValueError):
            # A crashed test run can leave unrelated diagnostics incomplete or
            # larger than the decode limit. Discovery must not depend on those
            # records. Named screenshot payloads are read strictly in export().
            unreadable += 1
            continue
        # Compact typed records start with a type or structure marker, not logs/PNG.
        if not payload.startswith((b"[T", b"[S")):
            continue
        for match in pattern.finditer(payload):
            records.append((match[1].decode(), match[2].decode(), "public.png"))
    if unreadable:
        warnings.warn(f"Skipped {unreadable} unreadable XCResult records during attachment discovery; "
                      "named screenshot payloads are still required to be readable.", RuntimeWarning)
    return records


def export(result, destination, require_all=False, suite="full"):
    if suite not in ("smoke", "full"):
        raise ValueError("Unknown screenshot suite")
    required_names = SMOKE_NAMES if suite == "smoke" else NAMES
    result, destination = pathlib.Path(result).resolve(), pathlib.Path(destination).resolve()
    database = result / "database.sqlite3"
    destination.mkdir(parents=True, exist_ok=True)
    for name in EXPORT_NAMES:
        (destination / (name + ".png")).unlink(missing_ok=True)
    found = {}
    if database.is_file():
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
            records = list(connection.execute(
                "SELECT name, xcResultKitPayloadRefId, uniformTypeIdentifier FROM Attachments ORDER BY timestamp"
            ))
    else:
        records = compact_records(result)
    for name, ref, kind in records:
        if name not in EXPORT_NAMES or kind != "public.png":
            continue
        if not ref or not re.fullmatch(r"[A-Za-z0-9_~=+-]+", ref):
            raise ValueError("Unsafe or unknown screenshot payload reference")
        try:
            payload = decompress((result / "Data" / ("data." + ref)).read_bytes())
        except (OSError, ValueError) as error:
            raise ValueError(f"Cannot read snapshot {name}: {error}") from error
        if not payload.startswith(PNG):
            raise ValueError(f"Snapshot {name} is not a PNG")
        output = destination / (name + ".png")
        output.write_bytes(payload)
        found[name] = {"name": name, "file": output.name, "bytes": len(payload)}
    summary = {"screenshots": [found[name] for name in EXPORT_NAMES if name in found],
               "missing": [name for name in required_names if name not in found], "suite": suite}
    (destination / "manifest.json").write_text(json.dumps(summary, indent=2) + "\n")
    if require_all and summary["missing"]:
        raise ValueError("Missing expected screenshots: " + ", ".join(summary["missing"]))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result")
    parser.add_argument("destination")
    parser.add_argument("--require-all", action="store_true")
    parser.add_argument("--suite", choices=("smoke", "full"), default="full")
    args = parser.parse_args()
    print(json.dumps(export(args.result, args.destination, args.require_all, args.suite), indent=2))


if __name__ == "__main__":
    main()
