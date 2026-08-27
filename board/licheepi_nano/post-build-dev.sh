#!/bin/sh

set -eu

TARGET_DIR=${1:?missing target directory}

# Buildroot's overlay rsync intentionally normalizes permissions. Restore the
# mode required for sudoers.d files after all package and overlay installation.
chmod 0440 "$TARGET_DIR/etc/sudoers.d/90-victoria"
