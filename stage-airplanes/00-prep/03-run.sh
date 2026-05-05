#!/bin/bash -e

# Mask first-boot interactive setup units. Our image is webconfig-managed —
# console prompts have no UX path on a feeder Pi (typically headless), and
# the userconfig.service flow specifically races/breaks on cloud-init builds:
# pi (uid 1000) ships from pi-gen and `airplanes` (the feed daemon user)
# already exists, so its `usermod -l airplanes pi` rename collides whenever
# a user happens to type "airplanes" in rpi-imager. With Restart=on-failure
# the failed rename loops indefinitely, blocking boot.
#
# cloud-init's raspberry_pi_os.add_user calls /usr/lib/userconf-pi/userconf
# directly (the binary, not the service) — masking the systemd unit doesn't
# break the rpi-imager-customized path.
#
# systemd-firstboot.service is masked for the same reason: locale, keymap,
# timezone, and root password are all baked at build time or
# customization-driven; we never want a console wizard.

mkdir -p "${ROOTFS_DIR}/etc/systemd/system"
ln -sf /dev/null "${ROOTFS_DIR}/etc/systemd/system/userconfig.service"
ln -sf /dev/null "${ROOTFS_DIR}/etc/systemd/system/systemd-firstboot.service"
