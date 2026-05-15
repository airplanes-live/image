#!/usr/bin/env bash
# Fast PR-time smoke for the stage-airplanes overlay. Runs stages 00-prep,
# 01-install-feed, 02-install-decoder, and 06-firstboot inside a
# debian:trixie-slim container at native amd64 speed, skipping pi-gen stages
# 0/1/2 and qemu emulation. Catches stage-airplanes script regressions and
# feed/install.sh interactions in ~5-15 min instead of the full build's
# ~75 min.
#
# External network dependencies: install.sh clones readsb (via
# AIRPLANES_READSB_REPO), mlat-client, and may fetch from PyPI to build the
# mlat venv. Stage 02 also clones wiedehopf/readsb and flightaware/dump978.
# These are accepted as external integration coverage; flakes here would need
# fixturing those repos.
#
# Usage: overlay-smoke.sh FEED_DIR
#   FEED_DIR — path to a local feed/ checkout

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FEED_ARG="${1:?usage: overlay-smoke.sh FEED_DIR}"
[[ -d "$FEED_ARG" ]] || { echo "feed dir not found: $FEED_ARG" >&2; exit 1; }
# Canonicalize so docker doesn't treat a relative path as a named volume.
FEED_DIR="$(cd -- "$FEED_ARG" && pwd)"
[[ -f "$REPO_ROOT/scripts/systemctl-stub" ]] || { echo "missing systemctl-stub" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker required" >&2; exit 1; }

echo "==> overlay smoke: image=$REPO_ROOT feed=$FEED_DIR"
docker run --rm \
    --volume "$REPO_ROOT:/image:ro" \
    --volume "$FEED_DIR:/feed:ro" \
    --env AIRPLANES_FEED_BRANCH=dev \
    --env "AIRPLANES_WEBCONFIG_REPO=${AIRPLANES_WEBCONFIG_REPO:-}" \
    --env "AIRPLANES_WEBCONFIG_BRANCH=${AIRPLANES_WEBCONFIG_BRANCH:-}" \
    debian:trixie-slim \
    bash -e -o pipefail /image/test/overlay-smoke-inner.sh
