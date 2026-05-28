#!/usr/bin/env bats

# Pin the post-health-gate activator-start pass.
#
# `systemctl enable <activator>` writes the relevant target's wants-link but
# does not arm the activator in the current boot. On a fresh-flashed image
# that doesn't matter — `timers.target` / `paths.target` brings everything up
# at boot. On an in-place runtime self-update OR a direct `install.sh
# --runtime` invocation, a newly-enabled timer/path would otherwise stay idle
# until next reboot. `airplanes_runtime_start_enabled_activators` closes
# that gap by starting each *.timer / *.path in the manifest's enable list,
# best-effort, after the health gate has already validated the release.
#
# This file covers the helper in isolation AND its wiring through
# `airplanes_runtime_finalize_after_health_passed` (the state-machine
# self-update callsite). The direct `install.sh --runtime` callsite at
# `airplanes_runtime_run_install_steps` calls the same helper with the
# same shape and is exercised end-to-end by the upgrade boot-smoke job.

bats_require_minimum_version 1.5.0

load lib/install_test_helpers

setup() {
    source_install_lib
    WORK="$BATS_TEST_TMPDIR/work"
    install -d -m 755 "$WORK"

    # Default shim — logs every non-`show` invocation, exits 0. Tests that
    # need failure injection install a custom shim below.
    SHIM_DIR="$BATS_TEST_TMPDIR/shim"
    SYSCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    mk_systemctl_shim "$SHIM_DIR" "$SYSCTL_LOG" >/dev/null
    PATH="$SHIM_DIR:$PATH"
    export PATH
}

# Write a minimal release manifest whose `.systemd.enable` carries `$@` as
# entries. Echoes the manifest path.
_write_manifest() {
    local f="$1"; shift
    local jq_enable
    jq_enable="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
    cat > "$f" <<JSON
{
    "version": "1.0.0",
    "channel": "stable",
    "commit_sha": "0000000000000000000000000000000000000000",
    "build_date": "2026-05-28T00:00:00Z",
    "arches": ["arm64"],
    "components": { "readsb_wiedehopf": "0000000" },
    "managed_paths": [],
    "mutable_paths": [],
    "systemd": { "enable": ${jq_enable}, "daemon_reload": true },
    "migrations": []
}
JSON
    printf '%s' "$f"
}

# Install a failure-injecting systemctl shim that exits non-zero when its
# argv matches "$SHIM_FAIL_PATTERN", logs every call to SYSCTL_LOG, and
# falls through to healthy `show` defaults for anything else (so the
# rest of the install path that calls `systemctl show` keeps working).
# Mirrors test_self_update_rollback_from_each_state.bats's pattern.
_install_failing_shim() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'SYSCTL_LOG=%q\n' "$SYSCTL_LOG"
        cat <<'EOF'
printf '%s\n' "$*" >> "$SYSCTL_LOG"
if [[ "${1:-}" == "show" ]]; then
    unit="${2:-}"; prop=""
    args=("$@"); n=${#args[@]}
    for ((i = 0; i < n; i++)); do
        case "${args[i]}" in
            -p) prop="${args[i+1]:-}" ;;
            --property=*) prop="${args[i]#--property=}" ;;
        esac
    done
    case "$prop" in
        ActiveState) echo active ;;
        SubState)    echo running ;;
        Result)      echo success ;;
        NRestarts)   echo 0 ;;
        RestartUSec) echo 0 ;;
        *)           echo "" ;;
    esac
    exit 0
fi
if [[ -n "${SHIM_FAIL_PATTERN:-}" && "$*" == *"$SHIM_FAIL_PATTERN"* ]]; then
    exit 1
fi
exit 0
EOF
    } > "$SHIM_DIR/systemctl"
    chmod 755 "$SHIM_DIR/systemctl"
}

# -- helper unit cases ------------------------------------------------------

@test "start_activators invokes systemctl start for each *.timer" {
    local manifest
    manifest="$(_write_manifest "$WORK/manifest.json" \
        "airplanes-diagnostics.timer" "airplanes-config-sync.timer")"
    AIRPLANES_BUILD_MODE=0 run airplanes_runtime_start_enabled_activators "$manifest"
    [ "$status" -eq 0 ]
    grep -Fx 'start airplanes-diagnostics.timer' "$SYSCTL_LOG"
    grep -Fx 'start airplanes-config-sync.timer' "$SYSCTL_LOG"
}

@test "start_activators invokes systemctl start for each *.path" {
    local manifest
    manifest="$(_write_manifest "$WORK/manifest.json" \
        "airplanes-tar1090-uat-sync.path")"
    AIRPLANES_BUILD_MODE=0 run airplanes_runtime_start_enabled_activators "$manifest"
    [ "$status" -eq 0 ]
    grep -Fx 'start airplanes-tar1090-uat-sync.path' "$SYSCTL_LOG"
}

@test "start_activators does NOT invoke start for *.service entries" {
    local manifest
    manifest="$(_write_manifest "$WORK/manifest.json" \
        "readsb.service" "airplanes-feed.service" "airplanes-diagnostics.timer")"
    AIRPLANES_BUILD_MODE=0 run airplanes_runtime_start_enabled_activators "$manifest"
    [ "$status" -eq 0 ]
    # The timer was started.
    grep -Fx 'start airplanes-diagnostics.timer' "$SYSCTL_LOG"
    # The services were not — restarting daemons is apply_systemd_ops' job.
    run grep -Fx 'start readsb.service' "$SYSCTL_LOG"
    [ "$status" -ne 0 ]
    run grep -Fx 'start airplanes-feed.service' "$SYSCTL_LOG"
    [ "$status" -ne 0 ]
}

