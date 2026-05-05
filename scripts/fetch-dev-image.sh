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

for cmd in gh jq xz git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "missing required tool: $cmd" >&2
        exit 1
    fi
done

git fetch -q origin "$BRANCH"
TARGET_SHA="$(git rev-parse "origin/$BRANCH")"
echo "==> origin/$BRANCH at $TARGET_SHA"

RUN_ID="$(gh run list -R "$REPO" -w "$WORKFLOW" -b "$BRANCH" --status success -L 20 \
    --json databaseId,headSha \
    | jq -r --arg sha "$TARGET_SHA" '.[] | select(.headSha == $sha) | .databaseId' \
    | head -n1)"

if [[ -z "$RUN_ID" ]]; then
    echo "no successful $WORKFLOW run on $BRANCH at $TARGET_SHA" >&2
    echo "(CI may still be running; latest runs on $BRANCH:)" >&2
    gh run list -R "$REPO" -w "$WORKFLOW" -b "$BRANCH" -L 5 >&2
    exit 1
fi

echo "==> matched run $RUN_ID"

mkdir -p deploy
echo "==> downloading $ARTIFACT into deploy/"
gh run download -R "$REPO" -n "$ARTIFACT" -D deploy/ "$RUN_ID"

shopt -s nullglob
xz_files=(deploy/*.img.xz)
if (( ${#xz_files[@]} == 0 )); then
    echo "no .img.xz found in deploy/ after download" >&2
    exit 1
fi

for xz in "${xz_files[@]}"; do
    echo "==> decompressing $(basename -- "$xz")"
    xz -df -- "$xz"
done

echo "OK: deploy image ready"
ls -lh deploy/*.img
