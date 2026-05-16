#!/usr/bin/env bash
# Inner half of webconfig-upgrade-smoke.sh; runs inside debian:trixie-slim
# (arm64 host). See test/webconfig-upgrade-smoke.sh for context and scope.
#
# Sequence:
#   1. Run stage-airplanes overlays 00-prep, 01-install-feed, 05-install-webconfig
#      against the config-stable webconfig branch — stage 05 downloads the
#      real published release and lays it down. This is the baseline.
#   2. Build a synthetic newer release ("v9.9.99") from the mounted webconfig
#      checkout using scripts/lib/build-release.sh.
#   3. Stage the synthetic release at file:// plus a bare git repo carrying
#      v9.9.99 as the highest stable-semver tag.
#   4. Invoke /usr/local/share/airplanes-webconfig/install.sh --runtime (the
#      installer-of-record on the device, installed by step 1) against the
#      file:// release.
#   5. Assert binary swapped, .prev preserved, manifest updated, sudoers files
#      replaced, visudo + lighttpd still parse, airplanes-webconfig
#      validate-sudoers passes against the new binary + new sudoers files.

set -euo pipefail

# shellcheck source=lib/overlay-common.sh
. /image/test/lib/overlay-common.sh

ARTIFACT_DIR="${ARTIFACT_DIR:-/artifacts}"
mkdir -p "$ARTIFACT_DIR"

# overlay-common.sh already sourced config-dev. Source config-stable now so
# stage 05 picks up the real published v0.1.1 release. Re-apply the
# file:///feed override that overlay-common.sh set (config-stable resets
# AIRPLANES_FEED_REPO to the github URL otherwise).
set -a
# shellcheck source=/dev/null
. /image/config-stable
set +a
export AIRPLANES_FEED_REPO="file:///feed"
echo "==> baseline pins: feed=$AIRPLANES_FEED_BRANCH webconfig=$AIRPLANES_WEBCONFIG_BRANCH"

apt-get install -y --no-install-recommends sudo lighttpd jq

echo "==> stage-airplanes/00-prep/00-run.sh"
( cd /image/stage-airplanes/00-prep && bash 00-run.sh )

echo "==> stage-airplanes/01-install-feed/00-run.sh (clone feed)"
( cd /image/stage-airplanes/01-install-feed && bash 00-run.sh )
echo "==> stage-airplanes/01-install-feed/01-run-chroot.sh"
( cd /image/stage-airplanes/01-install-feed && bash 01-run-chroot.sh )
echo "==> stage-airplanes/01-install-feed/02-run.sh"
( cd /image/stage-airplanes/01-install-feed && bash 02-run.sh )

echo "==> stage-airplanes/05-install-webconfig/00-run.sh (real v0.1.1 release)"
( cd /image/stage-airplanes/05-install-webconfig && bash 00-run.sh )
echo "==> stage-airplanes/05-install-webconfig/01-run-chroot.sh"
( cd /image/stage-airplanes/05-install-webconfig && bash 01-run-chroot.sh )
echo "==> stage-airplanes/05-install-webconfig/02-run.sh"
( cd /image/stage-airplanes/05-install-webconfig && bash 02-run.sh )

# --- baseline state captured ------------------------------------------------
BASELINE_BIN_SHA="$(sha256sum /usr/local/bin/airplanes-webconfig | awk '{print $1}')"
BASELINE_MANIFEST_VERSION="$(jq -r .version /etc/airplanes/webconfig-release.json)"
echo "==> baseline: binary sha256=$BASELINE_BIN_SHA manifest.version=$BASELINE_MANIFEST_VERSION"

# --- build synthetic v9.9.99 release ----------------------------------------
# overlay-common.sh already installed golang-go for the production cross-build
# in stage 05; build-release.sh reuses it for the synthetic v9.9.99 binary.

STAGED=/var/staged-webconfig-release
RELEASE_DIR="$STAGED/v9.9.99"
REMOTE="$STAGED/image-webconfig.git"
rm -rf "$STAGED"
install -d -m 0755 "$STAGED"

# Copy the webconfig source into a writable scratch since the host bind is
# read-only; build-release.sh writes outputs to a separate --output dir
# and does not mutate the source, but go build can populate a module cache.
SRC=/tmp/webconfig-src
rm -rf "$SRC"
cp -a /webconfig "$SRC"

echo "==> building v9.9.99 release"
bash "$SRC/scripts/lib/build-release.sh" \
    --version v9.9.99 \
    --kind stable \
    --source "$SRC" \
    --output "$RELEASE_DIR" \
    --arch arm64 \
    --build-date 2024-01-01T00:00:00Z

