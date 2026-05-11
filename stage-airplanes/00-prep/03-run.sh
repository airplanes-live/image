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
# directly (the binary, not the service); the binary in turn runs
# `systemctl enable --now getty@tty1.service`, which we mask in 06b. That
# breaks cc_users_groups before setup_user_keys runs, so we also flip the
# cloud-init distro to plain debian in 04-run.sh — see that file's drop-in
# for the full chain. Masking the systemd unit here is defense-in-depth.
#
# systemd-firstboot.service is masked for the same reason: locale, keymap,
# timezone, and root password are all baked at build time or
# customization-driven; we never want a console wizard.

mkdir -p "${ROOTFS_DIR}/etc/systemd/system"
ln -sf /dev/null "${ROOTFS_DIR}/etc/systemd/system/userconfig.service"
ln -sf /dev/null "${ROOTFS_DIR}/etc/systemd/system/systemd-firstboot.service"

# The "SSH may not work until a valid user has been set up" banner +
# rename_user.conf drop-in are created by `rename-user -f -s` in pi-gen's
# export-image/01-user-rename stage, AFTER stage-airplanes runs. rm'ing
# them here would be too early (the files don't exist yet). The whole
# rename stage is skipped instead — see export-image/01-user-rename/SKIP.
