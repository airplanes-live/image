#!/bin/bash
# Boot-free smoke for /usr/local/sbin/airplanes-first-run. Mounts the built
# image, runs the script via chroot, and asserts the side effects (feeder-id,
# done marker, feed.env integrity) without needing a full QEMU boot.
#
# Usage: first-run-chroot-smoke.sh PATH_TO_IMAGE.img.xz
#
# Requires: root (for losetup/mount/chroot), xz-utils. Cross-arch chroot
# additionally needs qemu-user-static + binfmt-misc registered for the target
# arch. Native chroot (e.g. arm64 host running an arm64 image) skips the
# qemu staging entirely.

set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
	exec sudo -E bash "$0" "$@"
fi

IMG_XZ="${1:?usage: first-run-chroot-smoke.sh PATH_TO_IMAGE.img.xz}"
[[ -f "$IMG_XZ" ]] || { echo "image not found: $IMG_XZ" >&2; exit 1; }

case "$(basename "$IMG_XZ")" in
	*-arm64.img.xz)  TARGET_ARCH=arm64 ; QEMU_BIN=qemu-aarch64-static ;;
	*-armhf.img.xz)  TARGET_ARCH=armhf ; QEMU_BIN=qemu-arm-static ;;
	*) echo "cannot infer arch from filename: $IMG_XZ" >&2; exit 1 ;;
esac

# Native chroot: host arch matches target, no qemu translation needed. Skips
# the qemu-user-static dependency on native arm64 runners.
case "$(uname -m)" in
	aarch64)        HOST_ARCH=arm64 ;;
	armv7l|armv6l)  HOST_ARCH=armhf ;;
	*)              HOST_ARCH="$(uname -m)" ;;
esac
if [[ "$HOST_ARCH" == "$TARGET_ARCH" ]]; then
	QEMU_BIN=""
fi

if [[ -n "$QEMU_BIN" && ! -x "/usr/bin/${QEMU_BIN}" ]]; then
	echo "missing /usr/bin/${QEMU_BIN}; install qemu-user-static" >&2
	exit 1
fi

WORK_DIR="$(mktemp -d)"
LOOP_DEV=""
ROOT_MNT="$WORK_DIR/r"
QEMU_COPIED=""

