#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEFAULT_ENGINE_ROOT="$(cd "$ROOT/.." && pwd)/HYROVI-Browser-Engine"
ENGINE_ROOT="${HYROVI_BROWSER_ENGINE_ROOT:-$DEFAULT_ENGINE_ROOT}"
BUILD_SCRIPT="$ENGINE_ROOT/engine/scripts/build-ios-core.sh"
DIST="$ENGINE_ROOT/engine/dist/ios"
DEST="$ROOT/firefox-ios/Client/HYROVI/EngineCore"

if [[ ! -x "$BUILD_SCRIPT" ]]; then
  echo "HYROVI Browser Engine checkout not found at: $ENGINE_ROOT" >&2
  echo "Set HYROVI_BROWSER_ENGINE_ROOT to the hyrovi-browser checkout." >&2
  exit 1
fi

(
  cd "$ENGINE_ROOT"
  "$BUILD_SCRIPT"
)

install -d "$DEST/include"
install -m 0644 "$DIST/libhyrovi_engine.a" "$DEST/libhyrovi_engine.a"
install -m 0644 "$DIST/include/hyrovi_engine.h" "$DEST/include/hyrovi_engine.h"
install -m 0644 "$DIST/include/module.modulemap" "$DEST/include/module.modulemap"

echo "HYROVI Engine core installed at $DEST"
shasum -a 256 "$DEST/libhyrovi_engine.a"
