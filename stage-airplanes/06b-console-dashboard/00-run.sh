#!/bin/bash -e

install -d -m 755 "${ROOTFS_DIR}/usr/local/lib/airplanes"
install -m 755 files/usr/local/lib/airplanes/render-status \
    "${ROOTFS_DIR}/usr/local/lib/airplanes/render-status"

install -d -m 755 "${ROOTFS_DIR}/usr/local/share/airplanes"
install -m 644 files/usr/local/share/airplanes/logo.txt \
    "${ROOTFS_DIR}/usr/local/share/airplanes/logo.txt"

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system"
install -m 644 files/etc/systemd/system/airplanes-dashboard.service \
    "${ROOTFS_DIR}/etc/systemd/system/airplanes-dashboard.service"

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d"
install -m 644 files/etc/systemd/system/getty@tty1.service.d/override.conf \
    "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d/override.conf"

install -d -m 755 "${ROOTFS_DIR}/etc/update-motd.d"
install -m 755 files/etc/update-motd.d/10-airplanes-status \
    "${ROOTFS_DIR}/etc/update-motd.d/10-airplanes-status"
