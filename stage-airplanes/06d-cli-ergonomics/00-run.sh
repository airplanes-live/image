#!/bin/bash -e
# Install /usr/local/sbin/apl-feed — a tiny POSIX-sh wrapper that auto-sudos
# privileged subcommands of the canonical /usr/local/bin/apl-feed for the
# human user on this image. Webconfig and systemd units use the absolute
# /usr/local/bin/apl-feed path and are not affected.

install -d -m 755 "${ROOTFS_DIR}/usr/local/sbin"
install -m 0755 files/usr/local/sbin/apl-feed \
    "${ROOTFS_DIR}/usr/local/sbin/apl-feed"
