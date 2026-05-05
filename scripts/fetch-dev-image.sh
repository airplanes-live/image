#!/bin/bash
# Pull the latest dev-channel image artifact from CI and decompress it into
# deploy/. Pins to current origin/dev HEAD and errors if no successful
# build-image run matches that commit. Avoids rebuilding locally when the
# native-arm64 runner has already produced an image faster than a dev box can.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

REPO=airplanes-live/image
BRANCH=dev
WORKFLOW=build-image.yml
ARTIFACT=image-dev-arm64

for cmd in gh jq xz git python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "missing required tool: $cmd" >&2
        exit 1
    fi
done

# Explicit refspec so refs/remotes/origin/$BRANCH is updated; a bare
# `git fetch origin $BRANCH` can leave only FETCH_HEAD updated and
# rev-parse origin/$BRANCH would read a stale ref.
git fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
TARGET_SHA="$(git rev-parse "origin/$BRANCH")"
echo "==> origin/$BRANCH at $TARGET_SHA"

# Push events only: cleanup-dev-artifacts only prunes push-to-dev artifacts,
# so workflow_dispatch artifacts could outlive their commit and mismatch.
# jq's `first(...)` avoids SIGPIPE from `head -n1` aborting under `set -e`.
RUN_ID="$(gh run list -R "$REPO" -w "$WORKFLOW" -b "$BRANCH" -e push --status success -L 20 \
    --json databaseId,headSha \
    | jq -r --arg sha "$TARGET_SHA" 'first(.[] | select(.headSha == $sha) | .databaseId) // empty')"

if [[ -z "$RUN_ID" ]]; then
    echo "no successful $WORKFLOW push run on $BRANCH at $TARGET_SHA" >&2
    echo "(CI may still be running; latest runs on $BRANCH:)" >&2
    gh run list -R "$REPO" -w "$WORKFLOW" -b "$BRANCH" -L 5 >&2
    exit 1
fi

echo "==> matched run $RUN_ID"

mkdir -p deploy
STAGE_DIR="$(mktemp -d -p deploy .fetch-image-XXXXXX)"
trap 'rm -rf -- "$STAGE_DIR"' EXIT INT TERM

echo "==> downloading $ARTIFACT into $STAGE_DIR"
if ! gh run download -R "$REPO" -n "$ARTIFACT" -D "$STAGE_DIR" "$RUN_ID"; then
    # Disambiguate: did dev advance during download, or was the artifact pruned?
    git fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
    NOW_SHA="$(git rev-parse "origin/$BRANCH")"
    if [[ "$NOW_SHA" != "$TARGET_SHA" ]]; then
        echo "$BRANCH advanced ($TARGET_SHA -> $NOW_SHA) during download — re-run" >&2
    else
        echo "artifact for $BRANCH at $TARGET_SHA may have been pruned" >&2
    fi
    exit 1
fi

shopt -s nullglob
xz_files=("$STAGE_DIR"/*.img.xz)
shopt -u nullglob
if (( ${#xz_files[@]} != 1 )); then
    echo "expected exactly 1 .img.xz in artifact, got ${#xz_files[@]}" >&2
    exit 1
fi

XZ_FILE="${xz_files[0]}"
XZ_BASE="$(basename -- "$XZ_FILE")"
echo "==> decompressing $XZ_BASE (keeping .xz for manifest)"
# -dk: decompress, keep the .xz alongside. We need both: the .img is what users
# flash directly with `dd` / Etcher, the .img.xz is what the rpi-imager Custom
# Repository manifest references via file:// (rpi-imager re-extracts on flash
# and validates against extract_sha256).
xz -dk -- "$XZ_FILE"

IMG_FILE="${XZ_FILE%.xz}"
IMG_BASE="$(basename -- "$IMG_FILE")"
if [[ ! -f "$IMG_FILE" ]]; then
    echo "decompression did not produce expected .img: $IMG_FILE" >&2
    exit 1
fi

# Move the .xz first: it's the smaller of the two and the manifest depends on
# it. If the larger .img move fails (no space, etc.), the .xz stays in deploy/
# so the user can either retry or re-decompress without re-downloading 800 MB.
mv -f -- "$XZ_FILE" "deploy/$XZ_BASE"
mv -f -- "$IMG_FILE" "deploy/$IMG_BASE"
echo "OK: deploy/$IMG_BASE"
ls -lh "deploy/$IMG_BASE" "deploy/$XZ_BASE"

echo "==> generating rpi-imager manifest"
"$SCRIPT_DIR/make-imager-manifest.sh" "deploy/$XZ_BASE"

MANIFEST_FILE="deploy/${XZ_BASE%.img.xz}.rpi-imager-manifest.json"
MANIFEST_URI="$(python3 -c 'import sys, pathlib; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$MANIFEST_FILE")"
echo
echo "Paste this URL into rpi-imager > Choose OS > Custom Repository:"
echo "  $MANIFEST_URI"
