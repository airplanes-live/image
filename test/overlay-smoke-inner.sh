#!/usr/bin/env bash
# Inner half of overlay-smoke.sh; runs inside debian:trixie-slim. See
# test/overlay-smoke.sh for context and scope.

set -euo pipefail

# shellcheck source=lib/overlay-common.sh
. /image/test/lib/overlay-common.sh

echo "==> stage-airplanes/00-prep/00-run.sh"
# Run from the stage dir so relative `files/` paths inside 00-run.sh resolve.
( cd /image/stage-airplanes/00-prep && bash 00-run.sh )

echo "==> stage-airplanes/00-prep/03-run.sh (mask first-boot prompts)"
( cd /image/stage-airplanes/00-prep && bash 03-run.sh )

echo "==> stage-airplanes/00-prep/04-run.sh (force cloud-init debian distro)"
( cd /image/stage-airplanes/00-prep && bash 04-run.sh )

echo "==> stage-airplanes/01-install-feed/01-run-chroot.sh (service account + state dirs)"
# Stage 01 is setup-only now. The feed binary, daemon wrappers, apl-feed CLI,
# systemd units, runtime libs, and the mlat-client venv arrive through the
# runtime overlay at stage 02 (managed_paths) — which this fast smoke
# deliberately does NOT run (it needs signed release downloads). Stage 01
# retains only the airplanes-feed service account + group creation, state dirs,
# and video-group membership.
( cd /image/stage-airplanes/01-install-feed && bash 01-run-chroot.sh )

echo "==> stage-airplanes/05-install-webconfig/00-run.sh (image-owned tmpfiles)"
# Stage 05 is setup-only now. The webconfig binary, helpers, systemd units,
# sudoers, and the lighttpd conf-available snippet arrive through the runtime
# overlay at stage 02 (managed_paths) — which this fast smoke deliberately
# does NOT run (it needs signed release downloads). So stage 05's host-side
# step (the image-owned tmpfiles) is the only part exercisable here; the
# chroot step's lighttpd conf-enabled activation depends on the overlay's
# conf-available symlink and is covered by the full build + boot-smoke. The
# webconfig user/group/state-dir + service-account contract is asserted by
# the runtime-overlay stage tests, not here.
( cd /image/stage-airplanes/05-install-webconfig && bash 00-run.sh )

echo "==> stage-airplanes/06-firstboot/00-run.sh"
# Seed NM state + saved WLAN rfkill so we can assert stage 06 wipes them.
# Mirrors what pi-gen's stage2/02-net-tweaks/01-run.sh writes when WPA_COUNTRY
# is unset; stage 06 overrides that policy and must clear both.
mkdir -p /var/lib/NetworkManager /var/lib/systemd/rfkill
cat > /var/lib/NetworkManager/NetworkManager.state <<'NMSTATE'
[main]
NetworkingEnabled=true
WirelessEnabled=false
WWANEnabled=true
NMSTATE
echo 1 > /var/lib/systemd/rfkill/platform-3f300000.mmcnr:wlan
# pi-gen runs on_chroot via its own helper; we stub that at the top of this
# script. The stage's `install` commands take relative `files/` paths.
( cd /image/stage-airplanes/06-firstboot && bash 00-run.sh )

echo "==> contract assertions"
fail() { echo "FAIL: $*" >&2; exit 1; }
# Stage 01 is setup-only now (service account + state dirs). Feed artifacts
# (feed-airplanes binary, apl-feed CLI, daemon wrappers, systemd units, runtime
# libs, mlat-client venv, feed.env, image-install marker, enable links) arrive
# through the runtime overlay at stage 02 (managed_paths + migrations), which
# this fast smoke does NOT run. Assertions below cover only what stages 00 + 01
# + 06 produce, not the overlay-delivered feed surface. The full image build +
# boot-smoke cover the feed overlay path end to end.
[[ -d /etc/airplanes ]] || fail "/etc/airplanes dir missing (stage 01 chroot)"
id -u airplanes-feed >/dev/null 2>&1 || fail "airplanes-feed user missing (stage 01 chroot)"
getent group airplanes-feed >/dev/null 2>&1 || fail "airplanes-feed group missing (stage 01 chroot)"
[[ ! -f /etc/airplanes/feeder-id ]] || fail "feeder-id should NOT exist in build mode"
[[ ! -f /etc/airplanes/feeder-claim-secret ]] || fail "feeder-claim-secret should NOT exist in build mode"
[[ ! -e /usr/local/share/airplanes/airplanes-uuid ]] || fail "airplanes-uuid symlink should NOT exist (new contract)"

