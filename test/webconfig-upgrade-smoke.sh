#!/usr/bin/env bash
# Exercises the on-device webconfig upgrade contract at the filesystem level.
#
# Mirrors test/update-regression-smoke.sh in shape: a debian:trixie-slim
# container builds a real rootfs by running stage-00 + stage-01 + stage-05
# against the published config-stable webconfig release, then assembles a
# synthetic newer release from a local image-webconfig checkout and runs the
# installed install.sh --runtime to upgrade in place. Post-upgrade assertions
# cover binary swap, manifest update, .prev preservation, visudo + lighttpd
# parseability, and cross-version sudoers parity via airplanes-webconfig
# validate-sudoers. QEMU-level coverage (real /api/webconfig-update + helper
# + /health probe + rollback) lives in build-image.yml's webconfig-upgrade-qemu.
#
# External network: stage-01-install-feed clones feed/readsb. Same external
# integration cost as test/update-regression-smoke.sh.
#
# Usage: webconfig-upgrade-smoke.sh FEED_DIR WEBCONFIG_DIR
#   FEED_DIR        path to a local airplanes-live/feed checkout
#   WEBCONFIG_DIR   path to a local airplanes-live/image-webconfig checkout

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FEED_ARG="${1:?usage: webconfig-upgrade-smoke.sh FEED_DIR WEBCONFIG_DIR}"
WEBCONFIG_ARG="${2:?usage: webconfig-upgrade-smoke.sh FEED_DIR WEBCONFIG_DIR}"
[[ -d "$FEED_ARG" ]] || { echo "feed dir not found: $FEED_ARG" >&2; exit 1; }
[[ -d "$WEBCONFIG_ARG" ]] || { echo "webconfig dir not found: $WEBCONFIG_ARG" >&2; exit 1; }

# Canonicalize so docker doesn't treat a relative path as a named volume.
FEED_DIR="$(cd -- "$FEED_ARG" && pwd)"
WEBCONFIG_DIR="$(cd -- "$WEBCONFIG_ARG" && pwd)"

[[ -f "$REPO_ROOT/scripts/systemctl-stub" ]] || { echo "missing systemctl-stub" >&2; exit 1; }
[[ -f "$WEBCONFIG_DIR/scripts/lib/build-release.sh" ]] || {
    echo "WEBCONFIG_DIR has no scripts/lib/build-release.sh (build it from a checkout that carries the release packager)" >&2
    exit 1
}
command -v docker >/dev/null || { echo "docker required" >&2; exit 1; }

HOST_ARTIFACT_DIR="${HOST_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/webconfig-upgrade}"
mkdir -p "$HOST_ARTIFACT_DIR"

echo "==> webconfig-upgrade smoke: image=$REPO_ROOT feed=$FEED_DIR webconfig=$WEBCONFIG_DIR artifacts=$HOST_ARTIFACT_DIR"
docker run --rm \
    --volume "$REPO_ROOT:/image:ro" \
    --volume "$FEED_DIR:/feed:ro" \
    --volume "$WEBCONFIG_DIR:/webconfig:ro" \
    --volume "$HOST_ARTIFACT_DIR:/artifacts" \
    --env "AIRPLANES_FEED_BRANCH=${AIRPLANES_FEED_BRANCH:-dev}" \
    --env "ARTIFACT_DIR=/artifacts" \
    debian:trixie-slim \
    bash -e -o pipefail /image/test/webconfig-upgrade-inner.sh
