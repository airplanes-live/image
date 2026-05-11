#!/bin/bash
# Boot-free smoke for /usr/local/sbin/airplanes-first-run. Mounts the built
# image, runs the script via chroot, and asserts the side effects (feeder-id,
# boot-config consumption / rename to .applied.txt, feed.env integrity)
# without needing a full QEMU boot. Note: chroot bypasses systemd's
# ProtectSystem / ReadWritePaths sandboxing, so this smoke cannot catch
# sandbox-related write failures — see image/test/test_first_run_unit.bats
# for the static unit-file lint that covers that gap.
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
# FEED_HOST seeded to verify expand_feed_host runs end-to-end: derived
# MLATSERVER and TARGET must land in feed.env, and FEED_HOST itself must NOT.
# Only valid, recognized keys are seeded here: strict consume-and-rename
# blocks the rename on ANY recorded error (typo'd WIFI_PASSWORD,
# unrecognized keys, etc.). The unrecognized-key / typo-leak coverage
# lives in test/test_first_run_consume.bats and test/test_first_run_wifi.bats.
cat > "$ROOT_MNT/boot/firmware/airplanes-config.txt" <<'CFG'
LATITUDE=51.5
LONGITUDE=-0.1
ALTITUDE=42m
MLAT_USER=ci-smoke
MLAT_ENABLED=true
DUMP978=no
HOSTNAME=ci-smoke-feeder
FEED_HOST=test.local
WIFI_SSID="Test Net"
WIFI_PASS="hunter22-secret"
WIFI_COUNTRY=DE
CFG

# RuntimeDirectory=airplanes (in the unit file) creates /run/airplanes/ when
# the unit runs under systemd. The chroot smoke bypasses systemd, so create
# the directory manually here — without it, merge_feed_env's flock target
# (/run/airplanes/feed-env.lock) has no parent and bash's 9>... redirect
# fails before flock even runs.
mkdir -p "$ROOT_MNT/run/airplanes"

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

echo "==> asserting boot config was consumed (renamed to .applied.txt)"
[[ ! -f "$ROOT_MNT/boot/firmware/airplanes-config.txt" ]] \
	|| { echo "airplanes-config.txt still present after successful first-run"; exit 1; }
[[ -f "$ROOT_MNT/boot/firmware/airplanes-config.applied.txt" ]] \
	|| { echo "airplanes-config.applied.txt missing"; exit 1; }
[[ -s "$ROOT_MNT/boot/firmware/airplanes-config.applied.txt" ]] \
	|| { echo "airplanes-config.applied.txt is empty"; exit 1; }
[[ ! -f "$ROOT_MNT/boot/firmware/airplanes-config.error.txt" ]] \
	|| { echo "unexpected airplanes-config.error.txt present"; cat "$ROOT_MNT/boot/firmware/airplanes-config.error.txt" >&2; exit 1; }

echo "==> asserting feed.env merged the seeded boot config"
unset LATITUDE LONGITUDE ALTITUDE USER MLAT_USER MLAT_ENABLED MLATSERVER TARGET FEED_HOST
# shellcheck source=/dev/null
( set -a; source "$ROOT_MNT/etc/airplanes/feed.env"; set +a; \
	[[ "$LATITUDE" == "51.5" ]] || { echo "LATITUDE not merged: $LATITUDE"; exit 1; }; \
	[[ "$LONGITUDE" == "-0.1" ]] || { echo "LONGITUDE not merged: $LONGITUDE"; exit 1; }; \
	[[ "$ALTITUDE" == "42m" ]] || { echo "ALTITUDE not merged: $ALTITUDE"; exit 1; }; \
	[[ "$MLAT_USER" == "ci-smoke" ]] || { echo "MLAT_USER not merged: $MLAT_USER"; exit 1; }; \
	[[ "$MLAT_ENABLED" == "true" ]] || { echo "MLAT_ENABLED not merged: $MLAT_ENABLED"; exit 1; }; \
	[[ -z "${USER:-}" ]] || { echo "legacy USER leaked into feed.env: $USER"; exit 1; }; \
	[[ "$MLATSERVER" == "test.local:31090" ]] || { echo "MLATSERVER not derived from FEED_HOST: $MLATSERVER"; exit 1; }; \
	[[ "$TARGET" == "--net-connector test.local,30004,beast_reduce_plus_out" ]] || { echo "TARGET not derived from FEED_HOST: $TARGET"; exit 1; }; \
	[[ -z "${FEED_HOST:-}" ]] || { echo "FEED_HOST leaked into feed.env: $FEED_HOST"; exit 1; } \
) || { echo "feed.env merge assertions failed"; exit 1; }

echo "==> asserting FEED_HOST line did NOT leak into feed.env on disk"
if grep -E '^FEED_HOST=' "$ROOT_MNT/etc/airplanes/feed.env"; then
	echo "FEED_HOST= line present in feed.env"; exit 1
fi

