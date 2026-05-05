#!/bin/bash -e

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system"
install -m 644 files/etc/systemd/system/airplanes-first-run.service \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-first-run.service"
install -m 644 files/etc/systemd/system/airplanes-claim.service \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-claim.service"
install -m 644 files/etc/systemd/system/airplanes-claim.timer \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-claim.timer"
install -m 644 files/etc/systemd/system/airplanes-rfkill-unblock.service \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-rfkill-unblock.service"

# Override stage2/02-net-tweaks/01-run.sh: when WPA_COUNTRY is unset (our case
# in config-dev/config-stable) it pre-seeds NetworkManager.state with
# WirelessEnabled=false to prevent radiating before a regdomain is set. We
# rely on rpi-imager's WiFi customization (which sets cfg80211.ieee80211_regdom
# via cmdline) so the WirelessEnabled=false guard is wrong for us. Wipe both
# the NM.state file and any saved WLAN rfkill state from the build chroot so
# the new airplanes-rfkill-unblock.service is the sole source of truth.
rm -f "${ROOTFS_DIR}/var/lib/NetworkManager/NetworkManager.state"
rm -f "${ROOTFS_DIR}"/var/lib/systemd/rfkill/*:wlan*

install -d -m 755 "${ROOTFS_DIR}/usr/local/sbin"
install -m 755 files/usr/local/sbin/airplanes-first-run \
	"${ROOTFS_DIR}/usr/local/sbin/airplanes-first-run"

# Pin the runtime-update branch to the channel this image was built from, so
# `apl-feed update` (which invokes feed/update.sh) doesn't silently fall back
# to feed/main on a dev image. update.sh reads this file as the fallback for
# AIRPLANES_FEED_BRANCH; without it the script defaults to "main" regardless
# of channel. The file is image-identity, not user state — feed.env stays
# user-editable.
#
# Allowlist mirrors the feed-side validation: only main / dev. Refusing to
# ship a bogus pin here surfaces release-config typos at build time instead
# of at every operator's update.
case "${AIRPLANES_FEED_BRANCH:-}" in
	main|dev) ;;
	"")
		echo "AIRPLANES_FEED_BRANCH unset; refusing to ship release-channel" >&2
		exit 1
		;;
	*)
		echo "AIRPLANES_FEED_BRANCH=${AIRPLANES_FEED_BRANCH} not in {main, dev}; refusing to ship release-channel" >&2
		exit 1
		;;
esac
install -d -m 755 "${ROOTFS_DIR}/etc/airplanes"
printf '%s\n' "${AIRPLANES_FEED_BRANCH}" \
	> "${ROOTFS_DIR}/etc/airplanes/release-channel"
chmod 0644 "${ROOTFS_DIR}/etc/airplanes/release-channel"

# pi-gen's export-image stage copies ${ROOTFS_DIR}/boot/firmware/* onto the
# FAT partition during image assembly, so writing the template here lands it
# on partition 1 where SD-card editors can reach it.
install -d -m 755 "${ROOTFS_DIR}/boot/firmware"
install -m 644 files/boot/firmware/airplanes-config.txt \
	"${ROOTFS_DIR}/boot/firmware/airplanes-config.txt"

on_chroot <<'EOF'
PATH="/usr/local/sbin:${PATH}" systemctl enable \
	airplanes-first-run.service airplanes-claim.timer \
	airplanes-rfkill-unblock.service
EOF
