#!/bin/bash -e
# Setup-only stage for webconfig. The webconfig binary, helpers, systemd
# units, sudoers, and lighttpd snippet now arrive through the runtime overlay
# at stage 02 (managed_paths symlinks + a copy-mode sudoers entry). This stage
# no longer clones image-webconfig or runs its install.sh.
#
# Host-side it lays down only the image-owned tmpfiles spec (creates
# /run/airplanes at boot — shared with feed + first-run). Everything that has
# to run inside the target rootfs (user, state dirs, group memberships,
# lighttpd mod_proxy + conf-enabled activation) lives in 01-run-chroot.sh.
# Unit enabling is handled dynamically from the overlay manifest in stage 02.

: "${ROOTFS_DIR:?ROOTFS_DIR must be set by pi-gen}"

install -D -m 0644 files/usr/lib/tmpfiles.d/airplanes-webconfig.conf \
    "${ROOTFS_DIR}/usr/lib/tmpfiles.d/airplanes-webconfig.conf"
