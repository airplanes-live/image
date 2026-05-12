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

echo "==> stage-airplanes/01-install-feed/00-run.sh (clone feed)"
( cd /image/stage-airplanes/01-install-feed && bash 00-run.sh )

echo "==> stage-airplanes/01-install-feed/01-run-chroot.sh (install.sh --build-mode)"
( cd /image/stage-airplanes/01-install-feed && bash 01-run-chroot.sh )

echo "==> stage-airplanes/01-install-feed/02-run.sh (cleanup staged feed)"
( cd /image/stage-airplanes/01-install-feed && bash 02-run.sh )

echo "==> stage-airplanes/02-install-decoder/00-run.sh (clone readsb + dump978)"
( cd /image/stage-airplanes/02-install-decoder && bash 00-run.sh )

echo "==> stage-airplanes/02-install-decoder/01-run-chroot.sh (compile + install)"
( cd /image/stage-airplanes/02-install-decoder && bash 01-run-chroot.sh )

echo "==> stage-airplanes/02-install-decoder/02-run.sh (cleanup build dirs)"
( cd /image/stage-airplanes/02-install-decoder && bash 02-run.sh )

echo "==> stage-airplanes/03-install-tar1090/00-run.sh (clone tar1090 + tar1090-db)"
( cd /image/stage-airplanes/03-install-tar1090 && bash 00-run.sh )

echo "==> stage-airplanes/03-install-tar1090/01-run-chroot.sh (run tar1090 install)"
( cd /image/stage-airplanes/03-install-tar1090 && bash 01-run-chroot.sh )

echo "==> stage-airplanes/03-install-tar1090/02-run.sh (cleanup tar1090 build dir)"
( cd /image/stage-airplanes/03-install-tar1090 && bash 02-run.sh )

echo "==> stage-airplanes/04-install-graphs1090/00-run.sh (clone graphs1090)"
( cd /image/stage-airplanes/04-install-graphs1090 && bash 00-run.sh )

echo "==> stage-airplanes/04-install-graphs1090/01-run-chroot.sh (run graphs1090 install + 978 wiring)"
( cd /image/stage-airplanes/04-install-graphs1090 && bash 01-run-chroot.sh )

echo "==> stage-airplanes/04-install-graphs1090/02-run.sh (cleanup graphs1090 git dir)"
( cd /image/stage-airplanes/04-install-graphs1090 && bash 02-run.sh )

echo "==> stage-airplanes/05-install-webconfig/00-run.sh (cross-build webconfig)"
( cd /image/stage-airplanes/05-install-webconfig && bash 00-run.sh )

echo "==> stage-airplanes/05-install-webconfig/01-run-chroot.sh (user + lighttpd + enable)"
( cd /image/stage-airplanes/05-install-webconfig && bash 01-run-chroot.sh )

echo "==> stage-airplanes/05-install-webconfig/02-run.sh (no-op)"
( cd /image/stage-airplanes/05-install-webconfig && bash 02-run.sh )

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
[[ -f /etc/airplanes/feed.env ]] || fail "feed.env missing"
[[ -f /etc/airplanes/image-install ]] || fail "image-install marker missing"
[[ -x /usr/local/share/airplanes/feed-airplanes ]] || fail "feed-airplanes binary missing"
[[ -x /usr/local/bin/apl-feed ]] || fail "apl-feed missing"
[[ -f /etc/systemd/system/airplanes-feed.service ]] || fail "airplanes-feed.service missing"
[[ -f /etc/systemd/system/airplanes-mlat.service ]] || fail "airplanes-mlat.service missing"
[[ ! -f /etc/airplanes/feeder-id ]] || fail "feeder-id should NOT exist in build mode"
[[ ! -f /etc/airplanes/feeder-claim-secret ]] || fail "feeder-claim-secret should NOT exist in build mode"
[[ ! -e /usr/local/share/airplanes/airplanes-uuid ]] || fail "airplanes-uuid symlink should NOT exist (new contract)"
[[ -s /etc/airplanes/.build-feed-sha ]] || fail ".build-feed-sha missing or empty"
[[ ! -d /usr/local/src/airplanes-feed-build ]] || fail "/usr/local/src/airplanes-feed-build was not cleaned up"

