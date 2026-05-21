#!/usr/bin/env bash
# airplanes-runtime-update-recover.sh — boot-time recovery oneshot for the
# runtime-overlay self-update protocol. Reads the persisted upgrade state
# and either finishes the install cleanup pass (HEALTH_PASSED) or rolls
# the system back to the prior release (every non-terminal state past
# STARTED).
#
# The runtime-overlay self-update orchestrator (runtime-self-update.sh)
# persists checkpoints to /var/lib/airplanes-runtime-upgrade/upgrade-state.
# If a power loss interrupts the orchestrator mid-protocol, the next boot
# runs this script BEFORE the decoder units (per the unit's `Before=`
# ordering) so a partial flip cannot start a daemon against a half-applied
# release.
#
# Pin _self_dir at startup so a `current` symlink flip mid-process (we
# might be running off the new release's tree) does not desync sourcing
# of install-common.sh.

set -uo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

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
    echo "ERROR: runtime-update-recover: install-common.sh not found" >&2
    exit 1
fi
# shellcheck source=../../scripts/lib/install-common.sh
. "$_lib"

TARGET_ROOT="$(airplanes_runtime_target_root)"

STATE="$(airplanes_runtime_state_read "$TARGET_ROOT")"
PREV="$(airplanes_runtime_state_get "$TARGET_ROOT" prev_release)"
NEW="$(airplanes_runtime_state_get  "$TARGET_ROOT" new_release)"

echo "runtime-update-recover: state=$STATE prev=$PREV new=$NEW"

# Helper: flip current back to the prior release. If prev is empty (no
# release before the failed attempt), drop the dangling symlink instead.
_recover_revert_symlink() {
    if [[ -n "$PREV" ]]; then
        local prev_on_device="${PREV#"$TARGET_ROOT"}"
        airplanes_runtime_flip_current "$prev_on_device" "$TARGET_ROOT" || true
        airplanes_runtime_relink_decoder_binaries "$TARGET_ROOT" || true
    else
        rm -f -- "${TARGET_ROOT}/opt/airplanes-runtime/current"
    fi
}

# Helper: undo migrations + restore preimages from the NEW release dir.
_recover_undo_migrations() {
    if [[ -n "$NEW" && -f "$NEW/manifest.json" ]]; then
        airplanes_runtime_run_migrations_rollback \
            "$NEW/manifest.json" "$NEW" "$TARGET_ROOT" || true
        airplanes_runtime_restore_all_mutable_paths \
            "$NEW/manifest.json" "$NEW" "$TARGET_ROOT" || true
    fi
}

# Helper: drop the (partial) new release dir.
_recover_drop_new_release() {
    if [[ -n "$NEW" && -d "$NEW" ]]; then
        rm -rf -- "$NEW"
    fi
}

# Helper: format a ROLLED_BACK terminal state from the prev/new versions.
_recover_terminal_label() {
    local prev_label="${PREV:-none}"
    prev_label="${prev_label##*/v}"
    prev_label="${prev_label%/}"
    local new_label="${NEW:-unknown}"
    new_label="${new_label##*/v}"
    new_label="${new_label%/}"
    printf 'ROLLED_BACK_%s_TO_%s' "$new_label" "$prev_label"
}

case "$STATE" in
    CLEAN)
        # No-op. The orchestrator either has not run since boot or last
        # exited cleanly. Belt-and-braces: drop any stragglers under the
        # download scratch dir (rare in practice — mktemp -d under /tmp
        # is cleaned on tmpfs reboot).
        ;;
    STARTED)
        # The orchestrator reserved the state file but had not yet
        # extracted the tarball. No on-disk release-tree mutation
        # happened; just clear the state file and (defensively) drop
        # the staged release dir if it exists.
        _recover_drop_new_release
        airplanes_runtime_state_clear "$TARGET_ROOT"
        ;;
    PAYLOAD_EXTRACTED)
        # The new release tree exists under releases/v<new>/ but
        # nothing else has been touched. Drop it.
        _recover_drop_new_release
        airplanes_runtime_state_clear "$TARGET_ROOT"
        ;;
    MIGRATIONS_FORWARD_DONE)
        # Migrations ran forward; current symlink not yet flipped, so
        # services on this boot are still pointed at the prior release.
        # Undo the migrations, restore preimages, drop the new release.
        _recover_undo_migrations
        _recover_drop_new_release
        airplanes_runtime_state_write "$TARGET_ROOT" "$(_recover_terminal_label)" \
            "failure_reason=power_loss_at_MIGRATIONS_FORWARD_DONE"
        ;;
    SYMLINK_FLIPPED|SYSTEMD_OPS_DONE|HEALTH_RUNNING)
        # The decoder units are stopped on this boot (the unit runs
        # Before= them), so we do not stop them ourselves. Undo
        # migrations from the new release dir, restore preimages, flip
        # current back to the prior release, daemon-reload. Decoder
        # restart is left to systemd's normal startup of readsb /
        # dump978 / airplanes-978 / uat-sync — those units are reached
        # AFTER this oneshot's RemainAfterExit=yes completes.
        _recover_undo_migrations
        _recover_revert_symlink
        _recover_drop_new_release
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload 2>/dev/null || true
        fi
        airplanes_runtime_state_write "$TARGET_ROOT" "$(_recover_terminal_label)" \
            "failure_reason=power_loss_at_$STATE"
        ;;
    HEALTH_PASSED)
        # Health gates passed during the live attempt; the cleanup pass
        # was interrupted. Complete it: write the runtime manifest
        # pointer, GC old releases, mark INSTALLED. Do NOT roll back —
        # the live release is the good one.
        airplanes_runtime_record_runtime_manifest "$TARGET_ROOT" || true
        airplanes_runtime_gc_old_releases "$TARGET_ROOT" || true
        airplanes_runtime_state_write "$TARGET_ROOT" INSTALLED
        ;;
    INSTALLED|FAILED_PRE_MUTATION)
        # Terminal good / terminal failure that did not mutate on-disk
        # state. Nothing to recover.
        ;;
    ROLLED_BACK_*)
        # Terminal failure of a previous attempt — already cleaned up.
        ;;
    UNKNOWN)
        echo "WARN: runtime-update-recover: state file malformed; leaving as-is for operator triage" >&2
        ;;
    *)
        echo "WARN: runtime-update-recover: unknown state '$STATE'; leaving as-is for operator triage" >&2
        ;;
esac

echo "runtime-update-recover: done"
exit 0
