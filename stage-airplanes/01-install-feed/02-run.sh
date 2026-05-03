#!/bin/bash -e

# Drop the build-time feed checkout. Cleanup runs outside the chroot to avoid
# the tmpfs that on_chroot mounts over /tmp masking parts of the tree.
rm -rf "${ROOTFS_DIR}/usr/local/src/airplanes-feed-build"