# Fresh-image MLAT posture: off by default until the operator opts in via the
# webconfig after entering real coordinates. GEO_CONFIGURED follows from the
# lat=0/lon=0 placeholders via feed's derive_geo_configured.
# Use -x (full-line match) + alternation so a busted half-quoted value
# (MLAT_ENABLED="false or MLAT_ENABLED=false") fails this assertion.
grep -qxE 'MLAT_ENABLED=("false"|false)' /etc/airplanes/feed.env \
    || fail "feed.env: expected MLAT_ENABLED=false on fresh image"
grep -qxE 'GEO_CONFIGURED=("false"|false)' /etc/airplanes/feed.env \
    || fail "feed.env: expected GEO_CONFIGURED=false on fresh image"

# Service files contain expected directives
grep -q 'ExecStart=/usr/local/share/airplanes/airplanes-feed.sh' /etc/systemd/system/airplanes-feed.service \
    || fail "airplanes-feed.service missing ExecStart=…/airplanes-feed.sh"
grep -qE '^After=.*airplanes-first-run.service' /etc/systemd/system/airplanes-feed.service \
    || fail "airplanes-feed.service missing After=airplanes-first-run.service"
grep -q 'ExecStart=/usr/local/share/airplanes/airplanes-mlat.sh' /etc/systemd/system/airplanes-mlat.service \
    || fail "airplanes-mlat.service missing ExecStart=…/airplanes-mlat.sh"
grep -qE '^After=.*airplanes-first-run.service' /etc/systemd/system/airplanes-mlat.service \
    || fail "airplanes-mlat.service missing After=airplanes-first-run.service"
grep -q 'feed2.airplanes.live,64004' /usr/local/share/airplanes/airplanes-feed.sh \
    || fail "airplanes-feed.sh missing feed2 connector"

# Daemon runtime state-file dependencies (PR 1+2 in feed; consumed by
# render-status, apl-feed status, and the webconfig server).
# RuntimeDirectoryPreserve=yes is required so the misconfig state file
# survives the daemon's failed terminal state (RestartPreventExitStatus=64).
grep -qE '^RuntimeDirectoryPreserve=yes$' /etc/systemd/system/airplanes-feed.service \
    || fail "airplanes-feed.service missing RuntimeDirectoryPreserve=yes (consumers can't read state across restart cycles)"
grep -qE '^RuntimeDirectoryPreserve=yes$' /etc/systemd/system/airplanes-mlat.service \
    || fail "airplanes-mlat.service missing RuntimeDirectoryPreserve=yes (misconfig state would vanish across exit-64 fail)"
grep -qE '^RuntimeDirectory=airplanes-feed$' /etc/systemd/system/airplanes-feed.service \
    || fail "airplanes-feed.service missing RuntimeDirectory=airplanes-feed"
grep -qE '^RuntimeDirectory=airplanes-mlat$' /etc/systemd/system/airplanes-mlat.service \
    || fail "airplanes-mlat.service missing RuntimeDirectory=airplanes-mlat"

# Daemon-time runtime libs installed by feed's update.sh. render-status
# and apl-feed status source state-reader.sh; the daemons source state-writer.sh.
[[ -f /usr/local/share/airplanes/lib/state-writer.sh ]] \
    || fail "state-writer.sh missing at /usr/local/share/airplanes/lib/ (daemons can't publish state)"
[[ -f /usr/local/share/airplanes/lib/state-reader.sh ]] \
    || fail "state-reader.sh missing at /usr/local/share/airplanes/lib/ (consumers can't read state)"
[[ -r /usr/local/share/airplanes/lib/state-reader.sh ]] \
    || fail "state-reader.sh not readable (mode 0644 expected)"

# enable links exist (proves systemctl enable was effective via the stub).
# Image services use [Install] WantedBy=default.target, mlat-client venv
# install also enables a unit; either default.target.wants or
# multi-user.target.wants is acceptable.
have_enable_link() {
    local unit="$1"
    [[ -L "/etc/systemd/system/default.target.wants/$unit" \
        || -L "/etc/systemd/system/multi-user.target.wants/$unit" ]]
}
have_enable_link airplanes-feed.service || fail "airplanes-feed enable symlink missing"
have_enable_link airplanes-mlat.service || fail "airplanes-mlat enable symlink missing"

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

# Stage 02 outputs (decoder + 978).
[[ -x /usr/bin/readsb ]] || fail "readsb binary missing"
[[ -x /usr/bin/viewadsb ]] || fail "viewadsb binary missing"
[[ -x /usr/bin/airplanes-978 ]] || fail "airplanes-978 binary missing"
[[ -x /usr/bin/dump978-fa ]] || fail "dump978-fa binary missing"
# airplanes-978 is a hardlink of readsb (same inode).
[[ "$(stat -c %i /usr/bin/readsb)" == "$(stat -c %i /usr/bin/airplanes-978)" ]] \
    || fail "airplanes-978 is not a hardlink of readsb"