# enable links helper (reused by stage 06 assertions below).
have_enable_link() {
    local unit="$1"
    [[ -L "/etc/systemd/system/default.target.wants/$unit" \
        || -L "/etc/systemd/system/multi-user.target.wants/$unit" ]]
}

# Stage 00-prep outputs (relative-path install commands; previously silent
# failures masked by absolute-path commands picking up the slack).
[[ -x /usr/sbin/policy-rc.d ]] || fail "policy-rc.d missing (00-prep relative path?)"

# 03-run.sh masks first-boot prompts: a /etc/systemd/system/<unit> symlink
# pointing at /dev/null is the canonical systemd "masked" state. Both must
# land regardless of whether the target services exist on this rootfs.
for masked_unit in userconfig.service systemd-firstboot.service; do
    [[ -L "/etc/systemd/system/$masked_unit" ]] \
        || fail "$masked_unit not masked (no symlink in /etc/systemd/system/)"
    [[ "$(readlink "/etc/systemd/system/$masked_unit")" == "/dev/null" ]] \
        || fail "$masked_unit symlink does not point at /dev/null"
done

# 04-run.sh forces cloud-init off raspberry_pi_os Distro. Without this,
# cc_users_groups blows up on the masked getty@tty1 (06b) and SSH keys from
# rpi-imager customisation never reach /home/<user>/.ssh.
distro_dropin=/etc/cloud/cloud.cfg.d/99-airplanes-distro-debian.cfg
[[ -f $distro_dropin ]] || fail "$distro_dropin missing"
grep -qE '^[[:space:]]*distro:[[:space:]]+debian[[:space:]]*$' "$distro_dropin" \
    || fail "$distro_dropin does not select debian distro"

# Decoder, tar1090, and graphs1090 are produced by the runtime-overlay
# stage (02-install-runtime-overlay), which requires signed release
# downloads + verification. That stage is not run by this smoke; the full
# image build (build-image.yml) covers it end-to-end. Build-sentinel files
# for those components (.build-readsb-decoder-sha etc.) are likewise no
# longer host-side artifacts — runtime-manifest.json is the canonical
# source for those SHAs.

# lighttpd base config syntax check (catches broken alias.url snippets in the
# stages this smoke does run). The webconfig conf-available snippet ships
# through the runtime overlay at stage 02 (not exercised here), so the
# conf-enabled webconfig hop is NOT linked in this smoke; the full image build
# + boot-smoke cover the webconfig reverse-proxy path end to end.
lighttpd -tt -f /etc/lighttpd/lighttpd.conf >/dev/null \
    || fail "lighttpd config-test failed"

# Stage 05 outputs. Setup-only now — the webconfig binary, helpers, units,
# sudoers, and the lighttpd conf-available snippet arrive through the runtime
# overlay (stage 02) and are asserted by the runtime-overlay stage tests +
# the full build. Here we verify only the image-owned tmpfiles snippet stage
# 05 still installs host-side.
[[ -f /usr/lib/tmpfiles.d/airplanes-webconfig.conf ]] \
    || fail "tmpfiles.d snippet for /run/airplanes missing"
grep -Eq '^d /run/airplanes 0755 root root' /usr/lib/tmpfiles.d/airplanes-webconfig.conf \
    || fail "tmpfiles.d snippet wrong shape"

# apl-feed is now overlay-delivered via managed_paths (stage 02). This fast
# smoke does not run stage 02; the full image build + boot-smoke cover it.

# Stage 06 outputs.
[[ -x /usr/local/sbin/airplanes-first-run ]] || fail "airplanes-first-run entrypoint missing"
[[ -f /etc/systemd/system/airplanes-first-run.service ]] || fail "airplanes-first-run.service missing"
[[ -f /etc/systemd/system/airplanes-claim.service ]] || fail "airplanes-claim.service missing"
[[ -f /etc/systemd/system/airplanes-claim.timer ]] || fail "airplanes-claim.timer missing"
[[ -f /etc/systemd/system/airplanes-rfkill-unblock.service ]] \
    || fail "airplanes-rfkill-unblock.service missing"
[[ -f /boot/firmware/airplanes-config.txt ]] || fail "boot-config template missing"
[[ -L /etc/systemd/system/multi-user.target.wants/airplanes-first-run.service ]] \
    || fail "airplanes-first-run.service enable symlink missing"
