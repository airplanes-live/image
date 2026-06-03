#!/usr/bin/env bash
# augment-dev-version.sh — fold a fingerprint of the bundled payload into an
# auto-generated dev version string.
#
# The auto dev version (resolve-channel-and-tags.sh) is keyed only on the image
# repo commit + date: `X.Y.Z-dev-<YYYYMMDD>-<image-sha7>`. That ignores the
# bundled component pins (webconfig, feed, readsb, mlat-client, dump978, tar1090,
# …), which track moving dev tags/branches. A component-only change on the same
# day therefore reproduces an identical version, and the on-device same-version
# replay guard refuses to install it. Appending a fingerprint of the bundled
# payload makes the version change whenever the payload changes.
#
# The fingerprint is the first 16 hex chars of a sha256 over the normalized
# component commits plus the mlat venv hash. Appending it to a 7-hex image-sha
# suffix yields a 23-hex suffix, still inside the device/schema regex bound of
# `[0-9a-f]{7,40}` — so no regex/schema/device change and the stable path is
# untouched.
#
# Pure function: reads <staging>/components.json and <staging>/compat.json,
# prints the (possibly augmented) version to stdout. Only an exact auto-dev-form
# base version is augmented; stable `X.Y.Z` and explicit/longer-suffix dev
# overrides pass through unchanged.
#
# Args:
#   --base-version <v>     the resolved version to (maybe) augment
#   --staging <dir>        directory holding components.json + compat.json

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: augment-dev-version.sh \
    --base-version <version> \
    --staging <staging-dir>
USAGE
}

die() {
    echo "augment-dev-version: $*" >&2
    exit 1
}

BASE_VERSION=""
STAGING=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-version) BASE_VERSION="${2-}"; shift 2 ;;
        --staging)      STAGING="${2-}";      shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage; die "unknown argument: $1" ;;
    esac
done

[[ -n "$BASE_VERSION" ]] || { usage; die "missing --base-version"; }
[[ -n "$STAGING" ]]      || { usage; die "missing --staging"; }
[[ -d "$STAGING" ]]      || die "--staging not a directory: $STAGING"

# Only the exact auto dev form gets a fingerprint. The suffix is precisely a
# 7-hex image sha — anything longer is an explicit override that already encodes
# its own identity, and a bare `X.Y.Z` is stable. Mangling either would break
# the stable contract or double-fingerprint an override.
if ! [[ "$BASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-dev-[0-9]{8}-[0-9a-f]{7}$ ]]; then
    printf '%s\n' "$BASE_VERSION"
    exit 0
fi

components="$STAGING/components.json"
[[ -f "$components" ]] || die "components.json not found in staging: $components"

# Normalize component values to their commit sha only. aggregate-components-json.sh
# emits either a bare sha string or a {commit_sha, version} object (when a
# component carries a version tag). Hash the commit only so a moving tag pointing
# at the same commit does not churn the fingerprint. `jq -S` sorts keys so map
# ordering can't perturb the hash.
norm="$(jq -S -c \
    'with_entries(.value |= if type == "object" then .commit_sha else . end)' \
    "$components")"

# Fold in the mlat venv content hash. build-runtime-assets.sh writes
# compat.mlat_venv_sha256 from stage-feed's rebuilt venv; a same-commit venv
# rebuild changes those bytes without changing any component commit, so
# components.json alone would miss it.
venv_hash=""
compat="$STAGING/compat.json"
if [[ -f "$compat" ]]; then
    venv_hash="$(jq -r '.mlat_venv_sha256 // ""' "$compat")"
fi

fp="$(printf '%s\n%s\n' "$norm" "$venv_hash" | sha256sum | cut -c1-16)"

printf '%s%s\n' "$BASE_VERSION" "$fp"