# No unresolved boost/soapy/usb libs at build time.
if ldd /usr/bin/dump978-fa | grep -q 'not found'; then
    ldd /usr/bin/dump978-fa | grep 'not found' >&2
    fail "dump978-fa has unresolved shared libraries"
fi
[[ -x /usr/local/share/airplanes/readsb.sh ]] || fail "readsb.sh wrapper missing"
[[ -x /usr/local/share/airplanes/airplanes-978.sh ]] || fail "airplanes-978.sh wrapper missing"
[[ -x /usr/local/share/airplanes/dump978-fa.sh ]] || fail "dump978-fa.sh wrapper missing"
[[ -f /etc/systemd/system/readsb.service ]] || fail "readsb.service missing"
[[ -f /etc/systemd/system/dump978-fa.service ]] || fail "dump978-fa.service missing"
[[ -f /etc/systemd/system/airplanes-978.service ]] || fail "airplanes-978.service missing"
[[ -s /etc/airplanes/.build-readsb-decoder-sha ]] || fail ".build-readsb-decoder-sha missing or empty"
[[ -s /etc/airplanes/.build-dump978-sha ]] || fail ".build-dump978-sha missing or empty"
[[ ! -d /usr/local/src/airplanes-readsb-build ]] || fail "readsb build dir not cleaned up"
[[ ! -d /usr/local/src/airplanes-dump978-build ]] || fail "dump978 build dir not cleaned up"
# readsb + 978 units are all enabled at install. The 978 wrappers self-disable
# via exit 64 when UAT_INPUT is empty/invalid (parallel to airplanes-mlat).
# UAT_INPUT lands in feed.env via webconfig — the boot config no longer
# touches operational keys.
have_enable_link readsb.service || fail "readsb.service enable symlink missing"
have_enable_link dump978-fa.service \
    || fail "dump978-fa.service should be enabled at install (PR 4: self-disables via exit 64)"
have_enable_link airplanes-978.service \
    || fail "airplanes-978.service should be enabled at install (PR 4: self-disables via exit 64)"

# 978 unit-file directives required for the self-disable pattern: exit 64
# without RestartPreventExitStatus=64 would loop the unit, and on
# airplanes-978 the state file must survive the failed terminal state.
grep -qE '^RestartPreventExitStatus=64$' /etc/systemd/system/dump978-fa.service \
    || fail "dump978-fa.service missing RestartPreventExitStatus=64 (would restart-loop on UAT_INPUT empty)"
grep -qE '^RestartPreventExitStatus=64$' /etc/systemd/system/airplanes-978.service \
    || fail "airplanes-978.service missing RestartPreventExitStatus=64"
grep -qE '^RuntimeDirectoryPreserve=yes$' /etc/systemd/system/airplanes-978.service \
    || fail "airplanes-978.service missing RuntimeDirectoryPreserve=yes (state file would vanish across exit-64)"

# Stage 02 fuller-features wiring (consumed by tar1090 heatmap/coverage).
grep -q -- '--write-json-globe-index' /usr/local/share/airplanes/readsb.sh \
    || fail "readsb.sh missing --write-json-globe-index"
grep -q -- '--write-globe-history' /usr/local/share/airplanes/readsb.sh \
    || fail "readsb.sh missing --write-globe-history"
# Regression guard: --aircraft-update-interval is a flightaware/dump1090-fa
# flag, not a wiedehopf/readsb flag. We pass --write-json-every instead.
# Crashlooped readsb in a real-Pi flash test before this guard existed.
grep -q -- '--write-json-every ' /usr/local/share/airplanes/readsb.sh \
    || fail "readsb.sh missing --write-json-every"
! grep -q -- '--aircraft-update-interval' /usr/local/share/airplanes/readsb.sh \
    || fail "readsb.sh has --aircraft-update-interval (unsupported by wiedehopf/readsb)"
[[ -d /var/globe_history ]] || fail "/var/globe_history not created"
[[ "$(stat -c %U /var/globe_history)" == "readsb" ]] || fail "/var/globe_history not owned by readsb"

