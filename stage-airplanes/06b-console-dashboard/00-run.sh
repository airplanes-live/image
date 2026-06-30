#!/bin/bash -e

# render-status, the ASCII assets, and the motd hook are delivered by the
# runtime overlay (current/lib/airplanes/render-status + current/share/airplanes/*,
# laid by 02-install-runtime-overlay), so 06b no longer ships image-owned
# copies under /usr/local — that tree is no longer ours to write. 06b installs
# only the version-stable /etc infrastructure: the dashboard service unit and
# the getty override that hands /dev/tty1 to it.
install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system"
install -m 644 files/etc/systemd/system/airplanes-dashboard.service \
    "${ROOTFS_DIR}/etc/systemd/system/airplanes-dashboard.service"

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d"
install -m 644 files/etc/systemd/system/getty@tty1.service.d/override.conf \
    "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d/override.conf"
