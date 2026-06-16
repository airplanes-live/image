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

# generate_feeder_id reads /proc/sys/kernel/random/uuid; without /proc mounted
# the read fails and feeder-id never gets written.
echo "==> bind-mounting /proc /sys /dev into chroot"
mount -t proc proc "$ROOT_MNT/proc"
mount --rbind /sys "$ROOT_MNT/sys"
mount --rbind /dev "$ROOT_MNT/dev"

echo "==> seeding airplanes-config.txt with the 6-key allowlist"
# Overwrite the shipped (all-commented) template with concrete values so we
# can assert each allowlist path end-to-end. The boot config's job is
# bootstrap only — hostname for mDNS discovery, WiFi creds for network
# join, FEED_HOST to point at a non-prod backend. Operational config
# (LATITUDE/LONGITUDE/ALTITUDE/MLAT_USER/MLAT_ENABLED/GAIN/UAT_INPUT) lives
# in the webconfig UI; the parse-time allowlist rejects those keys here.
# Strict consume-and-rename blocks the rename on ANY recorded error
# (typo'd WIFI_PASSWORD, allowlist rejection, etc.); the unrecognized-key /
# typo-leak coverage lives in test/test_first_run_parser.bats and
# test/test_first_run_consume.bats.
cat > "$ROOT_MNT/boot/firmware/airplanes-config.txt" <<'CFG'
HOSTNAME=ci-smoke-feeder
FEED_HOST=test.local
WEBSITE_URL=http://homelab.airplanes.test
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

echo "==> asserting feed.env carries the FEED_HOST-derived endpoints"
# The only operational keys the boot config can affect now are MLATSERVER and
# TARGET, both synthesized by expand_feed_host from FEED_HOST. Everything
# else in feed.env (LATITUDE/LONGITUDE/ALTITUDE/MLAT_USER/MLAT_ENABLED/
# UAT_INPUT/etc.) was written by feed/configure.sh during the chroot install
# and must survive the first-run merge unchanged — don't pin their specific
# values though, that's configure.sh's concern; assert presence only.
unset LATITUDE LONGITUDE ALTITUDE USER MLAT_USER MLAT_ENABLED MLATSERVER TARGET FEED_HOST UAT_INPUT APL_FEED_WEBSITE_URL WEBSITE_URL
# shellcheck source=/dev/null
( set -a; source "$ROOT_MNT/etc/airplanes/feed.env"; set +a; \
	[[ "$MLATSERVER" == "test.local:31090" ]] || { echo "MLATSERVER not derived from FEED_HOST: $MLATSERVER"; exit 1; }; \
	[[ "$TARGET" == "--net-connector test.local,30004,beast_reduce_plus_out" ]] || { echo "TARGET not derived from FEED_HOST: $TARGET"; exit 1; }; \
	[[ "$APL_FEED_WEBSITE_URL" == "http://homelab.airplanes.test" ]] || { echo "APL_FEED_WEBSITE_URL not derived from WEBSITE_URL: $APL_FEED_WEBSITE_URL"; exit 1; }; \
	[[ -z "${FEED_HOST:-}" ]] || { echo "FEED_HOST leaked into feed.env: $FEED_HOST"; exit 1; }; \
	[[ -z "${WEBSITE_URL:-}" ]] || { echo "WEBSITE_URL leaked into feed.env: $WEBSITE_URL"; exit 1; }; \
	[[ -z "${USER:-}" ]] || { echo "legacy USER leaked into feed.env: $USER"; exit 1; }; \
	[[ -v MLAT_USER ]] || { echo "MLAT_USER missing from feed.env (configure.sh default lost)"; exit 1; }; \
	[[ -v MLAT_ENABLED ]] || { echo "MLAT_ENABLED missing from feed.env"; exit 1; }; \
	[[ -v LATITUDE ]] || { echo "LATITUDE missing from feed.env"; exit 1; }; \
	[[ -v LONGITUDE ]] || { echo "LONGITUDE missing from feed.env"; exit 1; }; \
	[[ -v ALTITUDE ]] || { echo "ALTITUDE missing from feed.env"; exit 1; } \
) || { echo "feed.env merge assertions failed"; exit 1; }