# Stage 03 outputs (tar1090).
[[ -d /usr/local/share/tar1090 ]] || fail "tar1090 install dir missing"
[[ -f /usr/local/share/tar1090/html/index.html ]] || fail "tar1090 html/index.html missing"
[[ -f /lib/systemd/system/tar1090.service ]] || fail "tar1090.service missing"
[[ -f /etc/default/tar1090 ]] || fail "/etc/default/tar1090 missing"
grep -q '^ENABLE_978=yes' /etc/default/tar1090 \
    || fail "/etc/default/tar1090 ENABLE_978 not patched to yes"
[[ -L /etc/lighttpd/conf-enabled/89-airplanes-978.conf ]] \
    || fail "89-airplanes-978.conf not enabled"
[[ ! -L /etc/lighttpd/conf-enabled/95-tar1090-otherport.conf ]] \
    || fail "tar1090 otherport listener should be removed"
[[ -s /etc/airplanes/.build-tar1090-sha ]] || fail ".build-tar1090-sha missing or empty"
[[ -s /etc/airplanes/.build-tar1090-db-sha ]] || fail ".build-tar1090-db-sha missing or empty"
# Pinning held: tar1090-db's actual HEAD matches the SHA we captured at fetch.
[[ "$(git -C /usr/local/share/tar1090/git-db rev-parse HEAD)" \
    == "$(cat /etc/airplanes/.build-tar1090-db-sha)" ]] \
    || fail "tar1090-db SHA pinning was clobbered by upstream installer"
[[ ! -d /usr/local/src/airplanes-tar1090-build ]] || fail "tar1090 build dir not cleaned up"
have_enable_link tar1090.service || fail "tar1090.service enable symlink missing"

# Stage 04 outputs (graphs1090).
[[ -d /usr/share/graphs1090 ]] || fail "graphs1090 install dir missing"
[[ -f /lib/systemd/system/graphs1090.service ]] || fail "graphs1090.service missing"
[[ -f /etc/collectd/collectd.conf ]] || fail "collectd.conf missing"
grep -E -q '^URL_978 "file:///usr/share/graphs1090/978-symlink"' /etc/collectd/collectd.conf \
    || fail "collectd.conf URL_978 not patched"
[[ -L /usr/share/graphs1090/978-symlink/data ]] || fail "978-symlink/data missing"
[[ "$(readlink /usr/share/graphs1090/978-symlink/data)" == "/run/airplanes-978" ]] \
    || fail "978-symlink/data points at wrong target"
[[ -L /etc/lighttpd/conf-enabled/88-graphs1090.conf ]] \
    || fail "graphs1090 lighttpd snippet not enabled"
[[ ! -L /etc/lighttpd/conf-enabled/95-graphs1090-otherport.conf ]] \
    || fail "graphs1090 otherport listener should be removed"
[[ -s /etc/airplanes/.build-graphs1090-sha ]] || fail ".build-graphs1090-sha missing or empty"
[[ ! -d /usr/share/graphs1090/git ]] || fail "graphs1090 git dir not cleaned up"
have_enable_link graphs1090.service || fail "graphs1090.service enable symlink missing"
have_enable_link collectd.service || fail "collectd.service enable symlink missing"
# Interface lines normalized to canonical Pi names; no build-host leakage.
grep -q 'Interface "eth0"' /etc/collectd/collectd.conf || fail "collectd missing Interface eth0"
grep -q 'Interface "end0"' /etc/collectd/collectd.conf || fail "collectd missing Interface end0"
grep -q 'Interface "wlan0"' /etc/collectd/collectd.conf || fail "collectd missing Interface wlan0"
# Build-host interfaces (commonly eno*, ens*, enX*, wlxXX*) must not leak.
if grep -E -q 'Interface "(eno|ens|wlx|enx)[^"]*"' /etc/collectd/collectd.conf; then
    grep -E 'Interface "(eno|ens|wlx|enx)[^"]*"' /etc/collectd/collectd.conf >&2
    fail "build-host network interface name leaked into collectd.conf"
fi

# lighttpd config syntax check (catches broken alias.url snippets etc.)
lighttpd -tt -f /etc/lighttpd/lighttpd.conf >/dev/null \
    || fail "lighttpd config-test failed"

# Stage 05 outputs (webconfig plumbing).
[[ -x /usr/local/bin/airplanes-webconfig ]] || fail "airplanes-webconfig binary missing"
# Cross-build target matches ARCH (arm64); the smoke runs on amd64 so it must
# NOT be a host-arch binary.
file /usr/local/bin/airplanes-webconfig | grep -q 'ARM aarch64' \
    || fail "airplanes-webconfig is not an arm64 binary"
