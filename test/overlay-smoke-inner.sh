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

# Channel config exports these in production. Mirror for the smoke.
export AIRPLANES_FEED_REPO="file:///feed"
export AIRPLANES_FEED_BRANCH="${AIRPLANES_FEED_BRANCH:-dev}"

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

echo "==> stage-airplanes/06-firstboot/00-run.sh"
# pi-gen runs on_chroot via its own helper; we stub that at the top of this
# script. The stage's `install` commands take relative `files/` paths.
( cd /image/stage-airplanes/06-firstboot && bash 00-run.sh )

echo "==> check-stub-log.sh"
bash /image/scripts/check-stub-log.sh /

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

echo "overlay smoke passed"