[[ -L /etc/systemd/system/timers.target.wants/airplanes-claim.timer ]] \
    || fail "airplanes-claim.timer enable symlink missing"
[[ -L /etc/systemd/system/multi-user.target.wants/airplanes-rfkill-unblock.service ]] \
    || fail "airplanes-rfkill-unblock.service enable symlink missing"

# Hardening directives on the root-running stage-06 oneshots (airplanes-claim
# and airplanes-first-run). Both must run as root because /etc/airplanes/ is
# root-owned (deliberate — feed.env is shell-sourced as root by update.sh,
# so a daemon-writable /etc/airplanes/ would let a compromised daemon
# escalate). The systemd directives below shrink the blast radius of root
# in those units.
#
# Common set both share:
for unit in airplanes-claim.service airplanes-first-run.service; do
    path=/etc/systemd/system/$unit
    grep -q '^NoNewPrivileges=yes$' "$path" \
        || fail "$unit missing NoNewPrivileges=yes"
    grep -q '^ProtectHome=yes$' "$path" \
        || fail "$unit missing ProtectHome=yes"
    grep -q '^PrivateTmp=yes$' "$path" \
        || fail "$unit missing PrivateTmp=yes"
    grep -q '^ProtectKernelTunables=yes$' "$path" \
        || fail "$unit missing ProtectKernelTunables=yes"
    grep -q '^MemoryDenyWriteExecute=yes$' "$path" \
        || fail "$unit missing MemoryDenyWriteExecute=yes"
done

# Claim service is tightly sandboxed: ProtectSystem=strict + a single
# ReadWritePaths entry (only /etc/airplanes is mutated), CapabilityBoundingSet
# limited to the two caps write_secret_file actually needs (CAP_CHOWN to
# hand off to airplanes-feed, CAP_FOWNER to chmod after the chown), and
# SupplementaryGroups=airplanes-feed so the retry path can read a pending
# file already group-owned by airplanes-feed.
claim=/etc/systemd/system/airplanes-claim.service
grep -q '^ProtectSystem=strict$' "$claim" \
    || fail "airplanes-claim.service missing ProtectSystem=strict"
grep -q '^ReadWritePaths=/etc/airplanes$' "$claim" \
    || fail "airplanes-claim.service missing ReadWritePaths=/etc/airplanes"
grep -q '^CapabilityBoundingSet=CAP_CHOWN CAP_FOWNER$' "$claim" \
    || fail "airplanes-claim.service missing CapabilityBoundingSet=CAP_CHOWN CAP_FOWNER"
grep -q '^SupplementaryGroups=airplanes-feed$' "$claim" \
    || fail "airplanes-claim.service missing SupplementaryGroups=airplanes-feed"
grep -q '^RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX$' "$claim" \
    || fail "airplanes-claim.service missing RestrictAddressFamilies for HTTPS POST"

# First-run is sandboxed via ProtectSystem=true (NOT full — full would
# re-mount /etc read-only too, breaking the script's writes to /etc/hostname,
# /etc/airplanes/, /etc/NetworkManager/system-connections/, etc.). The two
# paths re-opened via ReadWritePaths cover /boot/firmware (for the
# airplanes-config.txt → airplanes-config.applied.txt rename and the
# airplanes-config.error.txt diagnostic) and /usr/local/share/airplanes
# (for the legacy airplanes-uuid symlink reinstalled by create-uuid.sh).
# RuntimeDirectory=airplanes creates /run/airplanes/ for the feed.env flock
# (path shared with webconfig's apply-config).
# Empty CapabilityBoundingSet (sethostname-fallback / raspi-config WiFi-
# country path silently fail, primary hostnamectl + wpa_supplicant.conf
# fallback paths don't need caps). PrivateNetwork=yes for defense in
# depth (RestrictAddressFamilies=AF_UNIX already excludes inet sockets).
firstrun=/etc/systemd/system/airplanes-first-run.service
grep -q '^ProtectSystem=true$' "$firstrun" \
    || fail "airplanes-first-run.service missing ProtectSystem=true"
grep -qE '^ReadWritePaths=.*/boot/firmware' "$firstrun" \
    || fail "airplanes-first-run.service missing /boot/firmware in ReadWritePaths"
grep -qE '^ReadWritePaths=.*/usr/local/share/airplanes' "$firstrun" \
    || fail "airplanes-first-run.service missing /usr/local/share/airplanes in ReadWritePaths"
grep -q '^RuntimeDirectory=airplanes$' "$firstrun" \
    || fail "airplanes-first-run.service missing RuntimeDirectory=airplanes"
