#!/usr/bin/env python3
"""Write an immutable, checksummed manifest after offline CH preparation."""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", type=Path, help="prepared .osrm base (the base itself need not exist)")
    parser.add_argument("--osm-timestamp", required=True)
    parser.add_argument("--service-bounds", nargs=4, required=True, type=float, metavar=("WEST", "SOUTH", "EAST", "NORTH"))
    parser.add_argument("--extract-bounds", nargs=4, required=True, type=float, metavar=("WEST", "SOUTH", "EAST", "NORTH"))
    args = parser.parse_args()
    files = sorted(args.base.parent.glob(args.base.name + ".*"))
    if not files or not any(p.suffix == ".hsgr" for p in files):
        parser.error("no CH graph found; run osrm-extract and osrm-contract first")
    hashes = {}
    for path in files:
        if path.is_file():
            with path.open("rb") as stream:
                hashes[path.name] = hashlib.file_digest(stream, "sha256").hexdigest()
    manifest = dict(format_version=1, osrm_version="6.0.0", binding_version="0.8.2", algorithm="CH", profile="car.lua",
                    osm_timestamp=args.osm_timestamp, data_file=args.base.name,
                    service_bounds=args.service_bounds, extract_bounds=args.extract_bounds, files=hashes)
    destination = args.base.parent / "manifest.json"
    if destination.exists():
        parser.error("manifest.json already exists; prepare a new versioned dataset directory")
    destination.write_text(json.dumps(manifest, indent=2) + "\n")
    print(destination.resolve())


if __name__ == "__main__":
    main()
