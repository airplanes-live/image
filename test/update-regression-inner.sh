#!/usr/bin/env bash
# Inner half of update-regression-smoke.sh; runs inside debian:trixie-slim.
# See test/update-regression-smoke.sh for context and scope.
#
# Builds a webconfig-flavored rootfs by running stage-airplanes overlays
# 00-prep, 01-install-feed, 05-install-webconfig, 06-firstboot, then
# fingerprints every webconfig-owned artifact, runs feed/update.sh in
# runtime mode (no --build-mode flag), refingerprints, and fails if there
# is any drift in the webconfig surface.
#
# Stages 02-04 (decoder, tar1090, graphs1090) are skipped — feed/update.sh
# does not interact with their artifacts, and skipping them saves ~5 min.
# `lighttpd -tt` and `visudo -cf` post-update validate parse-correctness for
# the stage-05-owned config either side might still touch.
#
# Stage 07 (cleanup) is skipped because update.sh expects the systemctl-stub
# to remain in place; the stub is overlaid here with a regression-aware shim
# that returns is-active=0 for airplanes-feed/mlat so update.sh's runtime
# checks short-circuit.

set -euo pipefail

# shellcheck source=lib/overlay-common.sh
. /image/test/lib/overlay-common.sh

# Artifact dir is bind-mounted from the host's $RUNNER_TEMP/update-regression
# so upload-artifact can read fingerprints and the update log on failure.
ARTIFACT_DIR="${ARTIFACT_DIR:-/artifacts}"
mkdir -p "$ARTIFACT_DIR"

# Stage 05 needs visudo from the sudo package; the regression-aware shim
# below also wants jq for diagnostics. Both are usually pulled in by stage
# 00-prep but install explicitly so this script stands alone.
apt-get install -y --no-install-recommends sudo lighttpd

echo "==> stage-airplanes/00-prep/00-run.sh"
( cd /image/stage-airplanes/00-prep && bash 00-run.sh )

echo "==> stage-airplanes/01-install-feed/00-run.sh (clone feed)"
( cd /image/stage-airplanes/01-install-feed && bash 00-run.sh )

echo "==> stage-airplanes/01-install-feed/01-run-chroot.sh (install.sh --build-mode)"
( cd /image/stage-airplanes/01-install-feed && bash 01-run-chroot.sh )

echo "==> stage-airplanes/01-install-feed/02-run.sh (cleanup staged feed)"
( cd /image/stage-airplanes/01-install-feed && bash 02-run.sh )

echo "==> stage-airplanes/05-install-webconfig/00-run.sh (cross-build webconfig)"
( cd /image/stage-airplanes/05-install-webconfig && bash 00-run.sh )

echo "==> stage-airplanes/05-install-webconfig/01-run-chroot.sh (user + lighttpd + enable)"
( cd /image/stage-airplanes/05-install-webconfig && bash 01-run-chroot.sh )

echo "==> stage-airplanes/05-install-webconfig/02-run.sh (no-op)"
( cd /image/stage-airplanes/05-install-webconfig && bash 02-run.sh )

echo "==> stage-airplanes/06-firstboot/00-run.sh"
( cd /image/stage-airplanes/06-firstboot && bash 00-run.sh )

# ---- Seed sentinel content under webconfig-owned dirs --------------------
# Catches `rm -rf $dir/*` regressions that leave dirs intact but wipe
# contents — directory mode/owner alone wouldn't drift in that case.
echo "==> seeding webconfig-owned sentinels"
printf 'regression-sentinel\n' > /var/lib/airplanes-webconfig/.update-regression-sentinel
printf 'regression-sentinel\n' > /etc/airplanes/webconfig/.update-regression-sentinel
chown airplanes-webconfig:airplanes-webconfig \
    /var/lib/airplanes-webconfig/.update-regression-sentinel \
    /etc/airplanes/webconfig/.update-regression-sentinel
chmod 0600 \
    /var/lib/airplanes-webconfig/.update-regression-sentinel \
    /etc/airplanes/webconfig/.update-regression-sentinel

# ---- Force the self-replace path of update.sh to fire --------------------
# Stage 01 leaves $GIT/update.sh and /usr/local/share/airplanes/update.sh
# byte-identical, so update.sh's diff check at the top of main() would skip
# the self-replace path. Overwriting the installed copy with a stub forces
# the diff to differ; the runtime run will then exercise the install + mv -fT
# self-replace and we fingerprint mode/sha post-update.
echo "==> seeding stale installed updater"
printf '#!/bin/bash\necho "stale stub" >&2\nexit 0\n' \
    > /usr/local/share/airplanes/update.sh