@test "start_activators logs WARN and returns 0 when a start fails" {
    _install_failing_shim
    SHIM_FAIL_PATTERN='start airplanes-diagnostics.timer'
    export SHIM_FAIL_PATTERN
    local manifest
    manifest="$(_write_manifest "$WORK/manifest.json" \
        "airplanes-diagnostics.timer" "airplanes-config-sync.timer")"
    AIRPLANES_BUILD_MODE=0 run airplanes_runtime_start_enabled_activators "$manifest"
    # The helper returns 0 — health gate already validated the release;
    # activator failure is not a rollback trigger.
    [ "$status" -eq 0 ]
    # The failing call was attempted (logged to the shim) AND emitted a
    # WARN line to stderr.
    grep -Fx 'start airplanes-diagnostics.timer' "$SYSCTL_LOG"
    [[ "$output" == *"WARN: start_activators: airplanes-diagnostics.timer: start failed"* ]]
    # And the non-failing peer still got started.
    grep -Fx 'start airplanes-config-sync.timer' "$SYSCTL_LOG"
    unset SHIM_FAIL_PATTERN
}

@test "start_activators is a no-op in build mode" {
    local manifest
    manifest="$(_write_manifest "$WORK/manifest.json" \
        "airplanes-diagnostics.timer")"
    AIRPLANES_BUILD_MODE=1 run airplanes_runtime_start_enabled_activators "$manifest"
    [ "$status" -eq 0 ]
    # Build mode short-circuits before any systemctl call.
    run grep -Fx 'start airplanes-diagnostics.timer' "$SYSCTL_LOG"
    [ "$status" -ne 0 ]
}

# -- integration through finalize ------------------------------------------

@test "finalize_after_health_passed drives start_activators for the new release manifest" {
    # Stage a target_root with a state file pointing at a `new_release`
    # whose manifest carries timers in .systemd.enable. Then call finalize
    # and assert systemctl saw `start <timer>` for each — proves the
    # finalize wiring AND that `$new/manifest.json` is the manifest path
    # the helper consumes (a wrong path here lets the unit-level cases
    # above pass while the state-machine self-update path silently misses
    # the start pass).
    local target_root
    target_root="$(mk_target_root "$WORK")"

    local new_dir
    new_dir="$(mk_target_release "$target_root" "0.0.2")"
    # Overwrite the minimal manifest with one whose enable list carries
    # timers we can grep for in the shim log.
    cat > "$new_dir/manifest.json" <<'JSON'
{
    "manifest_schema_version": 1,
    "installer_min_version": "1.0.0",
    "version": "0.0.2",
    "channel": "stable",
    "commit_sha": "0000000000000000000000000000000000000000",
    "build_date": "2026-05-28T00:00:00Z",
    "arches": ["arm64"],
    "components": { "readsb_wiedehopf": "0000000" },
    "managed_paths": [],
    "mutable_paths": [],
    "systemd": {
        "enable": [
            "readsb.service",
            "airplanes-diagnostics.timer",
            "airplanes-config-sync.timer"
        ],
        "daemon_reload": true
    },
    "migrations": []
}
JSON

    mk_state_file "$target_root" "HEALTH_PASSED" \
        "new_release=$new_dir"

    # Stage a `current` symlink so the runtime-manifest symlink
    # record_runtime_manifest writes points at a realistic post-flip release.
    ln -s "/opt/airplanes-runtime/releases/v0.0.2" \
        "$target_root/opt/airplanes-runtime/current"

    AIRPLANES_BUILD_MODE=0 run airplanes_runtime_finalize_after_health_passed "$target_root"
    [ "$status" -eq 0 ]

    # Timers were started post-finalize.
    grep -Fx 'start airplanes-diagnostics.timer' "$SYSCTL_LOG"
    grep -Fx 'start airplanes-config-sync.timer' "$SYSCTL_LOG"
    # The .service entry was NOT.
    run grep -Fx 'start readsb.service' "$SYSCTL_LOG"
    [ "$status" -ne 0 ]
}

@test "run_install_steps wires start_activators after run_health_gates" {
    # Static pin on the second runtime callsite. A behavioural end-to-end
    # test through run_install_steps would have to stub backup, migrations,
    # flip_current, managed_paths, decoder relink, health gates, GC — every
    # one of which has its own dedicated coverage elsewhere. What this
    # change actually pins is "the call is inserted at the right position in
    # the sequence", which is a static-text invariant. The upgrade boot-
    # smoke job exercises the dynamic side end-to-end. Asserting the call
    # appears between run_health_gates and gc_old_releases inside the
    # function body catches a future patch deleting or relocating it.
    local body
    body="$(awk '
        /^airplanes_runtime_run_install_steps\(\)/ { in_fn = 1 }
        in_fn { print }
        in_fn && /^}$/ { exit }
    ' "$LIB_PATH")"
    [[ -n "$body" ]] || { echo "could not extract run_install_steps body" >&2; return 1; }
    # The sequence below pins the call between the two anchors. Adjusting
    # the order or dropping the line will fail this test.
    [[ "$body" == *"run_health_gates"*"start_enabled_activators"*"gc_old_releases"* ]] \
        || { echo "run_install_steps no longer calls start_enabled_activators between run_health_gates and gc_old_releases" >&2
             printf '%s\n' "$body" >&2
             return 1; }
}