cleanup() {
	set +e
	if mountpoint -q "$ROOT_MNT/dev"; then umount -R "$ROOT_MNT/dev"; fi
	if mountpoint -q "$ROOT_MNT/sys"; then umount -R "$ROOT_MNT/sys"; fi
	if mountpoint -q "$ROOT_MNT/proc"; then umount "$ROOT_MNT/proc"; fi
	if mountpoint -q "$ROOT_MNT/boot/firmware"; then umount "$ROOT_MNT/boot/firmware"; fi
	if mountpoint -q "$ROOT_MNT"; then umount "$ROOT_MNT"; fi
	if [[ -n "$LOOP_DEV" ]]; then losetup -d "$LOOP_DEV"; fi
	if [[ -n "$QEMU_COPIED" && -f "$QEMU_COPIED" ]]; then rm -f "$QEMU_COPIED"; fi
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$ROOT_MNT"

echo "==> decompressing $IMG_XZ"
IMG_FILE="$WORK_DIR/$(basename "${IMG_XZ%.xz}")"
xz -dkc -- "$IMG_XZ" > "$IMG_FILE"

echo "==> attaching loop"
LOOP_DEV="$(losetup --show --find --partscan "$IMG_FILE")"
[[ -b "${LOOP_DEV}p2" ]] || { echo "expected ${LOOP_DEV}p2 (rootfs)"; exit 1; }
[[ -b "${LOOP_DEV}p1" ]] || { echo "expected ${LOOP_DEV}p1 (FAT/boot)"; exit 1; }

echo "==> mounting rootfs ${LOOP_DEV}p2 -> $ROOT_MNT"
mount -o ro,noload "${LOOP_DEV}p2" "$ROOT_MNT" 2>/dev/null || mount "${LOOP_DEV}p2" "$ROOT_MNT"
mount -o remount,rw "$ROOT_MNT"

echo "==> mounting FAT ${LOOP_DEV}p1 -> $ROOT_MNT/boot/firmware"
mkdir -p "$ROOT_MNT/boot/firmware"
mount "${LOOP_DEV}p1" "$ROOT_MNT/boot/firmware"

if [[ -n "$QEMU_BIN" ]]; then
	echo "==> staging $QEMU_BIN"
	QEMU_COPIED="$ROOT_MNT/usr/bin/$QEMU_BIN"
	cp "/usr/bin/$QEMU_BIN" "$QEMU_COPIED"
else
	echo "==> native chroot ($HOST_ARCH==$TARGET_ARCH); skipping qemu staging"
fi

# create-uuid.sh inside the chroot reads /proc/sys/kernel/random/uuid; without
# /proc mounted it falls back to no-uuid and feeder-id never gets written.
echo "==> bind-mounting /proc /sys /dev into chroot"
mount -t proc proc "$ROOT_MNT/proc"
mount --rbind /sys "$ROOT_MNT/sys"
mount --rbind /dev "$ROOT_MNT/dev"

echo "==> seeding airplanes-config.txt with real values"
# Overwrite the shipped sentinel template with realistic values so we can
# assert the merge into feed.env actually lands user-set keys (not just
# "feed.env still parses"). DUMP978=no is the sentinel, must NOT propagate.
# WIFI_PASSWORD (typo) seeded to verify it does NOT leak into feed.env.
cat > "$ROOT_MNT/boot/firmware/airplanes-config.txt" <<'CFG'
LATITUDE=51.5
LONGITUDE=-0.1
ALTITUDE=42m
USER=ci-smoke
DUMP978=no
WIFI_SSID="Test Net"
WIFI_PASS="hunter22-secret"
WIFI_COUNTRY=DE
WIFI_PASSWORD=should-not-leak
CFG

# Mock raspi-config / iw inside the chroot so apply_wifi_country doesn't
# touch the host kernel's regdomain via the bind-mounted /sys + /proc.
echo "==> staging raspi-config / iw mocks inside chroot"
mkdir -p "$ROOT_MNT/usr/local/bin-mocks"
cat > "$ROOT_MNT/usr/local/bin-mocks/raspi-config" <<'STUB'
#!/bin/sh
echo "[mock] raspi-config $*" >> /var/log/airplanes-first-run-mocks.log
exit 0
STUB
cat > "$ROOT_MNT/usr/local/bin-mocks/iw" <<'STUB'
#!/bin/sh
echo "[mock] iw $*" >> /var/log/airplanes-first-run-mocks.log
exit 0
STUB
chmod +x "$ROOT_MNT/usr/local/bin-mocks/raspi-config" "$ROOT_MNT/usr/local/bin-mocks/iw"

echo "==> running airplanes-first-run inside chroot (with mocks on PATH)"
# shellcheck disable=SC2016 # $PATH expanded by chroot's bash, not ours
chroot "$ROOT_MNT" /bin/bash -c \
	'PATH=/usr/local/bin-mocks:$PATH /usr/local/sbin/airplanes-first-run'

echo "==> asserting feeder-id exists and is a valid UUID"
FEEDER_ID_FILE="$ROOT_MNT/etc/airplanes/feeder-id"
[[ -f "$FEEDER_ID_FILE" ]] || { echo "feeder-id missing"; exit 1; }
FEEDER_ID="$(tr -d '\n\r{}' < "$FEEDER_ID_FILE" | tr 'A-F' 'a-f')"
[[ "$FEEDER_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
	|| { echo "feeder-id is not a valid UUID: $FEEDER_ID"; exit 1; }

echo "==> asserting first-run-done marker exists"
[[ -f "$ROOT_MNT/var/lib/airplanes/first-run-done" ]] \
	|| { echo "first-run-done marker missing"; exit 1; }

echo "==> asserting feed.env merged the seeded boot config"
unset LATITUDE LONGITUDE ALTITUDE USER
# shellcheck source=/dev/null
( set -a; source "$ROOT_MNT/etc/airplanes/feed.env"; set +a; \
	[[ "$LATITUDE" == "51.5" ]] || { echo "LATITUDE not merged: $LATITUDE"; exit 1; }; \
	[[ "$LONGITUDE" == "-0.1" ]] || { echo "LONGITUDE not merged: $LONGITUDE"; exit 1; }; \
	[[ "$ALTITUDE" == "42m" ]] || { echo "ALTITUDE not merged: $ALTITUDE"; exit 1; }; \
	[[ "$USER" == "ci-smoke" ]] || { echo "USER not merged: $USER"; exit 1; } \
) || { echo "feed.env merge assertions failed"; exit 1; }

echo "==> asserting WiFi keyfile generated and locked down"
WIFI_KEYFILE="$ROOT_MNT/etc/NetworkManager/system-connections/airplanes-config-wifi.nmconnection"
[[ -f "$WIFI_KEYFILE" ]] || { echo "WiFi keyfile missing: $WIFI_KEYFILE"; exit 1; }
[[ "$(stat -c %a "$WIFI_KEYFILE")" == "600" ]] \
	|| { echo "WiFi keyfile mode != 0600: $(stat -c %a "$WIFI_KEYFILE")"; exit 1; }
grep -q '^ssid=Test Net$' "$WIFI_KEYFILE" \
	|| { echo "WiFi keyfile missing ssid=Test Net"; exit 1; }
grep -q '^psk=hunter22-secret$' "$WIFI_KEYFILE" \
	|| { echo "WiFi keyfile missing psk=hunter22-secret"; exit 1; }
grep -q '^autoconnect=true$' "$WIFI_KEYFILE" \
	|| { echo "WiFi keyfile missing autoconnect=true"; exit 1; }

echo "==> asserting raspi-config nonint do_wifi_country DE was invoked"
grep -q 'raspi-config nonint do_wifi_country DE' "$ROOT_MNT/var/log/airplanes-first-run-mocks.log" \
	|| { echo "raspi-config not invoked for country"; exit 1; }

echo "==> asserting WIFI_* keys did NOT leak into feed.env"
if grep -E '^WIFI_' "$ROOT_MNT/etc/airplanes/feed.env"; then
	echo "WIFI_* keys leaked into feed.env"; exit 1
fi

echo "OK: feeder-id=$FEEDER_ID, boot-config merge confirmed, WiFi keyfile written, no leaks"