chmod 0755 /usr/local/share/airplanes/update.sh

# ---- Capture pre-update fingerprint --------------------------------------
echo "==> capturing pre-update fingerprint"
# shellcheck source=lib/webconfig-fingerprint.sh
. /image/test/lib/webconfig-fingerprint.sh
webconfig_fingerprint > "$ARTIFACT_DIR/pre.txt"

# ---- Install regression-aware systemctl shim -----------------------------
# update.sh in runtime mode (no --build-mode) hits `systemctl is-active
# airplanes-feed` after restart and exits 1 on failure. The default stub
# returns 1 for is-active so the update.sh "service couldn't be started"
# branch fires. Override only that case here; everything else delegates to
# the existing airplanes-systemctl-stub. The stub is at
# /usr/local/sbin/airplanes-systemctl-stub; the symlink at
# /usr/local/sbin/systemctl currently points there.
SYSTEMCTL_LINK=/usr/local/sbin/systemctl
SYSTEMCTL_LINK_TARGET=$(readlink "$SYSTEMCTL_LINK")
SYSTEMCTL_REGRESSION_SHIM=/usr/local/sbin/systemctl-regression-shim
cat > "$SYSTEMCTL_REGRESSION_SHIM" <<'SHIM'
#!/usr/bin/env bash
# Regression-test wrapper: returns is-active=0 for the feed/mlat units that
# update.sh checks at the end of its runtime path. Everything else passes
# through to the existing build-time stub.
args=("$@")
if [[ "${args[0]:-}" == "is-active" ]]; then
    # is-active accepts an optional --quiet (and other flags); skip them
    # to find the unit name.
    unit=""
    for ((i=1; i<${#args[@]}; i++)); do
        case "${args[i]}" in
            --*) continue ;;
            *) unit="${args[i]}"; break ;;
        esac
    done
    case "$unit" in
        airplanes-feed|airplanes-feed.service|airplanes-mlat|airplanes-mlat.service)
            echo active
            exit 0
            ;;
    esac
fi
exec /usr/local/sbin/airplanes-systemctl-stub "$@"
SHIM
chmod 0755 "$SYSTEMCTL_REGRESSION_SHIM"
ln -sfn "$SYSTEMCTL_REGRESSION_SHIM" "$SYSTEMCTL_LINK"

# ---- Run runtime-mode update.sh ------------------------------------------
# - APL_FEED_BIN=/bin/true makes claim-registration.sh's
#   `$feed_bin claim register --max-retry-time N` invocation a no-op
#   (returns 0, ignores args). Avoids needing live cloud connectivity.
# - AIRPLANES_FEED_REPO is already file:///feed via the common prelude.
# - No --build-mode flag — this exercises the same path real feeders run
#   when webconfig kicks `systemd-run /usr/local/share/airplanes/update.sh`.
echo "==> running runtime-mode update.sh"
set +e
APL_FEED_BIN=/bin/true \
    /usr/local/share/airplanes/update.sh \
    > "$ARTIFACT_DIR/update.log" 2>&1
update_rc=$?
set -e

# Restore the original symlink before fingerprinting so the post-fingerprint
# of /usr/local/sbin/systemctl matches pre.
ln -sfn "$SYSTEMCTL_LINK_TARGET" "$SYSTEMCTL_LINK"
rm -f "$SYSTEMCTL_REGRESSION_SHIM"

if [[ "$update_rc" -ne 0 ]]; then
    echo "FAIL: update.sh exited $update_rc; see $ARTIFACT_DIR/update.log" >&2
    tail -n 80 "$ARTIFACT_DIR/update.log" >&2
    exit 1
fi

# ---- Capture post-update fingerprint -------------------------------------
echo "==> capturing post-update fingerprint"
webconfig_fingerprint > "$ARTIFACT_DIR/post.txt"

# ---- Diff -----------------------------------------------------------------
echo "==> diffing pre vs post fingerprint"
if ! diff -u "$ARTIFACT_DIR/pre.txt" "$ARTIFACT_DIR/post.txt" \
        > "$ARTIFACT_DIR/fingerprint.diff"; then
    echo "FAIL: webconfig artifact drift detected" >&2
    cat "$ARTIFACT_DIR/fingerprint.diff" >&2
    exit 1
fi

# ---- Defense-in-depth post-update validations ----------------------------
echo "==> visudo -cf /etc/sudoers"
visudo -cf /etc/sudoers >/dev/null

echo "==> lighttpd -tt"
lighttpd -tt -f /etc/lighttpd/lighttpd.conf >/dev/null

echo "update-regression smoke passed"
