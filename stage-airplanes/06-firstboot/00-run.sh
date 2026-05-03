#!/bin/bash -e

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system"
install -m 644 files/etc/systemd/system/airplanes-first-run.service \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-first-run.service"
install -m 644 files/etc/systemd/system/airplanes-claim.service \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-claim.service"
install -m 644 files/etc/systemd/system/airplanes-claim.timer \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-claim.timer"

install -d -m 755 "${ROOTFS_DIR}/usr/local/sbin"
install -m 755 files/usr/local/sbin/airplanes-first-run \
	"${ROOTFS_DIR}/usr/local/sbin/airplanes-first-run"

# pi-gen's export-image stage copies ${ROOTFS_DIR}/boot/firmware/* onto the
# FAT partition during image assembly, so writing the template here lands it
# on partition 1 where SD-card editors can reach it.
install -d -m 755 "${ROOTFS_DIR}/boot/firmware"
install -m 644 files/boot/firmware/airplanes-config.txt \
	"${ROOTFS_DIR}/boot/firmware/airplanes-config.txt"

on_chroot <<'EOF'
PATH="/usr/local/sbin:${PATH}" systemctl enable \
	airplanes-first-run.service airplanes-claim.timer
EOF
