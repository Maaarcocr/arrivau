#!/usr/bin/env python3
"""Export named Arrivau screenshots from an Xcode 16 result bundle.

Xcode 16.4's `export attachments --only-failures` can omit XCTest attachments.
This narrow read-only extractor uses its observed SQLite attachment index and
Zstandard/raw payloads; it fails visibly if the result format changes. It never
modifies the .xcresult and exports only the four intentional demo snapshots.
Requires zstandard==0.25.0 for compressed payloads.
"""
import argparse
import json
import pathlib
import re
import sqlite3

NAMES = (
    "01-dispatcher-jobs", "02-new-delivery", "03-driver-route", "04-driver-shift",
)
PNG = b"\x89PNG\r\n\x1a\n"
ZSTD = b"\x28\xb5\x2f\xfd"


def export(result, destination, require_all=False):
    result, destination = pathlib.Path(result).resolve(), pathlib.Path(destination).resolve()
    database = result / "database.sqlite3"
    if not database.is_file():
        raise ValueError("Xcode result has no SQLite attachment index; export format needs review")
    destination.mkdir(parents=True, exist_ok=True)
    for name in NAMES:
        (destination / (name + ".png")).unlink(missing_ok=True)
    found = {}
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
        records = connection.execute(
            "SELECT name, xcResultKitPayloadRefId, uniformTypeIdentifier FROM Attachments ORDER BY timestamp"
        )
        for name, ref, kind in records:
            if name not in NAMES or kind != "public.png":
                continue
            if not ref or not re.fullmatch(r"[A-Za-z0-9_~=+-]+", ref):
                raise ValueError("Unsafe or unknown screenshot payload reference")
            payload = (result / "Data" / ("data." + ref)).read_bytes()
            if payload.startswith(ZSTD):
                import zstandard
                payload = zstandard.ZstdDecompressor().decompress(payload, max_output_size=32 * 1024 * 1024)
            if not payload.startswith(PNG):
                raise ValueError(f"Snapshot {name} is not a PNG")
            output = destination / (name + ".png")
            output.write_bytes(payload)
            found[name] = {"name": name, "file": output.name, "bytes": len(payload)}
    summary = {"screenshots": [found[name] for name in NAMES if name in found],
               "missing": [name for name in NAMES if name not in found]}
    (destination / "manifest.json").write_text(json.dumps(summary, indent=2) + "\n")
    if require_all and summary["missing"]:
        raise ValueError("Missing expected screenshots: " + ", ".join(summary["missing"]))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result")
    parser.add_argument("destination")
    parser.add_argument("--require-all", action="store_true")
    args = parser.parse_args()
    print(json.dumps(export(args.result, args.destination, args.require_all), indent=2))


if __name__ == "__main__":
    main()