[[ -f /etc/systemd/system/airplanes-webconfig.service ]] || fail "airplanes-webconfig.service missing"
grep -q '^User=airplanes-webconfig' /etc/systemd/system/airplanes-webconfig.service \
    || fail "airplanes-webconfig.service not running as airplanes-webconfig user"
grep -q '^After=.*airplanes-first-run.service' /etc/systemd/system/airplanes-webconfig.service \
    || fail "airplanes-webconfig.service missing After=airplanes-first-run.service"
[[ -f /etc/lighttpd/conf-available/40-airplanes-webconfig.conf ]] \
    || fail "lighttpd conf-available/40-airplanes-webconfig.conf missing"
[[ -L /etc/lighttpd/conf-enabled/40-airplanes-webconfig.conf ]] \
    || fail "lighttpd conf-enabled/40-airplanes-webconfig.conf symlink missing"
# mod_proxy enabled by lighttpd-enable-mod (debian helper writes a
# 10-proxy.conf symlink into conf-enabled).
[[ -e /etc/lighttpd/conf-enabled/10-proxy.conf ]] \
    || fail "lighttpd mod_proxy not enabled (no 10-proxy.conf in conf-enabled)"
have_enable_link airplanes-webconfig.service || fail "airplanes-webconfig.service enable symlink missing"

# Reset oneshot: unit installed, script executable, WantedBy symlink under
# airplanes-webconfig.service.wants/ exists.
[[ -f /etc/systemd/system/airplanes-webconfig-reset.service ]] \
    || fail "airplanes-webconfig-reset.service missing"
[[ -x /usr/local/lib/airplanes-webconfig/reset ]] \
    || fail "/usr/local/lib/airplanes-webconfig/reset missing or not executable"
[[ -L /etc/systemd/system/airplanes-webconfig.service.wants/airplanes-webconfig-reset.service ]] \
    || fail "reset wants symlink missing under airplanes-webconfig.service.wants/"

# Sudoers (PR-3): file exists, mode 0440, owned root:root, visudo accepts.
[[ -f /etc/sudoers.d/010_airplanes-webconfig ]] \
    || fail "sudoers snippet missing"
[[ "$(stat -c %a /etc/sudoers.d/010_airplanes-webconfig)" == "440" ]] \
    || fail "sudoers snippet perms != 0440"
[[ "$(stat -c %U:%G /etc/sudoers.d/010_airplanes-webconfig)" == "root:root" ]] \
    || fail "sudoers snippet not owned root:root"
visudo -cf /etc/sudoers.d/010_airplanes-webconfig >/dev/null \
    || fail "visudo rejects sudoers snippet"

# airplanes-webconfig in systemd-journal group (so /api/log/{unit} can read
# the journal without sudo).
id -nG airplanes-webconfig | tr ' ' '\n' | grep -qx systemd-journal \
    || fail "airplanes-webconfig not in systemd-journal group"

# apl-feed apply (the canonical feed.env writer) is shipped by
# stage-airplanes/01-install-feed and lives at /usr/local/bin/apl-feed.
[[ -x /usr/local/bin/apl-feed ]] \
    || fail "apl-feed binary missing or not executable"

# tmpfiles.d snippet for /run/airplanes (the feed-env lock dir).
[[ -f /usr/lib/tmpfiles.d/airplanes-webconfig.conf ]] \
    || fail "tmpfiles.d snippet for /run/airplanes missing"
grep -Eq '^d /run/airplanes 0755 root root' /usr/lib/tmpfiles.d/airplanes-webconfig.conf \
    || fail "tmpfiles.d snippet wrong shape"

# Sudoers expected set: apl-feed apply --json + reboot + systemd-run.
# The per-unit restart entries are gone — apl-feed apply owns the restart
# fan-out now (one writer pinned by sudoers; service restarts run as root
# inside that helper, not as a separate sudo grant).
for entry in \
    '/usr/local/bin/apl-feed apply --json' \
    'systemctl reboot' \
    'systemd-run --unit=airplanes-update'
do
    grep -F -q "$entry" /etc/sudoers.d/010_airplanes-webconfig \
        || fail "sudoers missing entry: $entry"
done

# PR-3 retired every per-unit restart entry from the sudoers policy.
# Any leftover line is dead authorization (still a valid sudo
# escalation surface).
for stale in \
    'systemctl restart airplanes-feed.service' \
    'systemctl restart airplanes-mlat.service' \
    'systemctl restart dump978-fa.service' \
    'systemctl restart airplanes-978.service' \
    'apply-config'
