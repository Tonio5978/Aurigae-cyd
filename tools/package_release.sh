#!/usr/bin/env bash
# Package an already-built esp32-cyd firmware into every downloadable a
# GitHub Release publishes (see .releaserc.json), all written to dist/:
#
#   bootloader.bin, partitions.bin, boot_app0.bin, firmware.bin
#       loose parts, flashable individually with esptool or esp-web-tools
#   manifest.json
#       esp-web-tools manifest pointing at those parts (same format as the
#       one FIRMWARE_MANIFEST_URL serves, which /checkupdate parses)
#   aurigae-webflasher-<version>.zip
#       manifest.json + the four parts, ready to drop onto a web flasher host
#   aurigae-factory-<version>.bin
#       single merged image, flashed at 0x0 on a blank/erased board
#
# Usage: pio run -e esp32-cyd && tools/package_release.sh
# In CI it runs from semantic-release's prepareCmd right after the build, once
# include/version.h already holds the new version.
#
# Requires: zip.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_NAME="esp32-cyd"
BUILD_DIR=".pio/build/$ENV_NAME"
OUT_DIR="dist"

for f in bootloader.bin partitions.bin firmware.bin firmware.factory.bin; do
  if [[ ! -f "$BUILD_DIR/$f" ]]; then
    echo "error: $BUILD_DIR/$f not found (run 'pio run -e $ENV_NAME' first)" >&2
    exit 1
  fi
done

# boot_app0.bin isn't a build output — it's a small static "boot slot 0" image
# shipped with the arduino-esp32 framework, needed because our partition table
# (min_spiffs.csv, see platformio.ini) has an otadata partition.
CORE_DIR="${PLATFORMIO_CORE_DIR:-$HOME/.platformio}"
BOOT_APP0="$CORE_DIR/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"
if [[ ! -f "$BOOT_APP0" ]]; then
  echo "error: boot_app0.bin not found at $BOOT_APP0 (framework package missing?)" >&2
  exit 1
fi

# app0/app1 in min_spiffs.csv are 0x1E0000 (1920K) each. PlatformIO's own
# "Flash:" check only sums ELF sections, so it misses an image that fits on
# paper but whose padded .bin spills past the slot: the bootloader then
# refuses to boot it and Update.begin() rejects it for OTA. Fail the release
# instead of publishing it.
APP_SLOT_SIZE=$((0x1E0000))
FW_SIZE=$(wc -c < "$BUILD_DIR/firmware.bin" | tr -d ' ')
if (( FW_SIZE > APP_SLOT_SIZE )); then
  echo "error: firmware.bin is $FW_SIZE bytes, exceeds the $APP_SLOT_SIZE-byte app slot by $((FW_SIZE - APP_SLOT_SIZE))" >&2
  exit 1
fi
echo "firmware.bin: $FW_SIZE / $APP_SLOT_SIZE bytes ($((APP_SLOT_SIZE - FW_SIZE)) free)"

VERSION="$(sed -n 's/^#define FW_VERSION "\([^"]*\)".*/\1/p' include/version.h)"
if [[ -z "$VERSION" ]]; then
  echo "error: couldn't parse FW_VERSION out of include/version.h" >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

cp "$BUILD_DIR/bootloader.bin" "$BUILD_DIR/partitions.bin" "$BUILD_DIR/firmware.bin" "$OUT_DIR/"
cp "$BOOT_APP0" "$OUT_DIR/"

# Offsets match this project's partition table (min_spiffs.csv) and the ESP32
# (non-S2/S3/C3) bootloader offset. If board/partitions ever change, these
# need to change with them.
cat > "$OUT_DIR/manifest.json" <<EOF
{
  "name": "Aurigae",
  "version": "$VERSION",
  "home_assistant_domain": "esphome",
  "new_install_prompt_erase": true,
  "builds": [
    {
      "chipFamily": "ESP32",
      "parts": [
        { "path": "bootloader.bin", "offset": 4096 },
        { "path": "partitions.bin", "offset": 32768 },
        { "path": "boot_app0.bin", "offset": 57344 },
        { "path": "firmware.bin", "offset": 65536 }
      ]
    }
  ]
}
EOF

(cd "$OUT_DIR" && zip -q -X "aurigae-webflasher-$VERSION.zip" \
  manifest.json bootloader.bin partitions.bin boot_app0.bin firmware.bin)

# pioarduino already merges bootloader/partitions/boot_app0/app into
# firmware.factory.bin at the offsets above (byte-identical to an esptool
# merge_bin), so no separate esptool step is needed.
cp "$BUILD_DIR/firmware.factory.bin" "$OUT_DIR/aurigae-factory-$VERSION.bin"

echo "Packaged Aurigae $VERSION into $OUT_DIR/:"
ls -l "$OUT_DIR"
