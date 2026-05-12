#!/bin/bash
# Explicit `set -e` (not just shebang) — pi-gen invokes via `on_chroot <
# 01-run-chroot.sh`, which feeds the body to bash inside the chroot and
# ignores the shebang's flags.
set -e

# Move local console login from TTY1 to TTY2 so airplanes-dashboard.service
# can own /dev/tty1 cleanly.
#
# `disable` first to remove any stale getty.target.wants symlink the upstream
# pi-gen stages may have written, then `mask` so systemd-getty-generator
# cannot recreate getty@tty1 from the kernel cmdline `console=tty1` at
# runtime. The dashboard's getty@tty1 drop-in (Conflicts=) covers the
# remaining failure mode where an operator manually unmasks.
export PATH="/usr/local/sbin:${PATH}"

systemctl disable getty@tty1.service || true
systemctl mask getty@tty1.service
systemctl enable getty@tty2.service
systemctl enable airplanes-dashboard.service

# Strip Debian/Raspberry Pi OS default login-banner content. Only the
# airplanes-dashboard hook (10-airplanes-status, installed in 00-run.sh)
# should fire from pam_motd at TTY2/SSH login — no `uname`, no Debian
# license blurb, no upstream additions.
#
# rm+install rather than `: > /etc/motd` so a packaging-time symlink (e.g.
# /etc/motd → /run/motd.dynamic on some Debian variants) doesn't write
# through to a runtime path. The installed empty regular file is what
# pam_motd will read on every login.
rm -f /etc/motd
install -m 0644 /dev/null /etc/motd

# Specific names rather than wildcard removal so a future hook the team
# intentionally adds isn't silently deleted. Smoke-test allowlist
# (test/overlay-smoke-inner.sh) flags any new offender.
rm -f /etc/update-motd.d/10-uname \
      /etc/update-motd.d/00-header \
      /etc/update-motd.d/10-help-text \
      /etc/update-motd.d/50-motd-news