grep -q '^RuntimeDirectoryPreserve=yes$' "$firstrun" \
    || fail "airplanes-first-run.service missing RuntimeDirectoryPreserve=yes"
grep -q '^CapabilityBoundingSet=$' "$firstrun" \
    || fail "airplanes-first-run.service missing empty CapabilityBoundingSet"
grep -q '^RestrictAddressFamilies=AF_UNIX$' "$firstrun" \
    || fail "airplanes-first-run.service missing RestrictAddressFamilies=AF_UNIX (dbus only)"
grep -q '^PrivateNetwork=yes$' "$firstrun" \
    || fail "airplanes-first-run.service missing PrivateNetwork=yes"

# rfkill-unblock unit semantics: must order before NetworkManager.service,
# must call `rfkill unblock wlan` (not `all`), and must clear NM.state.
grep -q '^Before=.*NetworkManager\.service' /etc/systemd/system/airplanes-rfkill-unblock.service \
    || fail "airplanes-rfkill-unblock.service missing Before=NetworkManager.service"
grep -q '^ExecStart=/usr/sbin/rfkill unblock wlan$' /etc/systemd/system/airplanes-rfkill-unblock.service \
    || fail "airplanes-rfkill-unblock.service missing ExecStart=/usr/sbin/rfkill unblock wlan"
grep -q '^ExecStart=/bin/rm -f /var/lib/NetworkManager/NetworkManager\.state$' \
    /etc/systemd/system/airplanes-rfkill-unblock.service \
    || fail "airplanes-rfkill-unblock.service missing ExecStart that wipes NetworkManager.state"

# Stage 06 must override stage2's WPA_COUNTRY-unset defaults: NM.state and
# any saved WLAN rfkill files written into the build chroot must be gone.
[[ ! -e /var/lib/NetworkManager/NetworkManager.state ]] \
    || fail "stage 06 did not delete NetworkManager.state seeded above"
if compgen -G '/var/lib/systemd/rfkill/*:wlan*' >/dev/null; then
    fail "stage 06 did not clear /var/lib/systemd/rfkill/*:wlan*"
fi

# release-channel pin: stage 06 writes the AIRPLANES_FEED_UPDATE_CHANNEL
# this image was built with (stable or dev) so feed/update.sh fetches
# runtime updates from the matching release stream. Distinct from
# AIRPLANES_FEED_BRANCH which only pins the build-time clone target.
[[ -f /etc/airplanes/release-channel ]] || fail "release-channel missing"
[[ "$(stat -c %a /etc/airplanes/release-channel)" == "644" ]] \
    || fail "release-channel mode != 0644"
release_channel_content="$(cat /etc/airplanes/release-channel)"
case "$release_channel_content" in
    stable|dev) ;;
    *) fail "release-channel content '$release_channel_content' not in {stable, dev}" ;;
esac
[[ "$release_channel_content" == "$AIRPLANES_FEED_UPDATE_CHANNEL" ]] \
    || fail "release-channel content '$release_channel_content' does not match AIRPLANES_FEED_UPDATE_CHANNEL='$AIRPLANES_FEED_UPDATE_CHANNEL'"

# Build-manifest sentinel written by stage 00.
[[ -s /etc/airplanes/.build-pi-gen-sha ]] || fail ".build-pi-gen-sha missing or empty"

echo "==> stage-airplanes/06a-run-tmpfs/00-run.sh"
( cd /image/stage-airplanes/06a-run-tmpfs && bash 00-run.sh )

echo "==> stage-airplanes/06a-run-tmpfs/01-run-chroot.sh"
( cd /image/stage-airplanes/06a-run-tmpfs && bash 01-run-chroot.sh )

echo "==> 06a post-install assertions"
[[ -x /usr/local/lib/airplanes/run-resize.sh ]] \
    || fail "run-resize.sh missing or not executable"
[[ "$(stat -c %a /usr/local/lib/airplanes/run-resize.sh)" == "755" ]] \
    || fail "run-resize.sh mode != 0755"
[[ -f /etc/systemd/system/airplanes-run-resize.service ]] \
    || fail "airplanes-run-resize.service missing"
[[ "$(stat -c %a /etc/systemd/system/airplanes-run-resize.service)" == "644" ]] \
    || fail "airplanes-run-resize.service mode != 0644"
grep -q '^WantedBy=local-fs.target$' /etc/systemd/system/airplanes-run-resize.service \
    || fail "airplanes-run-resize.service missing WantedBy=local-fs.target"
