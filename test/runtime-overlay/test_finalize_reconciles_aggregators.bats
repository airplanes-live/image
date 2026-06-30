#!/usr/bin/env bats

# Pin the post-health-gate aggregator reconcile pass.
#
# After the health gate validates a new overlay, finalize asks the on-device
# apl-aggregator helper (shipped in the overlay from image-webconfig) to bring
# third-party aggregators (FR24 / FlightAware) to the versions THIS release pins
# and restart the enabled ones — so a release that bumps an aggregator pin
# auto-applies on update. The pass is best-effort and fail-soft: it runs after the
# health gate, so nothing here rolls back, and an absent helper (older overlay) or
# build mode is a clean no-op.

bats_require_minimum_version 1.5.0

load lib/install_test_helpers

setup() {
    source_install_lib
    WORK="$BATS_TEST_TMPDIR/work"
    install -d -m 755 "$WORK"

    SHIM_DIR="$BATS_TEST_TMPDIR/shim"
    SYSCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    mk_systemctl_shim "$SHIM_DIR" "$SYSCTL_LOG" >/dev/null
    PATH="$SHIM_DIR:$PATH"
    export PATH

    # apl-aggregator stub — logs its argv; exit code controlled by AGG_RC.
    AGG_LOG="$BATS_TEST_TMPDIR/agg.log"
    AGG_HELPER="$BATS_TEST_TMPDIR/apl-aggregator"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$*" >> %q\n' "$AGG_LOG"
        printf 'exit "${AGG_RC:-0}"\n'
    } > "$AGG_HELPER"
    chmod 755 "$AGG_HELPER"
    export AIRPLANES_RUNTIME_AGG_HELPER="$AGG_HELPER"
}

# -- helper unit cases ------------------------------------------------------

@test "reconcile_aggregators invokes the helper with 'reconcile --json'" {
    AIRPLANES_BUILD_MODE=0 run airplanes_runtime_reconcile_aggregators
    [ "$status" -eq 0 ]
    grep -Fx 'reconcile --json' "$AGG_LOG"
}

@test "reconcile_aggregators returns 0 even when the helper fails (fail-soft)" {
    AGG_RC=7 AIRPLANES_BUILD_MODE=0 run airplanes_runtime_reconcile_aggregators
    [ "$status" -eq 0 ]
    grep -Fx 'reconcile --json' "$AGG_LOG"
}

@test "reconcile_aggregators is a no-op in build mode" {
    AIRPLANES_BUILD_MODE=1 run airplanes_runtime_reconcile_aggregators
    [ "$status" -eq 0 ]
    [ ! -s "$AGG_LOG" ]
}

@test "reconcile_aggregators is a no-op when the helper is absent" {
    rm -f "$AGG_HELPER"
    AIRPLANES_BUILD_MODE=0 run airplanes_runtime_reconcile_aggregators
    [ "$status" -eq 0 ]
    [ ! -s "$AGG_LOG" ]
}

# -- integration through finalize ------------------------------------------

@test "finalize_after_health_passed drives the aggregator reconcile" {
    local target_root new_dir
    target_root="$(mk_target_root "$WORK")"
    new_dir="$(mk_target_release "$target_root" "0.0.2")"
    mk_state_file "$target_root" "HEALTH_PASSED" "new_release=$new_dir"
    ln -s "/opt/airplanes/releases/v0.0.2" \
        "$target_root/opt/airplanes/current"

    AIRPLANES_BUILD_MODE=0 run airplanes_runtime_finalize_after_health_passed "$target_root"
    [ "$status" -eq 0 ]
    grep -Fx 'reconcile --json' "$AGG_LOG"
}

@test "finalize calls reconcile_aggregators after gc_old_releases" {
    # Static pin on the call position — a behavioural end-to-end test would have
    # to stub the whole finalize sequence (covered elsewhere). What matters here
    # is that the reconcile call stays AFTER GC, the last step.
    local body
    body="$(awk '
        /^airplanes_runtime_finalize_after_health_passed\(\)/ { in_fn = 1 }
        in_fn { print }
        in_fn && /^}$/ { exit }
    ' "$LIB_PATH")"
    [[ -n "$body" ]] || { echo "could not extract finalize body" >&2; return 1; }
    [[ "$body" == *"gc_old_releases"*"reconcile_aggregators"* ]] \
        || { echo "finalize no longer calls reconcile_aggregators after gc_old_releases" >&2
             printf '%s\n' "$body" >&2
             return 1; }
}
