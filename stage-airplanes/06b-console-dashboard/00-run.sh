#!/bin/bash -e

install -D -m 755 "${BASE_DIR:-.}/runtime-overlay/src/lib/airplanes/render-status" \
    "${ROOTFS_DIR}/usr/local/lib/airplanes/render-status"

install -D -m 644 "${BASE_DIR:-.}/runtime-overlay/src/share/airplanes/logo.txt" \
    "${ROOTFS_DIR}/usr/local/share/airplanes/logo.txt"
install -D -m 644 "${BASE_DIR:-.}/runtime-overlay/src/share/airplanes/banner.txt" \
    "${ROOTFS_DIR}/usr/local/share/airplanes/banner.txt"
install -D -m 644 "${BASE_DIR:-.}/runtime-overlay/src/share/airplanes/banner-narrow.txt" \
    "${ROOTFS_DIR}/usr/local/share/airplanes/banner-narrow.txt"
install -D -m 644 "${BASE_DIR:-.}/runtime-overlay/src/share/airplanes/icon.txt" \
    "${ROOTFS_DIR}/usr/local/share/airplanes/icon.txt"

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system"
install -m 644 files/etc/systemd/system/airplanes-dashboard.service \
    "${ROOTFS_DIR}/etc/systemd/system/airplanes-dashboard.service"

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d"
install -m 644 files/etc/systemd/system/getty@tty1.service.d/override.conf \
    "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d/override.conf"

install -D -m 755 "${BASE_DIR:-.}/runtime-overlay/src/etc/update-motd.d/10-airplanes-status" \
    "${ROOTFS_DIR}/etc/update-motd.d/10-airplanes-status"
