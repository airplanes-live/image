#!/usr/bin/env bash
# install.sh — runtime overlay installer, single path for image build and on-device update.
#
# Modes:
#   --build-mode (or AIRPLANES_BUILD_MODE=1)
#       Invoked from pi-gen's stage-airplanes/02-install-runtime-overlay/.
#       ROOTFS_DIR points at the staging rootfs; ARCH is set by pi-gen;
#       AIRPLANES_RUNTIME_OVERLAY_TAG names the concrete release tag the
#       image config pinned (runtime-vX.Y.Z for stable, runtime-dev-YYYYMMDD-<sha>
#       for dev). Downloads and verifies the release, extracts it under
#       ${ROOTFS_DIR}/opt/airplanes-runtime/releases/v<version>/, flips
#       current, relinks decoder binaries, lays managed_paths. Skips
#       systemd ops (handled by the chroot stage) and health gates (no
#       running system to probe).
#
#   --runtime (the default)
#       Invoked by the on-device self-update helper. Reads
#       /etc/airplanes/release-channel, resolves stable (highest semver
#       runtime-vX.Y.Z) or dev (runtime-dev-latest). Runs the full
#       install pipeline: download → verify → compat preflight →
#       extract → migrations forward → flip → relink → managed_paths →
#       systemd ops → health gates → record manifest pointer → GC.
#       Caller (the helper, lands in a follow-up change) owns flock,
#       state-machine persistence, and rollback orchestration.
#
# Pin the lib dir at startup so a `current` symlink flip mid-process
# doesn't desync the source path of helpers we still need to call
# (resolved decision 16).

set -euo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=scripts/lib/install-common.sh
. "$_self_dir/scripts/lib/install-common.sh"

airplanes_runtime_parse_mode_args "$@"

ARCH_NAME="$(airplanes_runtime_detect_arch)"
CHANNEL="$(airplanes_runtime_resolve_channel)"
TAG="$(airplanes_runtime_resolve_tag "$CHANNEL")"

TARGET_ROOT="$(airplanes_runtime_target_root)"

WORK_DIR="$(mktemp -d -t airplanes-runtime-install.XXXXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

if airplanes_runtime_is_build_mode; then
    echo "runtime-overlay install: mode=build arch=$ARCH_NAME tag=$TAG target_root=$TARGET_ROOT"
else
    echo "runtime-overlay install: mode=runtime arch=$ARCH_NAME channel=$CHANNEL tag=$TAG target_root=${TARGET_ROOT:-/}"
fi

airplanes_runtime_download_release "$TAG" "$ARCH_NAME" "$WORK_DIR"

MANIFEST="$WORK_DIR/manifest.json"
airplanes_runtime_verify_manifest_version "$MANIFEST" "$TAG"

if airplanes_runtime_is_build_mode; then
    # The build-mode caller cloned this source tree at the same ref that
    # produced the binary; assert the release's manifest matches.
    EXPECTED_SHA="$(git -C "$_self_dir" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$EXPECTED_SHA" ]]; then
        airplanes_runtime_verify_manifest_sha "$MANIFEST" "$EXPECTED_SHA"
    else
        # No git context (e.g. release tarball extracted into a non-git
        # tree). Skip rather than refuse — the manifest-version cross-check
        # already pinned the tag↔manifest mapping.
        echo "runtime-overlay install: no git context under $_self_dir; skipping commit_sha cross-check"
    fi
fi

if ! airplanes_runtime_is_build_mode; then
    airplanes_runtime_run_compat_preflight "$MANIFEST" "$TARGET_ROOT"
fi

# Resolve release version from the manifest so the extraction destination
# is canonical (and so a `dev-latest` floating tag still lands under its
# concrete v<X.Y.Z-dev-...> dir).
RELEASE_VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")"
RELEASE_DIR_ABS="${TARGET_ROOT}/opt/airplanes-runtime/releases/v${RELEASE_VERSION}"

if [[ -e "$RELEASE_DIR_ABS" ]]; then
    # A prior incomplete install (or a deliberate re-run) of the same
    # version: remove the staged dir so the extract is clean. Never touch
    # `current` from here — that's the prior release the user is still on.
    rm -rf -- "$RELEASE_DIR_ABS"
fi

airplanes_runtime_extract_release_tarball \
    "$WORK_DIR/${TAG}-${ARCH_NAME}.tar.gz" \
    "$RELEASE_DIR_ABS"

# The manifest in the release dir is the one subsequent steps trust. The
# one in WORK_DIR was used for verify-then-discard.
RELEASE_MANIFEST="$RELEASE_DIR_ABS/manifest.json"

airplanes_runtime_run_install_steps "$RELEASE_MANIFEST" "$RELEASE_DIR_ABS" "$TARGET_ROOT"

echo "runtime-overlay install: done"
