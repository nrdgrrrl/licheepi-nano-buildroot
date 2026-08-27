#!/bin/bash -e

BOARD_DIR="$(dirname "$0")"
GENIMAGE_CFG="${BOARD_DIR}/genimage-dev.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage-dev.tmp"

rm -rf "${GENIMAGE_TMP}"

genimage \
  --rootpath "${TARGET_DIR}" \
  --tmppath "${GENIMAGE_TMP}" \
  --inputpath "${BINARIES_DIR}" \
  --outputpath "${BINARIES_DIR}" \
  --config "${GENIMAGE_CFG}"
