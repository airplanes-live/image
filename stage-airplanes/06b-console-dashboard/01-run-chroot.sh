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