echo "==> asserting HOSTNAME applied to /etc/hostname and /etc/hosts"
HN_ACTUAL="$(tr -d '\n\r' < "$ROOT_MNT/etc/hostname")"
[[ "$HN_ACTUAL" == "ci-smoke-feeder" ]] \
	|| { echo "/etc/hostname not updated: got '$HN_ACTUAL'"; exit 1; }
grep -qP '^127\.0\.1\.1\s+ci-smoke-feeder(\s|$)' "$ROOT_MNT/etc/hosts" \
	|| { echo "/etc/hosts 127.0.1.1 line not updated"; cat "$ROOT_MNT/etc/hosts" >&2; exit 1; }

echo "==> asserting HOSTNAME line did NOT leak into feed.env on disk"
if grep -E '^HOSTNAME=' "$ROOT_MNT/etc/airplanes/feed.env"; then
	echo "HOSTNAME= line present in feed.env"; exit 1
fi

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

echo "==> asserting SSH posture drop-in is shipped"
SSHD_DROPIN="$ROOT_MNT/etc/ssh/sshd_config.d/90-airplanes.conf"
[[ -f "$SSHD_DROPIN" ]] || { echo "missing $SSHD_DROPIN"; exit 1; }
grep -Eq '^[[:space:]]*PasswordAuthentication[[:space:]]+no[[:space:]]*$' "$SSHD_DROPIN" \
	|| { echo "PasswordAuthentication no missing from drop-in"; exit 1; }
grep -Eq '^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+no[[:space:]]*$' "$SSHD_DROPIN" \
	|| { echo "KbdInteractiveAuthentication no missing from drop-in"; exit 1; }
grep -Eq '^[[:space:]]*PubkeyAuthentication[[:space:]]+yes[[:space:]]*$' "$SSHD_DROPIN" \
	|| { echo "PubkeyAuthentication yes missing from drop-in"; exit 1; }

# sshd -T resolves the *effective* config (Include chain + first-match), not
# what's in any one snippet. Catches drift like the main sshd_config moving
# the Include below a hardcoded PasswordAuthentication, or a future stage
# adding an overriding snippet that lexically wins. Host keys are needed for
# sshd to start; ssh-keygen -A here doesn't reach the .img.xz artifact since
# smoke operates on a temp-decompressed copy.
echo "==> asserting effective sshd config rejects password auth by default"
mkdir -p "$ROOT_MNT/run/sshd"
chroot "$ROOT_MNT" /usr/bin/ssh-keygen -A >/dev/null 2>&1 \
	|| { echo "ssh-keygen -A failed in chroot"; exit 1; }
sshd_dump() {
	chroot "$ROOT_MNT" /usr/sbin/sshd -T -C "user=pi,host=localhost,addr=127.0.0.1" 2>/dev/null
}
sshd_dump | grep -qx 'passwordauthentication no' \
	|| { echo "effective PasswordAuthentication != no"; sshd_dump | grep -E 'authentication' >&2; exit 1; }
sshd_dump | grep -qx 'kbdinteractiveauthentication no' \
	|| { echo "effective KbdInteractiveAuthentication != no"; exit 1; }
sshd_dump | grep -qx 'pubkeyauthentication yes' \
	|| { echo "effective PubkeyAuthentication != yes"; exit 1; }

echo "==> asserting stale 'valid user' SSH banner is absent"
for stale_banner in /etc/ssh/sshd_banner /etc/ssh/sshd_config.d/rename_user.conf; do
	[[ ! -e "$ROOT_MNT$stale_banner" ]] \
		|| { echo "stale banner file present: $stale_banner"; exit 1; }
done

echo "==> asserting userconfig + systemd-firstboot are masked"
for masked_unit in userconfig.service systemd-firstboot.service; do
	link="$ROOT_MNT/etc/systemd/system/$masked_unit"
	[[ -L "$link" ]] \
		|| { echo "$masked_unit not masked (no symlink in /etc/systemd/system/)"; exit 1; }
	[[ "$(readlink "$link")" == "/dev/null" ]] \
		|| { echo "$masked_unit symlink does not point at /dev/null"; exit 1; }
done

echo "==> asserting cloud-init's 50-cloud-init.conf can override 90-airplanes.conf"
# Simulates the rpi-imager "SSH on + password" path: cc_set_passwords writes
# PasswordAuthentication yes into 50-cloud-init.conf, lexically beats our
# 90-airplanes.conf. Regression guard for any future change that would block
# the explicit-opt-in flow.
cat > "$ROOT_MNT/etc/ssh/sshd_config.d/50-cloud-init.conf" <<'CIEOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
CIEOF
sshd_dump | grep -qx 'passwordauthentication yes' \
	|| { echo "cloud-init 50- override did not flip pwauth to yes"; exit 1; }
sshd_dump | grep -qx 'kbdinteractiveauthentication yes' \
	|| { echo "cloud-init 50- override did not flip kbd-interactive to yes"; exit 1; }
rm -f "$ROOT_MNT/etc/ssh/sshd_config.d/50-cloud-init.conf"

echo "OK: feeder-id=$FEEDER_ID, boot-config merge confirmed, WiFi keyfile written, no leaks"
