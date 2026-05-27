#!/usr/bin/env bash
# install.sh — runtime overlay installer, single path for image build and on-device update.
#
# Modes:
#   --build-mode (or AIRPLANES_BUILD_MODE=1)
#       Invoked from pi-gen's stage-airplanes/02-install-runtime-overlay/.
#       ROOTFS_DIR points at the staging rootfs; ARCH is set by pi-gen;
#       AIRPLANES_RUNTIME_RELEASE_ASSET_DIR points at the signed runtime assets
#       produced earlier in the product-release workflow. Local builds may set
#       AIRPLANES_RUNTIME_OVERLAY_TAG to install from a published product release.
#       Downloads/copies and verifies the release, extracts it under
#       ${ROOTFS_DIR}/opt/airplanes-runtime/releases/v<version>/, flips
#       current, relinks decoder binaries, lays managed_paths. Skips
#       systemd ops (handled by the chroot stage) and health gates (no
#       running system to probe).
#
#   --runtime (the default)
#       Invoked by the on-device self-update helper. Reads
#       /etc/airplanes/release-channel, resolves stable (latest published
#       vX.Y.Z product release) or dev (dev-latest). Runs the full
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
TARBALL="$(airplanes_runtime_downloaded_tarball_path "$ARCH_NAME" "$WORK_DIR")"

MANIFEST="$WORK_DIR/manifest.json"
airplanes_runtime_verify_manifest_version "$MANIFEST" "$TAG"

if airplanes_runtime_is_build_mode; then
    # The build-mode caller cloned this source tree at the same ref that
    # produced the binary; assert the release's manifest matches.
    #
    # AIRPLANES_RUNTIME_SKIP_SOURCE_SHA_CHECK=1 disables this assertion for
    # in-tree usage where the cloned source IS the image repo (not a
    # separate runtime-overlay clone) and the image build pins to an
    # older published runtime-release tag than the image repo HEAD. The
    # device installs the release tarball, not the in-tree source files,
    # so the source-matches-release invariant is not load-bearing in that
    # configuration. The minisign signature on SHA256SUMS plus the
    # manifest-version cross-check still pin tag↔manifest↔tarball.
    if [[ "${AIRPLANES_RUNTIME_SKIP_SOURCE_SHA_CHECK:-0}" == "1" ]]; then
        echo "runtime-overlay install: AIRPLANES_RUNTIME_SKIP_SOURCE_SHA_CHECK=1; skipping commit_sha cross-check"
    else
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
fi

if ! airplanes_runtime_is_build_mode; then
    airplanes_runtime_run_compat_preflight "$MANIFEST" "$TARGET_ROOT"
fi

# Resolve release version from the manifest so the extraction destination
# is canonical (and so a `dev-latest` floating tag still lands under its
# concrete v<X.Y.Z-dev-...> dir).
RELEASE_VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")"
RELEASE_DIR_ABS="${TARGET_ROOT}/opt/airplanes-runtime/releases/v${RELEASE_VERSION}"

# Compute PREV_RELEASE_DIR from the pre-flip current symlink. Empty if
# there's no current yet (first install). The link target is always an
# on-device-canonical path (`/opt/airplanes-runtime/releases/v<X>/`); for
# downstream consumers under a build-mode rebase we surface it rebased so
# shell migrations can stat it under TARGET_ROOT, while we compare the
# link's literal target against the on-device equivalent of the new
# release path.
CURRENT_LINK="${TARGET_ROOT}/opt/airplanes-runtime/current"
PREV_RELEASE_LINK_TARGET=""
PREV_RELEASE_DIR=""
if [[ -L "$CURRENT_LINK" ]]; then
    PREV_RELEASE_LINK_TARGET="$(readlink "$CURRENT_LINK")"
    if [[ -n "$TARGET_ROOT" ]]; then
        PREV_RELEASE_DIR="${TARGET_ROOT}${PREV_RELEASE_LINK_TARGET}"
    else
        PREV_RELEASE_DIR="$PREV_RELEASE_LINK_TARGET"
    fi
fi
export PREV_RELEASE_DIR

# Same-version replay safety: if `current` already points at the dir we're
# about to extract, refuse rather than rm -rf the live release. Compare
# the link's literal target against the on-device equivalent of the new
# release path (RELEASE_DIR_ABS stripped of TARGET_ROOT). The caller
# (operator triage shell or runtime-self-update.sh) bumps the version or
# removes `current` by hand to recover.
NEW_RELEASE_ON_DEVICE="${RELEASE_DIR_ABS#"$TARGET_ROOT"}"
if [[ -n "$PREV_RELEASE_LINK_TARGET" && "$PREV_RELEASE_LINK_TARGET" == "$NEW_RELEASE_ON_DEVICE" ]]; then
    echo "ERROR: requested release ($NEW_RELEASE_ON_DEVICE) is the active 'current' target." >&2
    echo "       Refusing to overwrite. Bump the version or remove 'current' first." >&2
    exit 1
fi

if [[ -e "$RELEASE_DIR_ABS" ]]; then
    # A prior incomplete install of the same version that did NOT become
    # current. Safe to remove and re-stage.
    rm -rf -- "$RELEASE_DIR_ABS"
fi

airplanes_runtime_extract_release_tarball \
    "$TARBALL" \
    "$RELEASE_DIR_ABS"

# The manifest in the release dir is the one subsequent steps trust. The
# one in WORK_DIR was used for verify-then-discard.
RELEASE_MANIFEST="$RELEASE_DIR_ABS/manifest.json"

airplanes_runtime_run_install_steps "$RELEASE_MANIFEST" "$RELEASE_DIR_ABS" "$TARGET_ROOT"

echo "runtime-overlay install: done"
