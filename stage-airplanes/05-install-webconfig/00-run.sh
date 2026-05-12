#!/bin/bash -e
# Cross-build the webconfig binary on the build host and install it plus the
# lighttpd reverse-proxy snippet and systemd unit. User creation, ownership,
# and lighttpd module enable happen inside the chroot in 01-run-chroot.sh.

# Map pi-gen's ARCH to Go's GOARCH/GOARM.
case "${ARCH}" in
	arm64) export GOOS=linux GOARCH=arm64 ;;
	armhf) export GOOS=linux GOARCH=arm GOARM=7 ;;
	*) echo "ERROR: stage-05 cross-build does not support ARCH='${ARCH:-unset}'" >&2; exit 1 ;;
esac

# Pure-Go module — no CGO, no cross toolchain needed. -trimpath strips
# host-specific paths from stack traces so the binary is reproducible across
# build hosts; -buildvcs=false keeps the binary independent of git state of
# the pi-gen checkout (we record that separately in the build manifest).
export CGO_ENABLED=0

WEBCONFIG_SRC="${BASE_DIR}/webconfig"
WEBCONFIG_BIN="${ROOTFS_DIR}/usr/local/bin/airplanes-webconfig"

install -d -m 755 "${ROOTFS_DIR}/usr/local/bin"

# Surface the pi-gen HEAD SHA inside the binary so /health (and later /api/status)
# can answer "which build is this?" without re-reading the manifest.
WEBCONFIG_VERSION="$(git -C "${BASE_DIR}" rev-parse --short HEAD 2>/dev/null || echo dev)"

( cd "${WEBCONFIG_SRC}" && go build \
	-trimpath -buildvcs=false \
	-ldflags "-s -w -X main.version=${WEBCONFIG_VERSION}" \
	-o "${WEBCONFIG_BIN}" \
	./cmd/webconfig )

chmod 0755 "${WEBCONFIG_BIN}"

# The feed.env writer no longer lives in webconfig — it's `apl-feed apply
# --json`, installed by stage-airplanes/01-install-feed from the feed
# scripts. Sudoers (files/etc/sudoers.d/010_airplanes-webconfig) pins the
# exact argv. webconfig now shells out via that grant.

# Lighttpd reverse-proxy snippet — symlinked into conf-enabled in the chroot.
install -D -m 0644 files/etc/lighttpd/conf-available/40-airplanes-webconfig.conf \
	"${ROOTFS_DIR}/etc/lighttpd/conf-available/40-airplanes-webconfig.conf"

# Systemd units: webconfig itself plus the root-owned reset oneshot.
install -D -m 0644 files/etc/systemd/system/airplanes-webconfig.service \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-webconfig.service"
install -D -m 0644 files/etc/systemd/system/airplanes-webconfig-reset.service \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-webconfig-reset.service"

# Reset script — invoked by airplanes-webconfig-reset.service when the SD-card
# marker /boot/firmware/airplanes-reset-password exists. Runs as root (no
# sandbox) so it can rm under /boot/firmware, which webconfig itself can't.
install -D -m 0755 files/usr/local/lib/airplanes-webconfig/reset \
	"${ROOTFS_DIR}/usr/local/lib/airplanes-webconfig/reset"

# Sudoers entries — installed at 0440 in the chroot step so visudo
# accepts them at runtime.
install -D -m 0644 files/etc/sudoers.d/010_airplanes-webconfig \
	"${ROOTFS_DIR}/etc/sudoers.d/010_airplanes-webconfig"

# tmpfiles.d snippet creates /run/airplanes/ at boot for the feed-env lock
# (root-owned 0755, world-readable but writable only by root). `apl-feed
# apply` locks /run/airplanes/feed-env.lock here.
install -D -m 0644 files/usr/lib/tmpfiles.d/airplanes-webconfig.conf \
	"${ROOTFS_DIR}/usr/lib/tmpfiles.d/airplanes-webconfig.conf"

# Per-user state dir; chowned in the chroot once the airplanes-webconfig user
# exists. Mode 0700 so only that user (and root) can read session secrets.
install -d -m 0700 "${ROOTFS_DIR}/var/lib/airplanes-webconfig"
install -d -m 0700 "${ROOTFS_DIR}/etc/airplanes/webconfig"