do
    if grep -F -q "$stale" /etc/sudoers.d/010_airplanes-webconfig; then
        fail "sudoers still contains retired entry: $stale"
    fi
done

# claim-show MUST NOT be in sudoers — webconfig reads the secret directly
# via group permissions. A leftover entry would be dead config and an
# unnecessary privilege surface.
if grep -qF 'apl-feed claim show' /etc/sudoers.d/010_airplanes-webconfig; then
    fail "sudoers still contains 'apl-feed claim show' — should be dropped after the group-read pivot"
fi

# webconfig.service ReadWritePaths must reach /etc/airplanes so the sudo
# child (running as root) is allowed to write feed.env through the helper.
grep -E -q '^ReadWritePaths=.*/etc/airplanes( |$)' /etc/systemd/system/airplanes-webconfig.service \
    || fail "airplanes-webconfig.service ReadWritePaths missing /etc/airplanes"
grep -E -q '^ReadWritePaths=.*/run/airplanes( |$)' /etc/systemd/system/airplanes-webconfig.service \
    || fail "airplanes-webconfig.service ReadWritePaths missing /run/airplanes"

# airplanes-webconfig user exists with matching primary group.
getent passwd airplanes-webconfig >/dev/null \
    || fail "airplanes-webconfig user missing"
getent group airplanes-webconfig >/dev/null \
    || fail "airplanes-webconfig group missing"
[[ -d /var/lib/airplanes-webconfig ]] || fail "/var/lib/airplanes-webconfig missing"
[[ "$(stat -c %a /var/lib/airplanes-webconfig)" == "700" ]] \
    || fail "/var/lib/airplanes-webconfig perms != 0700"
[[ "$(stat -c %U /var/lib/airplanes-webconfig)" == "airplanes-webconfig" ]] \
    || fail "/var/lib/airplanes-webconfig owner != airplanes-webconfig"
[[ -d /etc/airplanes/webconfig ]] || fail "/etc/airplanes/webconfig missing"
[[ "$(stat -c %a /etc/airplanes/webconfig)" == "700" ]] \
    || fail "/etc/airplanes/webconfig perms != 0700"
[[ "$(stat -c %U /etc/airplanes/webconfig)" == "airplanes-webconfig" ]] \
    || fail "/etc/airplanes/webconfig owner != airplanes-webconfig"

# airplanes-webconfig must be a member of the airplanes-feed group so the
# reveal handler can read /etc/airplanes/feeder-claim-secret directly.
id -nG airplanes-webconfig | tr ' ' '\n' | grep -qx airplanes-feed \
    || fail "airplanes-webconfig not in airplanes-feed group"

# webconfig.service must declare the supplementary group explicitly so the
# runtime contract is self-documenting (and survives an /etc/group rewrite
# between unit-load and process-start).
grep -q '^SupplementaryGroups=airplanes-feed$' /etc/systemd/system/airplanes-webconfig.service \
    || fail "airplanes-webconfig.service missing SupplementaryGroups=airplanes-feed"

# End-to-end: drop a fake claim secret as airplanes-feed:airplanes-feed
# mode 0640, then read it as airplanes-webconfig via group permissions.
# Catches regressions in either side (file ownership/mode, group
# membership) at PR time.
install -d -m 0755 /etc/airplanes
printf '%s\n' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' > /etc/airplanes/feeder-id
chmod 0644 /etc/airplanes/feeder-id
printf '%s\n' 'ABCD1234EFGH5678' > /etc/airplanes/feeder-claim-secret
chmod 0640 /etc/airplanes/feeder-claim-secret
chown airplanes-feed:airplanes-feed /etc/airplanes/feeder-claim-secret
read_out=$(runuser -u airplanes-webconfig -- cat /etc/airplanes/feeder-claim-secret 2>&1) \
    || fail "airplanes-webconfig cannot read claim secret: $read_out"
[[ "$read_out" == "ABCD1234EFGH5678" ]] \
    || fail "claim secret read returned wrong content: $read_out"
rm -f /etc/airplanes/feeder-id /etc/airplanes/feeder-claim-secret

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

# Build-manifest sentinels written by stages 00 + 01 (rest are checked above).
[[ -s /etc/airplanes/.build-pi-gen-sha ]] || fail ".build-pi-gen-sha missing or empty"
[[ -s /etc/airplanes/.build-airplanes-readsb-sha ]] || fail ".build-airplanes-readsb-sha missing or empty"

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
PATHS_FEED_ENV=/nx \
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