grep -qE '^After=.*systemd-remount-fs\.service' /etc/systemd/system/airplanes-run-resize.service \
    || fail "airplanes-run-resize.service missing After=systemd-remount-fs.service"
[[ -L /etc/systemd/system/local-fs.target.wants/airplanes-run-resize.service ]] \
    || fail "airplanes-run-resize.service enable symlink missing under local-fs.target.wants/"
# /run/collectd mount unit (replaces an fstab line; systemd .mount units
# auto-create the mountpoint directory, which avoids the chicken-and-egg
# of tmpfiles-setup running After=local-fs.target).
[[ -f /etc/systemd/system/run-collectd.mount ]] \
    || fail "run-collectd.mount missing"
[[ "$(stat -c %a /etc/systemd/system/run-collectd.mount)" == "644" ]] \
    || fail "run-collectd.mount mode != 0644"
grep -q '^Where=/run/collectd$' /etc/systemd/system/run-collectd.mount \
    || fail "run-collectd.mount missing Where=/run/collectd"
grep -q '^What=tmpfs$' /etc/systemd/system/run-collectd.mount \
    || fail "run-collectd.mount missing What=tmpfs"
grep -qE '^Options=.*size=64M' /etc/systemd/system/run-collectd.mount \
    || fail "run-collectd.mount missing size=64M in Options"
grep -qE '^Before=.*collectd\.service' /etc/systemd/system/run-collectd.mount \
    || fail "run-collectd.mount missing Before=collectd.service (would race with collectd start)"
[[ -L /etc/systemd/system/local-fs.target.wants/run-collectd.mount ]] \
    || fail "run-collectd.mount enable symlink missing under local-fs.target.wants/"
grep -qE '^tmpfs[[:space:]]+/run[[:space:]]+tmpfs[[:space:]]+.*size=128M' /etc/fstab \
    || fail "/etc/fstab missing /run tmpfs floor"
# Re-running 00-run.sh must be idempotent: the fstab marker line gates
# the append. A second pass should leave only one /run line.
( cd /image/stage-airplanes/06a-run-tmpfs && bash 00-run.sh ) >/dev/null
run_lines=$(grep -cE '^tmpfs[[:space:]]+/run[[:space:]]+tmpfs' /etc/fstab)
[[ "$run_lines" -eq 1 ]] \
    || fail "06a-run-tmpfs/00-run.sh appended duplicate /run line on second pass (got $run_lines lines)"

echo "==> stage-airplanes/06b-console-dashboard/00-run.sh"
( cd /image/stage-airplanes/06b-console-dashboard && bash 00-run.sh )

# Seed the Debian/Raspberry Pi OS default login-banner content that ships in
# the real target rootfs but NOT in this debian:trixie-slim base. Without
# this, the 01-run-chroot.sh cleanup assertions below would pass vacuously
# (deleting a file that was never there).
mkdir -p /etc/update-motd.d
printf 'Debian GNU/Linux placeholder license blurb.\n' > /etc/motd
for hook in 10-uname 00-header 10-help-text 50-motd-news; do
    cat > "/etc/update-motd.d/$hook" <<HOOK
#!/bin/sh
echo "SEEDED-MOTD-HOOK-$hook"
HOOK
    chmod 0755 "/etc/update-motd.d/$hook"
done

echo "==> stage-airplanes/06b-console-dashboard/01-run-chroot.sh"
( cd /image/stage-airplanes/06b-console-dashboard && bash 01-run-chroot.sh )

echo "==> 06b post-install assertions"
[[ -x /usr/local/lib/airplanes/render-status ]] || fail "render-status missing or not executable"
[[ "$(stat -c %a /usr/local/lib/airplanes/render-status)" == "755" ]] \
    || fail "render-status mode != 0755"
[[ -s /usr/local/share/airplanes/logo.txt ]] || fail "logo.txt missing or empty"
[[ "$(stat -c %a /usr/local/share/airplanes/logo.txt)" == "644" ]] \
    || fail "logo.txt mode != 0644"
[[ -s /usr/local/share/airplanes/banner.txt ]] || fail "banner.txt missing or empty"
[[ "$(stat -c %a /usr/local/share/airplanes/banner.txt)" == "644" ]] \
    || fail "banner.txt mode != 0644"