echo "==> asserting synthetic keys did NOT leak into feed.env on disk"
if grep -E '^FEED_HOST=' "$ROOT_MNT/etc/airplanes/feed.env"; then
	echo "FEED_HOST= line present in feed.env"; exit 1
fi
# WEBSITE_URL is allowlisted but synthetic — renamed to APL_FEED_WEBSITE_URL.
if grep -E '^WEBSITE_URL=' "$ROOT_MNT/etc/airplanes/feed.env"; then
	echo "WEBSITE_URL= line present in feed.env (should have been renamed)"; exit 1
fi
# HOSTNAME is allowlisted but synthetic — applied to /etc/hostname only.
if grep -E '^HOSTNAME=' "$ROOT_MNT/etc/airplanes/feed.env"; then
	echo "HOSTNAME= line present in feed.env"; exit 1
fi

echo "==> asserting HOSTNAME applied to /etc/hostname and /etc/hosts"
HN_ACTUAL="$(tr -d '\n\r' < "$ROOT_MNT/etc/hostname")"
[[ "$HN_ACTUAL" == "ci-smoke-feeder" ]] \
	|| { echo "/etc/hostname not updated: got '$HN_ACTUAL'"; exit 1; }
grep -qP '^127\.0\.1\.1\s+ci-smoke-feeder(\s|$)' "$ROOT_MNT/etc/hosts" \
	|| { echo "/etc/hosts 127.0.1.1 line not updated"; cat "$ROOT_MNT/etc/hosts" >&2; exit 1; }

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
grep -Eq '^[[:space:]]*AuthorizedKeysFile[[:space:]]+\.ssh/authorized_keys[[:space:]]+/etc/ssh/authorized_keys\.d/%u[[:space:]]*$' "$SSHD_DROPIN" \
	|| { echo "AuthorizedKeysFile line missing from drop-in"; exit 1; }

echo "==> asserting managed authorized_keys.d directory exists"
[[ -d "$ROOT_MNT/etc/ssh/authorized_keys.d" ]] \
	|| { echo "missing /etc/ssh/authorized_keys.d"; exit 1; }

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

echo "==> asserting the per-device SSH opt-in snippet scopes pwauth to pi only"
# The 99-airplanes-ssh-pi.conf snippet (dropped by apply_ssh_password / apl-ssh)
# is Match User pi -> PasswordAuthentication yes. With it present, the effective
# config must flip pwauth to yes for user=pi while every other user keeps the
# 90-airplanes.conf default of no.
cat > "$ROOT_MNT/etc/ssh/sshd_config.d/99-airplanes-ssh-pi.conf" <<'PIEOF'
# airplanes.live per-device opt-in: enables password SSH for the pi account
# only (Match-scoped, so other users keep the 90-airplanes.conf default of
# PasswordAuthentication no). Written by airplanes-first-run (boot config) and
# webconfig's apl-ssh helper.
Match User pi
    PasswordAuthentication yes
Match all
PIEOF
sshd_dump_user() {
	chroot "$ROOT_MNT" /usr/sbin/sshd -T -C "user=$1,host=localhost,addr=127.0.0.1" 2>/dev/null
}
sshd_dump_user pi | grep -qx 'passwordauthentication yes' \
	|| { echo "99 snippet did not enable pwauth for user=pi"; exit 1; }
sshd_dump_user matt | grep -qx 'passwordauthentication no' \
	|| { echo "99 snippet leaked pwauth to a non-pi user (user=matt)"; exit 1; }
rm -f "$ROOT_MNT/etc/ssh/sshd_config.d/99-airplanes-ssh-pi.conf"

echo "OK: feeder-id=$FEEDER_ID, boot-config merge confirmed, WiFi keyfile written, no leaks"
