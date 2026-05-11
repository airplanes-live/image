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

# raspberrypi-sys-mods ships /etc/ssh/sshd_banner + sshd_config.d/rename_user.conf
# which print "SSH may not work until a valid user has been set up" on every
# login. userconf-pi removes them after it creates the user, but we route
# around userconf-pi entirely (see masks above). cloud-init's cc_users_groups
# creates a valid uid-1000 user without touching these files, so the banner
# stays on disk and lies to every SSH session. Delete at build time.
rm -f "${ROOTFS_DIR}/etc/ssh/sshd_banner"
rm -f "${ROOTFS_DIR}/etc/ssh/sshd_config.d/rename_user.conf"