[[ -s /usr/local/share/airplanes/banner-narrow.txt ]] || fail "banner-narrow.txt missing or empty"
[[ "$(stat -c %a /usr/local/share/airplanes/banner-narrow.txt)" == "644" ]] \
    || fail "banner-narrow.txt mode != 0644"
[[ -f /etc/systemd/system/airplanes-dashboard.service ]] \
    || fail "airplanes-dashboard.service missing"
[[ -f /etc/systemd/system/getty@tty1.service.d/override.conf ]] \
    || fail "getty@tty1 override drop-in missing"
[[ -x /etc/update-motd.d/10-airplanes-status ]] \
    || fail "update-motd.d/10-airplanes-status missing or not executable"
[[ "$(stat -c %a /etc/update-motd.d/10-airplanes-status)" == "755" ]] \
    || fail "10-airplanes-status mode != 0755"

# Unit content sanity.
grep -q '^TTYPath=/dev/tty1' /etc/systemd/system/airplanes-dashboard.service \
    || fail "dashboard service missing TTYPath=/dev/tty1"
grep -q '^Conflicts=getty@tty1.service' /etc/systemd/system/airplanes-dashboard.service \
    || fail "dashboard service missing Conflicts=getty@tty1.service"
grep -q '^WantedBy=multi-user.target' /etc/systemd/system/airplanes-dashboard.service \
    || fail "dashboard service missing WantedBy=multi-user.target"
grep -Eq '^After=.*multi-user\.target' /etc/systemd/system/airplanes-dashboard.service \
    || fail "dashboard service missing After=multi-user.target"
grep -q '^StartLimitIntervalSec=' /etc/systemd/system/airplanes-dashboard.service \
    || fail "dashboard service missing StartLimitIntervalSec"
# Deferred-start machinery: sleep grace then best-effort kmsg-mute via setterm.
grep -q '^ExecStartPre=/usr/bin/sleep 6$' /etc/systemd/system/airplanes-dashboard.service \
    || fail "dashboard service missing ExecStartPre=/usr/bin/sleep 6"
grep -Eq '^ExecStartPre=-/usr/bin/setterm .*--clear all.*--msg off' \
    /etc/systemd/system/airplanes-dashboard.service \
    || fail "dashboard service missing ExecStartPre=-/usr/bin/setterm with --clear all and --msg off"
# Without TERM=linux, render-status' `tput cols` fails the terminfo lookup
# and the dispatcher falls back to the 80-col default even on wide HDMI.
grep -q '^Environment=TERM=linux$' /etc/systemd/system/airplanes-dashboard.service \
    || fail "dashboard service missing Environment=TERM=linux"
[[ -x /usr/bin/setterm ]] || fail "/usr/bin/setterm missing (util-linux base assumption)"

# Getty@tty1 must be masked (symlinked to /dev/null) and NOT in
# getty.target.wants/. Getty@tty2 must be in getty.target.wants/.
[[ -L /etc/systemd/system/getty@tty1.service ]] \
    || fail "getty@tty1.service not a symlink (mask failed)"
[[ "$(readlink /etc/systemd/system/getty@tty1.service)" == "/dev/null" ]] \
    || fail "getty@tty1.service not masked to /dev/null"
[[ ! -e /etc/systemd/system/getty.target.wants/getty@tty1.service ]] \
    || fail "stale getty@tty1.service wants symlink left behind"
[[ -L /etc/systemd/system/getty.target.wants/getty@tty2.service ]] \
    || fail "getty@tty2.service enable symlink missing"
# Dashboard's enable symlink moved from getty.target.wants/ to
# multi-user.target.wants/ when WantedBy= was retargeted.
[[ -L /etc/systemd/system/multi-user.target.wants/airplanes-dashboard.service ]] \
    || fail "airplanes-dashboard.service enable symlink missing under multi-user.target.wants/"
[[ ! -e /etc/systemd/system/getty.target.wants/airplanes-dashboard.service ]] \
    || fail "stale airplanes-dashboard.service symlink left under getty.target.wants/"

# Login-banner cleanup: /etc/motd is a regular empty file, default upstream
# update-motd.d hooks are gone, and the only executable file remaining is
# our 10-airplanes-status. The seeded payload sentinel must not appear.
[[ -f /etc/motd && ! -L /etc/motd ]] || fail "/etc/motd is missing or a symlink"
[[ "$(stat -c %s /etc/motd)" == "0" ]] || fail "/etc/motd is not empty"
[[ "$(stat -c %a /etc/motd)" == "644" ]] || fail "/etc/motd mode != 0644"
for hook in 10-uname 00-header 10-help-text 50-motd-news; do
    [[ ! -e "/etc/update-motd.d/$hook" ]] \
        || fail "seeded /etc/update-motd.d/$hook was not removed"
