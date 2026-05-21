#!/bin/bash -e
# Install /usr/local/sbin/apl-feed — a tiny POSIX-sh wrapper that auto-sudos
# privileged subcommands of the canonical /usr/local/bin/apl-feed for the
# human user on this image. Webconfig and systemd units use the absolute
# /usr/local/bin/apl-feed path and are not affected.
#
# Also installs /usr/local/lib/airplanes-webconfig/start-orchestrator.sh —
# the stable image-owned launch path that webconfig's sudoers entry pins to.
# The trampoline exec()s the runtime-overlay-shipped orchestrator after
# verifying it exists, or exits 75 (EX_TEMPFAIL) so the capability gate in
# webconfig returns HTTP 503 cleanly when the overlay is not in place.

install -d -m 755 "${ROOTFS_DIR}/usr/local/sbin"
install -m 0755 files/usr/local/sbin/apl-feed \
    "${ROOTFS_DIR}/usr/local/sbin/apl-feed"

install -D -m 0755 \
    files/usr/local/lib/airplanes-webconfig/start-orchestrator.sh \
    "${ROOTFS_DIR}/usr/local/lib/airplanes-webconfig/start-orchestrator.sh"
