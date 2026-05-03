#!/bin/bash -e

: "${AIRPLANES_READSB_DECODER_REPO:?must be set by config-stable/dev}"
: "${AIRPLANES_READSB_DECODER_BRANCH:?must be set by config-stable/dev}"
: "${AIRPLANES_DUMP978_REPO:?must be set by config-stable/dev}"
: "${AIRPLANES_DUMP978_BRANCH:?must be set by config-stable/dev}"

# Sources land outside chroot under /usr/local/src; cleaned up in 02-run.sh
# after the chroot compile step. NOT /tmp — on_chroot mounts tmpfs there.
fetch_repo() {
	local dir="$1" repo="$2" ref="$3"
	rm -rf "$dir"
	install -d -m 755 "$dir"
	git -C "$dir" init -q
	git -C "$dir" remote add origin "$repo"
	git -C "$dir" fetch --depth 1 origin "$ref"
	git -C "$dir" checkout -q FETCH_HEAD
}

READSB_DIR="${ROOTFS_DIR}/usr/local/src/airplanes-readsb-build"
DUMP978_DIR="${ROOTFS_DIR}/usr/local/src/airplanes-dump978-build"

fetch_repo "$READSB_DIR" "$AIRPLANES_READSB_DECODER_REPO" "$AIRPLANES_READSB_DECODER_BRANCH"
git -C "$READSB_DIR" rev-parse HEAD > "${ROOTFS_DIR}/etc/airplanes/.build-readsb-decoder-sha"

fetch_repo "$DUMP978_DIR" "$AIRPLANES_DUMP978_REPO" "$AIRPLANES_DUMP978_BRANCH"
git -C "$DUMP978_DIR" rev-parse HEAD > "${ROOTFS_DIR}/etc/airplanes/.build-dump978-sha"

# Wrapper scripts under /usr/local/share/airplanes/ — image-owned argv shapers,
# sourced from /etc/airplanes/feed.env via systemd EnvironmentFile=.
install -D -m 0755 files/usr/local/share/airplanes/readsb.sh \
	"${ROOTFS_DIR}/usr/local/share/airplanes/readsb.sh"
install -D -m 0755 files/usr/local/share/airplanes/airplanes-978.sh \
	"${ROOTFS_DIR}/usr/local/share/airplanes/airplanes-978.sh"
install -D -m 0755 files/usr/local/share/airplanes/dump978-fa.sh \
	"${ROOTFS_DIR}/usr/local/share/airplanes/dump978-fa.sh"

# Image-owned systemd units. readsb is enabled in 01-run-chroot.sh; the two 978
# units stay disabled until first-run flips them on DUMP978=yes.
install -D -m 0644 files/etc/systemd/system/readsb.service \
	"${ROOTFS_DIR}/etc/systemd/system/readsb.service"
install -D -m 0644 files/etc/systemd/system/dump978-fa.service \
	"${ROOTFS_DIR}/etc/systemd/system/dump978-fa.service"
install -D -m 0644 files/etc/systemd/system/airplanes-978.service \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-978.service"