done
# Allowlist: nothing executable left under /etc/update-motd.d/ except ours.
# Catches future Raspberry Pi OS additions we missed by name.
unexpected="$(find /etc/update-motd.d -maxdepth 1 -type f -executable \
    ! -name 10-airplanes-status -printf '%f\n')"
[[ -z "$unexpected" ]] \
    || fail "unexpected executables under /etc/update-motd.d/: $unexpected"

# Renderer self-test: invoke --snapshot with every PATHS_* pointing at a
# missing file. Must exit 0, render every section, and never leak a
# 32+hex-char run (regression guard against accidentally reading the claim
# secret) or the literal path of the secret file.
SNAP_OUT="$(mktemp)"
PATHS_FEEDER_ID=/nx \
PATHS_RELEASE_CHANNEL=/nx \
PATHS_MANIFEST=/nx \
PATHS_CLAIM_SECRET=/nx \
PATHS_CLAIM_PENDING=/nx \
PATHS_CLAIM_VERSION=/nx \
PATHS_AIRCRAFT_JSON=/nx \
PATHS_THERMAL=/nx \
PATHS_LOGO=/usr/local/share/airplanes/logo.txt \
PATHS_ICON=/usr/local/share/airplanes/icon.txt \
TERM=dumb \
AIRPLANES_STATUS_TAGLINE_INDEX=0 \
    bash /usr/local/lib/airplanes/render-status --snapshot >"$SNAP_OUT" 2>&1 \
    || fail "render-status --snapshot exited non-zero with all sources missing"
# Banner header (icon + airplanes.live + tagline + version) replaces the
# old standalone "Build channel=…" line. Section list mirrors the labels
# emitted by build_status_lines_compact.
for needle in 'airplanes.live' 'Unfiltered flight data' 'feed sha=' \
              'Access' 'Feeder ID' 'Claim' 'Services' 'Feed' 'System'; do
    grep -q "$needle" "$SNAP_OUT" || fail "snapshot missing marker: $needle"
done
# Friendly service rows: one labelled line per display service.
for needle in 'Data upload (feed)' 'Aircraft triangulation (mlat)' \
              'ADS-B decoder (readsb)' 'UAT receiver (978)'; do
    grep -q "$needle" "$SNAP_OUT" || fail "snapshot missing service row: $needle"
done
# Dropped from the MOTD copy: claim-register action hint and Build line.
if grep -q 'sudo apl-feed claim register' "$SNAP_OUT"; then
    fail "snapshot must no longer print 'sudo apl-feed claim register' on the MOTD"
fi
if grep -E -q 'Build[[:space:]]+channel=' "$SNAP_OUT"; then
    fail "snapshot still emits the standalone 'Build channel=' line"
fi
# dump978-fa folds into the UAT row; raw producer must never appear.
if grep -q 'dump978-fa' "$SNAP_OUT"; then
    fail "snapshot renders dump978-fa as a standalone row (should fold into uat978)"
fi
# Icon artwork must land in the rootfs at the documented path.
[[ -s /usr/local/share/airplanes/icon.txt ]] \
    || fail "/usr/local/share/airplanes/icon.txt missing in installed rootfs"
grep -q '(not yet generated)' "$SNAP_OUT" \
    || fail "snapshot did not show '(not yet generated)' for missing feeder-id"
grep -q 'unclaimed' "$SNAP_OUT" \
    || fail "snapshot did not show 'unclaimed' for missing claim secret"
if grep -E -q '[0-9a-f]{32,}' "$SNAP_OUT"; then
    fail "snapshot leaked a 32+ hex-char run (possible secret read)"
fi
# Real claim secrets are 16 uppercase A-Z0-9 (apl-feed validate_secret),
# displayed by `claim show` as XXXX-XXXX-XXXX-XXXX. Defense-in-depth match
# on both shapes catches a regression that started reading the secret file.
if grep -E -q '[A-Z0-9]{16}' "$SNAP_OUT"; then
    fail "snapshot leaked a 16-uppercase-alnum run (claim secret format)"
fi
if grep -E -q '([A-Z0-9]{4}-){3}[A-Z0-9]{4}' "$SNAP_OUT"; then
    fail "snapshot leaked an XXXX-XXXX-XXXX-XXXX run (displayed secret form)"
