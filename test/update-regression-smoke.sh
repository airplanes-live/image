#!/usr/bin/env bash
# Detects drift in webconfig-owned artifacts caused by feed/update.sh runs.
# Builds a webconfig-flavored rootfs in a debian:trixie-slim container,
# fingerprints the artifacts, runs feed/update.sh in runtime mode, then
# fails on any drift.
#
# External network dependencies: stage 01 clones readsb (via
# AIRPLANES_READSB_REPO), and the runtime update path may rebuild
# mlat-client from PyPI. Same accepted external integration coverage as
# overlay-smoke.
#
# Usage: update-regression-smoke.sh FEED_DIR
#   FEED_DIR — path to a local feed/ checkout

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FEED_ARG="${1:?usage: update-regression-smoke.sh FEED_DIR}"
[[ -d "$FEED_ARG" ]] || { echo "feed dir not found: $FEED_ARG" >&2; exit 1; }
# Canonicalize so docker doesn't treat a relative path as a named volume.
FEED_DIR="$(cd -- "$FEED_ARG" && pwd)"
[[ -f "$REPO_ROOT/scripts/systemctl-stub" ]] || { echo "missing systemctl-stub" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker required" >&2; exit 1; }

# Artifact dir on the host so CI's upload-artifact can read it; defaults to
# a per-run mktemp when not in CI.
HOST_ARTIFACT_DIR="${HOST_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/update-regression}"
mkdir -p "$HOST_ARTIFACT_DIR"

echo "==> update-regression smoke: image=$REPO_ROOT feed=$FEED_DIR artifacts=$HOST_ARTIFACT_DIR"
docker run --rm \
    --volume "$REPO_ROOT:/image:ro" \
    --volume "$FEED_DIR:/feed:ro" \
    --volume "$HOST_ARTIFACT_DIR:/artifacts" \
    --env AIRPLANES_FEED_BRANCH="${AIRPLANES_FEED_BRANCH:-dev}" \
    --env "AIRPLANES_WEBCONFIG_REPO=${AIRPLANES_WEBCONFIG_REPO:-}" \
    --env "AIRPLANES_WEBCONFIG_BRANCH=${AIRPLANES_WEBCONFIG_BRANCH:-}" \
    --env ARTIFACT_DIR=/artifacts \
    debian:trixie-slim \
    bash -e -o pipefail /image/test/update-regression-inner.sh