# Bare git repo carrying only v9.9.99 as the highest semver tag.
echo "==> staging file:// remote with v9.9.99 tag"
git init -q --bare "$REMOTE"
SEED=/tmp/webconfig-seed
rm -rf "$SEED"
git init -q "$SEED"
(
    cd "$SEED" || exit 1
    git config user.email t@example.com
    git config user.name test
    git commit --allow-empty -q -m "test seed"
    git tag v9.9.99
    git remote add origin "$REMOTE"
    git push -q origin --tags
)

# --- upgrade ----------------------------------------------------------------
echo "==> running install.sh --runtime against v9.9.99"
echo stable > /etc/airplanes/release-channel
AIRPLANES_WEBCONFIG_REPO="file://$REMOTE" \
AIRPLANES_WEBCONFIG_DOWNLOAD_BASE="file://$STAGED" \
    bash /usr/local/share/airplanes-webconfig/install.sh --runtime \
    > "$ARTIFACT_DIR/install.log" 2>&1 \
    || { echo "FAIL: install.sh --runtime exited non-zero" >&2; tail -n 80 "$ARTIFACT_DIR/install.log" >&2; exit 1; }

# --- post-upgrade assertions ------------------------------------------------
echo "==> post-upgrade assertions"

POST_BIN_SHA="$(sha256sum /usr/local/bin/airplanes-webconfig | awk '{print $1}')"
POST_MANIFEST_VERSION="$(jq -r .version /etc/airplanes/webconfig-release.json)"

[[ "$POST_BIN_SHA" != "$BASELINE_BIN_SHA" ]] || {
    echo "FAIL: binary sha256 unchanged after upgrade" >&2
    exit 1
}
[[ "$POST_MANIFEST_VERSION" == "v9.9.99" ]] || {
    echo "FAIL: manifest reports $POST_MANIFEST_VERSION, expected v9.9.99" >&2
    exit 1
}

# .prev preserves the v0.1.1 binary.
[[ -f /usr/local/bin/airplanes-webconfig.prev ]] || {
    echo "FAIL: .prev missing after upgrade" >&2
    exit 1
}
PREV_SHA="$(sha256sum /usr/local/bin/airplanes-webconfig.prev | awk '{print $1}')"
[[ "$PREV_SHA" == "$BASELINE_BIN_SHA" ]] || {
    echo "FAIL: .prev sha256=$PREV_SHA does not match baseline $BASELINE_BIN_SHA" >&2
    exit 1
}

# Sudoers files still parse.
visudo -cf /etc/sudoers.d/010_airplanes-webconfig >/dev/null \
    || { echo "FAIL: visudo rejected 010" >&2; exit 1; }
visudo -cf /etc/sudoers.d/011_airplanes-webconfig-update >/dev/null \
    || { echo "FAIL: visudo rejected 011" >&2; exit 1; }

# Cross-version sudoers parity: the newly-installed binary's argv shapes
# must all be authorized by the newly-installed sudoers files. This is the
# runtime check that catches the upgrade-with-stale-sudoers lockout case.
/usr/local/bin/airplanes-webconfig --validate-sudoers \
    || { echo "FAIL: validate-sudoers" >&2; exit 1; }

# Sudoers from the rootfs tarball replaced the baked-in v0.1.1 versions.
SYNTH_SUDOERS="$(mktemp -d)"
tar -C "$SYNTH_SUDOERS" -xzf "$RELEASE_DIR/rootfs.tar.gz" \
    ./etc/sudoers.d/010_airplanes-webconfig \
    ./etc/sudoers.d/011_airplanes-webconfig-update
diff -q \
    "$SYNTH_SUDOERS/etc/sudoers.d/010_airplanes-webconfig" \
    /etc/sudoers.d/010_airplanes-webconfig >/dev/null \
    || { echo "FAIL: 010_airplanes-webconfig content drift from synthetic release" >&2; exit 1; }
diff -q \
    "$SYNTH_SUDOERS/etc/sudoers.d/011_airplanes-webconfig-update" \
    /etc/sudoers.d/011_airplanes-webconfig-update >/dev/null \
    || { echo "FAIL: 011_airplanes-webconfig-update content drift from synthetic release" >&2; exit 1; }

# airplanes-webconfig user/group still exists with the original uid/gid.
getent passwd airplanes-webconfig >/dev/null \
    || { echo "FAIL: airplanes-webconfig user vanished" >&2; exit 1; }
getent group airplanes-webconfig >/dev/null \
    || { echo "FAIL: airplanes-webconfig group vanished" >&2; exit 1; }

# Lighttpd's webconfig snippet still references valid module bits.
lighttpd -tt -f /etc/lighttpd/lighttpd.conf >/dev/null \
    || { echo "FAIL: lighttpd config no longer parses" >&2; exit 1; }

echo "webconfig-upgrade smoke passed (baseline=$BASELINE_MANIFEST_VERSION → upgraded=$POST_MANIFEST_VERSION)"
