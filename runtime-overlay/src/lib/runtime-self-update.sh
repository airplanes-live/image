#!/usr/bin/env bash
# runtime-self-update.sh — drive a runtime-overlay upgrade through a
# state-machine-persisted protocol so a power loss between any two steps
# can be resumed (or rolled back) by airplanes-runtime-update-recover.sh
# on the next boot.
#
# Invoked as root via the webconfig orchestrator (sudoers-pinned). Owns the
# upgrade flock at /run/airplanes/runtime-update.lock for the whole
# protocol — state read/write, download/verify, extract, migrations
# forward, symlink flip, systemd ops, health gates, cleanup, rollback.
#
# Direct invocation (operator triage from a root shell) is permitted; the
# flock guarantees concurrent direct runs serialise rather than racing.
#
# Pin the lib dir at startup so a `current` symlink flip mid-process does
# not desync sourcing of install-common.sh.

set -uo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# install-common.sh location: the helper is sourced from the same source
# tree the runtime overlay was built from. For the in-source layout this
# is `runtime-overlay/scripts/lib/install-common.sh`; the search list lets
# the bats fixture and the future production layout (a flipped `current/`)
# both find it.
_lib_candidates=(
    "${AIRPLANES_RUNTIME_INSTALL_COMMON:-}"
    "${_self_dir}/../../scripts/lib/install-common.sh"
    "${_self_dir}/../scripts/lib/install-common.sh"
    "/opt/airplanes-runtime/current/scripts/lib/install-common.sh"
    "/usr/local/lib/airplanes-runtime/install-common.sh"
)
_lib=""
for _candidate in "${_lib_candidates[@]}"; do
    [[ -z "$_candidate" ]] && continue
    if [[ -r "$_candidate" ]]; then
        _lib="$_candidate"
        break
    fi
done
if [[ -z "$_lib" ]]; then
    echo "ERROR: runtime-self-update: install-common.sh not found in any of: ${_lib_candidates[*]}" >&2
    exit 1
fi
# shellcheck source=../../scripts/lib/install-common.sh
. "$_lib"

# ---------------------------------------------------------------------------
# Flock — acquired BEFORE state read/write so a losing invocation exits 75
# without touching the marker.
# ---------------------------------------------------------------------------

install -d -m 0755 "$(dirname "$AIRPLANES_RUNTIME_LOCK_FILE")"
exec 9>"$AIRPLANES_RUNTIME_LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: another runtime-overlay update is in progress (lock held: $AIRPLANES_RUNTIME_LOCK_FILE)" >&2
    exit 75
fi

# ---------------------------------------------------------------------------
# Resolve target root and bind state-file paths
# ---------------------------------------------------------------------------

TARGET_ROOT="$(airplanes_runtime_target_root)"

# Persist state or abort. A state-write failure means we cannot
# distinguish forward-progress from rollback on the next boot — there
# is no safe way to continue once we have lost write access to the
# state file. The caller surfaces the failure (we are pre-mutation if
# called before STARTED is reached, otherwise the in-flight rollback
# walks back from whatever the LAST successful state-write was).
_state_write_or_die() {
    if ! airplanes_runtime_state_write "$TARGET_ROOT" "$@"; then
        echo "FATAL: runtime-self-update: state-file write failed (args: $*); aborting" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Refuse re-entry on a dirty state
# ---------------------------------------------------------------------------
#
# Recovery is the boot-time oneshot's job; mixing entry paths is error-
# prone. CLEAN, INSTALLED, FAILED_PRE_MUTATION, and ROLLED_BACK_*
# (terminal good / terminal failure) are safe to enter from. Anything
# else means the previous attempt did not reach a terminal state and the
# recovery oneshot must drain the state file first.

_initial_state="$(airplanes_runtime_state_read "$TARGET_ROOT")"
case "$_initial_state" in
    CLEAN|INSTALLED|FAILED_PRE_MUTATION)
        # Safe to enter. Clear any terminal-good leftover so the new
        # attempt starts from a CLEAN file.
        airplanes_runtime_state_clear "$TARGET_ROOT"
        ;;
    ROLLED_BACK_*)
        # Terminal failure of a prior attempt — log it and start fresh.
        echo "runtime-self-update: prior attempt terminated in $_initial_state; starting fresh" >&2
        airplanes_runtime_state_clear "$TARGET_ROOT"
        ;;
    UNKNOWN)
        echo "ERROR: runtime-self-update: state file is malformed; run airplanes-runtime-update-recover.sh first" >&2
        exit 1
        ;;
    *)
        echo "ERROR: runtime-self-update: state file is in non-terminal state '$_initial_state'; run airplanes-runtime-update-recover.sh first" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Resolve channel / tag / arch, download, verify (pre-mutation)
