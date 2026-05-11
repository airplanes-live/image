#!/bin/bash -e
# Install airplanes-grant-sudo: a oneshot service that writes per-user
# /etc/sudoers.d/099_airplanes-sudo-<name> NOPASSWD grants after cloud-init
# creates the rpi-imager-supplied user(s). Closes the gap left by the
# debian cloud-init Distro override (99-airplanes-distro-debian.cfg),
# which causes rpi-imager to omit the `groups: [sudo]` / `sudo:` keys it
# would normally emit for a raspberry-pi-os image.

install -d -m 755 "${ROOTFS_DIR}/usr/local/sbin"
install -m 0755 files/usr/local/sbin/airplanes-grant-sudo \
	"${ROOTFS_DIR}/usr/local/sbin/airplanes-grant-sudo"

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system"
install -m 0644 files/etc/systemd/system/airplanes-grant-sudo.service \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-grant-sudo.service"
