#!/bin/bash -e

# Move local console login from TTY1 to TTY2 so airplanes-dashboard.service
# can own /dev/tty1 cleanly.
#
# `disable` first to remove any stale getty.target.wants symlink the upstream
# pi-gen stages may have written, then `mask` so systemd-getty-generator
# cannot recreate getty@tty1 from the kernel cmdline `console=tty1` at
# runtime. The dashboard's getty@tty1 drop-in (Conflicts=) covers the
# remaining failure mode where an operator manually unmasks.
on_chroot <<'EOF'
PATH="/usr/local/sbin:${PATH}" systemctl disable getty@tty1.service || true
PATH="/usr/local/sbin:${PATH}" systemctl mask getty@tty1.service
PATH="/usr/local/sbin:${PATH}" systemctl enable getty@tty2.service
PATH="/usr/local/sbin:${PATH}" systemctl enable airplanes-dashboard.service
EOF