# ---------------------------------------------------------------------------

ARCH_NAME="$(airplanes_runtime_detect_arch)"
CHANNEL="$(airplanes_runtime_resolve_channel)"
TAG="$(airplanes_runtime_resolve_tag "$CHANNEL")"

WORK_DIR="$(mktemp -d -t airplanes-runtime-update.XXXXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "runtime-self-update: arch=$ARCH_NAME channel=$CHANNEL tag=$TAG target_root=${TARGET_ROOT:-/}"

# pre_mutation_fail — record FAILED_PRE_MUTATION and exit. No on-disk
# mutation has happened yet; the next attempt clears this terminal state
# and starts fresh. A failure to persist the terminal state itself is
# surfaced (exit 1) but the next attempt will overwrite the prior file
# anyway.
pre_mutation_fail() {
    local reason="$1"
    airplanes_runtime_state_write "$TARGET_ROOT" FAILED_PRE_MUTATION \
        "failure_reason=$reason" || \
        echo "ERROR: pre_mutation_fail: could not persist FAILED_PRE_MUTATION" >&2
    exit 1
}

if ! airplanes_runtime_download_release "$TAG" "$ARCH_NAME" "$WORK_DIR"; then
    pre_mutation_fail "download_failed"
fi
TARBALL="$(airplanes_runtime_downloaded_tarball_path "$TAG" "$ARCH_NAME" "$WORK_DIR")"

MANIFEST="$WORK_DIR/manifest.json"
if ! airplanes_runtime_verify_manifest_version "$MANIFEST" "$TAG"; then
    pre_mutation_fail "manifest_version_mismatch"
fi

if ! airplanes_runtime_run_compat_preflight "$MANIFEST" "$TARGET_ROOT"; then
    pre_mutation_fail "compat_preflight_failed"
fi

# Resolve release version → release dir.
RELEASE_VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")"
RELEASE_DIR_ABS="${TARGET_ROOT}/opt/airplanes-runtime/releases/v${RELEASE_VERSION}"

# Snapshot the pre-update current symlink target so rollback knows where
# to flip back to. Empty if there is no current yet (first install).
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

# Same-version replay guard: if `current` already targets the version we
# are about to install, refuse. Mirrors install.sh's check so a re-driven
# update against the live release does not erase live files.
NEW_RELEASE_ON_DEVICE="${RELEASE_DIR_ABS#"$TARGET_ROOT"}"
if [[ -n "$PREV_RELEASE_LINK_TARGET" && "$PREV_RELEASE_LINK_TARGET" == "$NEW_RELEASE_ON_DEVICE" ]]; then
    pre_mutation_fail "same_version_replay_${NEW_RELEASE_ON_DEVICE//\//_}"
fi

# A prior incomplete install at the same version dir that did NOT become
# current — safe to remove and re-stage. (Not a mutation of live state.)
if [[ -e "$RELEASE_DIR_ABS" ]]; then
    rm -rf -- "$RELEASE_DIR_ABS"
fi

# ---------------------------------------------------------------------------
# Open the attempt: write STARTED with prev_release / new_release pinned.
# ---------------------------------------------------------------------------

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_state_write_or_die STARTED \
    "prev_release=$PREV_RELEASE_DIR" \
    "new_release=$RELEASE_DIR_ABS" \
    "started_at=$STARTED_AT"

