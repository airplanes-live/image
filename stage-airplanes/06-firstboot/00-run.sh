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

# Pin the runtime-update channel this image ships on, so `apl-feed update`
# (which invokes feed/update.sh) resolves to the right release stream. The
# build-time clone target (AIRPLANES_FEED_BRANCH) and the runtime update
# channel are different concerns — the former is a SHA/branch/tag the image
# was built from, the latter is "stable" or "dev" telling the feed-side
# resolver which release stream to track at update time. We write only the
# update channel here.
#
# Allowlist mirrors the feed-side validation: only stable / dev. Refusing
# to ship a bogus pin here surfaces release-config typos at build time
# instead of at every operator's update. The feed-side parser additionally
# accepts "main" as a legacy alias for stable so older images shipped
# before this rename still resolve correctly; new images should write
# only the canonical names.
case "${AIRPLANES_FEED_UPDATE_CHANNEL:-}" in
	stable|dev) ;;
	"")
		echo "AIRPLANES_FEED_UPDATE_CHANNEL unset; refusing to ship release-channel" >&2
		exit 1
		;;
	*)
		echo "AIRPLANES_FEED_UPDATE_CHANNEL=${AIRPLANES_FEED_UPDATE_CHANNEL} not in {stable, dev}; refusing to ship release-channel" >&2
		exit 1
		;;
esac
install -d -m 755 "${ROOTFS_DIR}/etc/airplanes"
printf '%s\n' "${AIRPLANES_FEED_UPDATE_CHANNEL}" \
	> "${ROOTFS_DIR}/etc/airplanes/release-channel"
chmod 0644 "${ROOTFS_DIR}/etc/airplanes/release-channel"

# Image-install provenance marker. Its presence tells the feed daemons this is
# an overlay-image feeder, distinguishing it from a standalone feed install
# (which has neither marker nor binary) and from a legacy image (detected
# instead by the baked /usr/bin/airplanes-feeder binary the marker post-dates).
# Only presence is contractual: feed reads it with `-f` and never sources it,
# so the body is a shell-safe comment for anyone who cats the file. Baked here
# rather than delivered by the runtime overlay so the flag stays permanent
# across overlay updates, rollbacks, or removal — the same reason
# release-channel is baked.
printf '%s\n' '# airplanes.live image-install marker; presence signals an overlay-image feeder.' \
	> "${ROOTFS_DIR}/etc/airplanes/image-install"
chmod 0644 "${ROOTFS_DIR}/etc/airplanes/image-install"

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
