#!/bin/bash -e
# Remove the source clone left behind by 00-run.sh so the shipped image
# does not carry a sibling copy of the webconfig repo on rootfs. Mirrors
# stage-airplanes/01-install-feed's cleanup.
rm -rf "${ROOTFS_DIR}/usr/local/src/airplanes-webconfig-build"