# ---------------------------------------------------------------------------
# Rollback helper
# ---------------------------------------------------------------------------
#
# Drives the inverse of the forward walk. The caller invokes from the
# state at which the failure was observed; we walk back through any state
# whose forward step has already run. Idempotent — calling roll_back_to
# CLEAN from PAYLOAD_EXTRACTED runs only the rm; calling it from
# SYMLINK_FLIPPED runs the migration rollback, preimage restore, symlink
# revert, and unit restart in order.
#
# The forward state at the time of the failure is recorded in the state
# file. We READ it inside the helper so an exit-trap invocation gets the
# latest checkpoint.
roll_back_and_exit() {
    local rc="$1"
    local at
    at="$(airplanes_runtime_state_read "$TARGET_ROOT")"
    local reason="${2:-rollback_from_${at}}"
    local prev new
    prev="$(airplanes_runtime_state_get "$TARGET_ROOT" prev_release)"
    new="$(airplanes_runtime_state_get  "$TARGET_ROOT" new_release)"

    echo "runtime-self-update: rolling back from $at" >&2

    # SYMLINK_FLIPPED / SYSTEMD_OPS_DONE / HEALTH_RUNNING : stop the
    # decoder + uat-sync units first so a migration rollback that touches
    # mutable config does not race a still-running daemon.
    case "$at" in
        SYMLINK_FLIPPED|SYSTEMD_OPS_DONE|HEALTH_RUNNING)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop \
                    airplanes-tar1090-uat-sync.service \
                    airplanes-978.service \
                    dump978-fa.service \
                    readsb.service 2>/dev/null || true
            fi
            ;;
    esac

    # MIGRATIONS_FORWARD_DONE / SYMLINK_FLIPPED / SYSTEMD_OPS_DONE /
    # HEALTH_RUNNING : migration rollbacks run from the NEW release dir
    # (its `.attempt-migrations.applied` records what we forward-applied).
    case "$at" in
        MIGRATIONS_FORWARD_DONE|SYMLINK_FLIPPED|SYSTEMD_OPS_DONE|HEALTH_RUNNING)
            if [[ -n "$new" && -f "$new/manifest.json" ]]; then
                airplanes_runtime_run_migrations_rollback \
                    "$new/manifest.json" "$new" "$TARGET_ROOT" || true
                airplanes_runtime_restore_all_mutable_paths \
                    "$new/manifest.json" "$new" "$TARGET_ROOT" || true
            fi
            ;;
    esac

    # SYMLINK_FLIPPED / SYSTEMD_OPS_DONE / HEALTH_RUNNING : flip current
    # back to the prior release. If there was no prior release (first
    # install), drop the dangling symlink so subsequent attempts see a
    # clean tree.
    case "$at" in
        SYMLINK_FLIPPED|SYSTEMD_OPS_DONE|HEALTH_RUNNING)
            if [[ -n "$prev" ]]; then
                # prev is the on-device-canonical path the link should
                # point at — strip any TARGET_ROOT prefix before passing
                # to flip_current, which re-rebases under target_root.
                local prev_on_device="${prev#"$TARGET_ROOT"}"
                airplanes_runtime_flip_current "$prev_on_device" "$TARGET_ROOT" || true
                airplanes_runtime_relink_decoder_binaries "$TARGET_ROOT" || true
            else
                rm -f -- "${TARGET_ROOT}/opt/airplanes-runtime/current"
            fi
            ;;
    esac

    # SYMLINK_FLIPPED / SYSTEMD_OPS_DONE / HEALTH_RUNNING : daemon-reload
    # + restart the prior release's decoder stack so the rolled-back
    # symlink takes effect. Order mirrors the hardcoded forward restart
    # order in apply_systemd_ops.
    case "$at" in
        SYMLINK_FLIPPED|SYSTEMD_OPS_DONE|HEALTH_RUNNING)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl daemon-reload 2>/dev/null || true
                if [[ -n "$prev" ]]; then
                    systemctl restart \
                        readsb.service \
                        dump978-fa.service \
                        airplanes-978.service \
                        airplanes-tar1090-uat-sync.service 2>/dev/null || true
                fi
            fi
            ;;
    esac

    # Any post-extract state: drop the new release dir so a successful
    # retry can re-stage it without the "release dir already exists"
    # safety guard tripping.
    case "$at" in
        PAYLOAD_EXTRACTED|MIGRATIONS_FORWARD_DONE|SYMLINK_FLIPPED|SYSTEMD_OPS_DONE|HEALTH_RUNNING)
            if [[ -n "$new" && -d "$new" ]]; then
                rm -rf -- "$new"
            fi
            ;;
    esac

    # Final terminal state — encode where we were and where we ended up.
    local prev_label="${prev:-none}"
    prev_label="${prev_label##*/v}"
    prev_label="${prev_label%/}"
    local new_label="${new:-unknown}"
    new_label="${new_label##*/v}"
    new_label="${new_label%/}"
    airplanes_runtime_state_write "$TARGET_ROOT" \
        "ROLLED_BACK_${new_label}_TO_${prev_label}" \
        "failure_reason=$reason" || \
        echo "ERROR: roll_back_and_exit: could not persist ROLLED_BACK terminal state" >&2

    exit "$rc"
}