fi
if grep -q 'feeder-claim-secret' "$SNAP_OUT"; then
    fail "snapshot leaked the literal string 'feeder-claim-secret'"
fi
rm -f "$SNAP_OUT"

echo "==> stage-airplanes/06d-cli-ergonomics/00-run.sh (apl-feed sudo wrapper)"
( cd /image/stage-airplanes/06d-cli-ergonomics && bash 00-run.sh )

echo "==> 06d post-install assertions"
[[ -x /usr/local/sbin/apl-feed ]] || fail "/usr/local/sbin/apl-feed missing or not executable"
[[ "$(stat -c %a /usr/local/sbin/apl-feed)" == "755" ]] \
    || fail "/usr/local/sbin/apl-feed mode != 0755"
head -1 /usr/local/sbin/apl-feed | grep -qE '^#!/bin/sh' \
    || fail "/usr/local/sbin/apl-feed shebang is not /bin/sh"
# The canonical /usr/local/bin/apl-feed is overlay-delivered (stage 02);
# this smoke does not run stage 02 so we only verify the sbin wrapper exists
# and is a distinct file (not a self-link). The full build + boot-smoke cover
# the wrapper-shadowing-binary assertion end to end.

# Stage 02-install-runtime-overlay is not exercised by this smoke; seed a
# synthetic runtime-manifest.json so 07-finalize's manifest-generator.sh
# has the runtime-component SHAs to fold into build-manifest.json. The
# canonical runtime-manifest is produced by the runtime-overlay stage at
# real-build time. SHAs below are placeholder 40-hex values.
install -d -m 755 /etc/airplanes
cat > /etc/airplanes/runtime-manifest.json <<'JSON'
{
    "version": "0.0.0-smoke",
    "channel": "dev",
    "components": {
        "feed_scripts":     "0000000000000000000000000000000000000000",
        "feed_readsb":      "0000000000000000000000000000000000000000",
        "readsb_wiedehopf": "0000000000000000000000000000000000000000",
        "dump978_fa":       "0000000000000000000000000000000000000000",
        "tar1090":          "0000000000000000000000000000000000000000",
        "tar1090_db":       "0000000000000000000000000000000000000000",
        "graphs1090":       "0000000000000000000000000000000000000000"
    }
}
JSON

echo "==> stage-airplanes/07-finalize/00-run.sh (stub-check + manifest + cleanup)"
( cd /image/stage-airplanes/07-finalize && bash 00-run.sh )

echo "==> post-finalize assertions"
[[ -s /etc/airplanes/build-manifest.json ]] || fail "build-manifest.json missing or empty"
jq -e '.schema_version == 1
    and .channel == "dev"
    and .arch == "arm64"
    and (.pi_gen | test("^([0-9a-f]{40}(-dirty)?|unknown)$"))
    and (.components | keys | length == 7)
    and (.components.airplanes_feed | test("^[0-9a-f]{40}$"))
    and (.components.airplanes_readsb | test("^[0-9a-f]{40}$"))
    and (.components.wiedehopf_readsb | test("^[0-9a-f]{40}$"))
    and (.components.wiedehopf_tar1090 | test("^[0-9a-f]{40}$"))
    and (.components.wiedehopf_tar1090_db | test("^[0-9a-f]{40}$"))
    and (.components.wiedehopf_graphs1090 | test("^[0-9a-f]{40}$"))
    and (.components.flightaware_dump978 | test("^[0-9a-f]{40}$"))
    and (.stub_fingerprint.invocations | type) == "number"
    and (.stub_fingerprint.enables | type) == "number"
    and (.stub_fingerprint.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
    /etc/airplanes/build-manifest.json > /dev/null \
    || { jq . /etc/airplanes/build-manifest.json >&2; fail "build-manifest.json contract"; }

# Build-only state must be gone.
[[ ! -e /usr/sbin/policy-rc.d ]] || fail "policy-rc.d still present after finalize"
[[ ! -e /usr/local/sbin/airplanes-systemctl-stub ]] || fail "systemctl-stub still present after finalize"
[[ ! -e /usr/local/sbin/systemctl ]] || fail "systemctl symlink still present after finalize"
[[ ! -e /usr/local/sbin/service ]] || fail "service symlink still present after finalize"
[[ ! -e /usr/local/sbin/deb-systemd-invoke ]] || fail "deb-systemd-invoke symlink still present after finalize"
[[ ! -e /var/log/airplanes-systemctl-stub.log ]] || fail "stub log still present after finalize"

echo "overlay smoke passed"
