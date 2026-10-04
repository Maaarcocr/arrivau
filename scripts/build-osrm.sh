#!/usr/bin/env bash
# Offline runtime dependency preparation. Never edits service/config or installs globally.
set -euo pipefail
VERSION=6.0.0
SHA256=369192672c0041600740c623ce961ef856e618878b7d28ae5e80c9f6c2643031
PREFIX="${1:?Usage: build-osrm.sh ABSOLUTE_INSTALL_PREFIX [ABSOLUTE_BUILD_DIRECTORY]}"
WORK="${2:-$PREFIX-build}"
JOBS="${OSRM_BUILD_JOBS:-2}"
[[ "$PREFIX" = /* && "$WORK" = /* && "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'Use absolute directories and a positive job count' >&2; exit 2; }
for tool in curl sha256sum tar cmake c++; do command -v "$tool" >/dev/null; done
MARKER="$PREFIX/arrivau-osrm-version"
if [[ -f "$MARKER" && "$(cat "$MARKER")" == "$VERSION $SHA256" && -f "$PREFIX/lib/libosrm.a" && -x "$PREFIX/bin/osrm-contract" ]]; then
  echo "Pinned OSRM already installed at $PREFIX"
  exit 0
fi
if [[ -f "$MARKER" && "$(cat "$MARKER")" != "$VERSION $SHA256" ]]; then
  echo 'Existing prefix contains a different version; choose a new directory' >&2; exit 2
fi
BUILD_MARKER="$PREFIX/.arrivau-osrm-building"
if [[ -e "$PREFIX" && ! -f "$MARKER" && ! -f "$BUILD_MARKER" && -n "$(ls -A "$PREFIX")" ]]; then
  echo 'Refusing to overwrite an existing unrecognized prefix; choose a new directory' >&2; exit 2
fi
mkdir -p "$WORK" "$PREFIX"
if [[ -f "$BUILD_MARKER" && "$(cat "$BUILD_MARKER")" != "$VERSION $SHA256" ]]; then
  echo 'Unrecognized partial build; choose a new prefix' >&2; exit 2
fi
printf '%s %s\n' "$VERSION" "$SHA256" > "$BUILD_MARKER"
ARCHIVE="$WORK/osrm-backend-v$VERSION.tar.gz"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 "https://github.com/Project-OSRM/osrm-backend/archive/refs/tags/v$VERSION.tar.gz" -o "$ARCHIVE.tmp"
  mv "$ARCHIVE.tmp" "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | sha256sum --check --status
SOURCE="$WORK/osrm-backend-$VERSION"
if [[ ! -f "$SOURCE/CMakeLists.txt" ]]; then tar -xzf "$ARCHIVE" -C "$WORK"; fi
cmake -S "$SOURCE" -B "$WORK/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_CXX_FLAGS=-Wno-error=array-bounds -DENABLE_LTO=OFF -DENABLE_CCACHE=OFF
cmake --build "$WORK/build" --target osrm osrm-extract osrm-contract --parallel "$JOBS"
# Install only the native SDK and offline preparation tools. No daemon required.
mkdir -p "$PREFIX/include/osrm" "$PREFIX/include/flatbuffers" "$PREFIX/lib" "$PREFIX/bin" "$PREFIX/share/osrm"
cp -a "$SOURCE/include/." "$PREFIX/include/osrm/"
cp -a "$SOURCE/include/osrm/"*.hpp "$PREFIX/include/osrm/"
cp -a "$SOURCE/third_party/flatbuffers/include/flatbuffers/." "$PREFIX/include/flatbuffers/"
cp "$WORK/build/libosrm.a" "$PREFIX/lib/"
cp "$WORK/build/osrm-extract" "$WORK/build/osrm-contract" "$PREFIX/bin/"
cp -a "$SOURCE/profiles" "$PREFIX/share/osrm/"
cp "$SOURCE/LICENSE.TXT" "$PREFIX/share/osrm/LICENSE.TXT"
printf '%s %s\n' "$VERSION" "$SHA256" > "$MARKER"
echo "OSRM_BACKEND_PATH=$PREFIX"
