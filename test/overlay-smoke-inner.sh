#!/usr/bin/env bash
# Inner half of overlay-smoke.sh; runs inside debian:trixie-slim. See
# test/overlay-smoke.sh for context and scope.

set -euo pipefail

# Pi-gen helpers expected by stage scripts: on_chroot wraps a heredoc to run
# inside the chroot. We're already inside the rootfs (the container), so
# just execute the heredoc body in the current shell.
on_chroot() { bash; }
export -f on_chroot

# Stage scripts read ROOTFS_DIR / BASE_DIR from pi-gen. Map to container root.
export ROOTFS_DIR=/
export BASE_DIR=/image

# Source config-dev so all decoder + feed repo/branch env vars are in scope —
# avoids drifting between the smoke and what production builds actually use.
# (shellcheck can't follow runtime-container path; values come from configured envs.)
set -a
# shellcheck disable=SC1091
. /image/config-dev
set +a
# Override AIRPLANES_FEED_REPO to the bind-mounted local checkout. Other repos
# (readsb decoder, dump978) are fetched from GitHub during the smoke, same as
# the real build — that's what we're trying to validate.
export AIRPLANES_FEED_REPO="file:///feed"

# Stage 07 invokes manifest-generator.sh which requires ARCH. The smoke runs
# in a debian:trixie-slim container regardless of host arch — pick arm64 to
# match config-dev's primary target. CHANNEL=dev comes from the config-dev
# source above.
export ARCH=arm64

echo "==> apt update + stage-00-prep packages"
apt-get update -qq
# Install only what stage-00-prep declares; install.sh fetches its own
# bootstrap deps inside the chroot via airplanes_install_update_deps.
mapfile -t stage00_packages < <(grep -v '^#' /image/stage-airplanes/00-prep/01-packages)
apt-get install -y --no-install-recommends "${stage00_packages[@]}"
# systemd provides /bin/systemctl. The stub passes 'enable' through to it;
# without /bin/systemctl, enables silently no-op and leave no symlink under
# target.wants/, so post-install assertions can't tell whether enable worked.
apt-get install -y --no-install-recommends systemd

# git refuses to operate on bind-mounted feed checkout owned by a different
# uid (runner host vs. root in container); mirror feed/test/installer-smoke's
# fix. Has to run after git is installed.
git config --system --add safe.directory '*'

echo "==> stage-airplanes/00-prep/00-run.sh"
# Run from the stage dir so relative `files/` paths inside 00-run.sh resolve.
( cd /image/stage-airplanes/00-prep && bash 00-run.sh )

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

echo "==> stage-airplanes/06-firstboot/00-run.sh"
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

# Service files contain expected directives
grep -q 'ExecStart=/usr/local/share/airplanes/airplanes-feed.sh' /etc/systemd/system/airplanes-feed.service \
    || fail "airplanes-feed.service missing ExecStart=…/airplanes-feed.sh"
grep -q 'After=airplanes-first-run.service' /etc/systemd/system/airplanes-feed.service \
    || fail "airplanes-feed.service missing After=airplanes-first-run.service"
grep -q 'ExecStart=/usr/local/share/airplanes/airplanes-mlat.sh' /etc/systemd/system/airplanes-mlat.service \
    || fail "airplanes-mlat.service missing ExecStart=…/airplanes-mlat.sh"
grep -q 'After=airplanes-first-run.service' /etc/systemd/system/airplanes-mlat.service \
    || fail "airplanes-mlat.service missing After=airplanes-first-run.service"
grep -q 'feed2.airplanes.live,64004' /usr/local/share/airplanes/airplanes-feed.sh \
    || fail "airplanes-feed.sh missing feed2 connector"

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
# readsb enabled; 978 services explicitly NOT enabled (first-run flips them on
# DUMP978=yes, not at image-build time).
have_enable_link readsb.service || fail "readsb.service enable symlink missing"
have_enable_link dump978-fa.service \
    && fail "dump978-fa.service unexpectedly enabled at build time"
have_enable_link airplanes-978.service \
    && fail "airplanes-978.service unexpectedly enabled at build time"

# Stage 02 fuller-features wiring (consumed by tar1090 heatmap/coverage).
grep -q -- '--write-json-globe-index' /usr/local/share/airplanes/readsb.sh \
    || fail "readsb.sh missing --write-json-globe-index"
grep -q -- '--globe-history-dir' /usr/local/share/airplanes/readsb.sh \
    || fail "readsb.sh missing --globe-history-dir"
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

# Stage 06 outputs.
[[ -x /usr/local/sbin/airplanes-first-run ]] || fail "airplanes-first-run entrypoint missing"
[[ -f /etc/systemd/system/airplanes-first-run.service ]] || fail "airplanes-first-run.service missing"
[[ -f /etc/systemd/system/airplanes-claim.service ]] || fail "airplanes-claim.service missing"
[[ -f /etc/systemd/system/airplanes-claim.timer ]] || fail "airplanes-claim.timer missing"
[[ -f /boot/firmware/airplanes-config.txt ]] || fail "boot-config template missing"
[[ -L /etc/systemd/system/multi-user.target.wants/airplanes-first-run.service ]] \
    || fail "airplanes-first-run.service enable symlink missing"
[[ -L /etc/systemd/system/timers.target.wants/airplanes-claim.timer ]] \
    || fail "airplanes-claim.timer enable symlink missing"

# Build-manifest sentinels written by stages 00 + 01 (rest are checked above).
[[ -s /etc/airplanes/.build-pi-gen-sha ]] || fail ".build-pi-gen-sha missing or empty"
[[ -s /etc/airplanes/.build-airplanes-readsb-sha ]] || fail ".build-airplanes-readsb-sha missing or empty"

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