# ---------------------------------------------------------------------------
# Forward walk
# ---------------------------------------------------------------------------

# State-write convention: every state checkpoint is written BEFORE the
# operation it labels, so a power-loss after the state-write but before
# the operation completes recovers through the same rollback path as one
# where the operation finished. The .attempt-migrations.applied file
# tracks per-migration completion so a partial migration set rolls back
# cleanly regardless of where in MIGRATIONS_FORWARD_DONE we crashed.

# PAYLOAD_EXTRACTED — write FIRST so a power-loss mid-extract (which
# leaves a partial tree under RELEASE_DIR_ABS) recovers by removing the
# scratch dir.
_state_write_or_die PAYLOAD_EXTRACTED
if ! airplanes_runtime_extract_release_tarball \
        "$TARBALL" \
        "$RELEASE_DIR_ABS"; then
    roll_back_and_exit 1 "extract_failed"
fi

# The manifest in the release dir is the one downstream steps trust.
RELEASE_MANIFEST="$RELEASE_DIR_ABS/manifest.json"

# MIGRATIONS_FORWARD_DONE — write BEFORE the first live-state mutation
# (preimage backup + forward migrations). A crash in this window
# recovers by running rollback against the per-attempt completion file
# (which only contains migrations that fully forward-applied) and
# restoring preimages.
_state_write_or_die MIGRATIONS_FORWARD_DONE
if ! airplanes_runtime_backup_all_mutable_paths \
        "$RELEASE_MANIFEST" "$RELEASE_DIR_ABS" "$TARGET_ROOT"; then
    roll_back_and_exit 1 "mutable_backup_failed"
fi
if ! airplanes_runtime_run_migrations_forward \
        "$RELEASE_MANIFEST" "$RELEASE_DIR_ABS" "$TARGET_ROOT"; then
    roll_back_and_exit 1 "migrations_forward_failed"
fi

# SYMLINK_FLIPPED — write BEFORE flip_current so a crash mid-flip
# recovers by reverting the symlink (which may or may not have been
# moved, mv -Tf is atomic so it is in one of two valid states).
_state_write_or_die SYMLINK_FLIPPED
NEW_RELEASE_ON_DEVICE="${RELEASE_DIR_ABS#"$TARGET_ROOT"}"
if ! airplanes_runtime_flip_current "$NEW_RELEASE_ON_DEVICE" "$TARGET_ROOT"; then
    roll_back_and_exit 1 "symlink_flip_failed"
fi
if ! airplanes_runtime_relink_decoder_binaries "$TARGET_ROOT"; then
    roll_back_and_exit 1 "decoder_relink_failed"
fi
if ! airplanes_runtime_apply_managed_paths \
        "$RELEASE_MANIFEST" "$RELEASE_DIR_ABS" "$TARGET_ROOT"; then
    roll_back_and_exit 1 "managed_paths_failed"
fi

# SYSTEMD_OPS_DONE — write BEFORE daemon-reload+restart so a crash
# mid-restart recovers through the stop-services-and-revert path.
_state_write_or_die SYSTEMD_OPS_DONE
if ! airplanes_runtime_apply_systemd_ops "$RELEASE_MANIFEST"; then
    roll_back_and_exit 1 "systemd_ops_failed"
fi

# HEALTH_RUNNING → HEALTH_PASSED
_state_write_or_die HEALTH_RUNNING
if ! airplanes_runtime_run_health_gates "$TARGET_ROOT"; then
    roll_back_and_exit 1 "health_gates_failed"
fi
_state_write_or_die HEALTH_PASSED

# Cleanup → INSTALLED. Both steps below run within HEALTH_PASSED; a
# failure here leaves the state at HEALTH_PASSED so the recovery
# oneshot finishes the cleanup pass on next boot. We deliberately do
# NOT roll back here — health gates passed, the live release is good.
if ! airplanes_runtime_record_runtime_manifest "$TARGET_ROOT"; then
    echo "ERROR: runtime-self-update: failed to record runtime manifest pointer after HEALTH_PASSED" >&2
    exit 1
fi
if ! airplanes_runtime_gc_old_releases "$TARGET_ROOT"; then
    echo "WARN: runtime-self-update: GC of old releases reported a failure (non-fatal)" >&2
fi

_state_write_or_die INSTALLED
echo "runtime-self-update: done (state=INSTALLED)"
exit 0
