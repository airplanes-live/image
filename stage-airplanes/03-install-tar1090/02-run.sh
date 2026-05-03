#!/bin/bash -e

# tar1090 source is unused at runtime; install.sh copied html assets out.
# Keep /usr/local/share/tar1090/git-db — runtime aircraft DB lookups use it.
rm -rf "${ROOTFS_DIR}/usr/local/src/airplanes-tar1090-build"
