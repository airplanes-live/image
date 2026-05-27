#!/usr/bin/env bats

# Tests for the extended compat preflight: manifest_schema_version floor,
# installer_min_version floor, base_os_codename mismatch rejection, and
# free-space check.

bats_require_minimum_version 1.5.0

load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
}

# Helper: write a manifest with the given schema version, installer min, and
# optional compat object.
mk_manifest_with_floor() {
    local dir="$1" schema_ver="$2" installer_min="$3"
    shift 3
    # Remaining args are key=value for the compat block.
    local compat_json="{}"
    if [[ $# -gt 0 ]]; then
        compat_json="{"
        local first=1
        for kv in "$@"; do
            local k="${kv%%=*}" v="${kv#*=}"
            [[ $first -eq 0 ]] && compat_json="$compat_json,"
            compat_json="$compat_json \"$k\": \"$v\""
            first=0
        done
        compat_json="$compat_json }"
    fi
    cat > "$dir/manifest.json" <<JSON
{
    "manifest_schema_version": $schema_ver,
    "installer_min_version": "$installer_min",
    "version": "1.0.0",
    "channel": "stable",
    "commit_sha": "0000000000000000000000000000000000000000",
    "build_date": "2026-05-20T00:00:00Z",
    "arches": ["arm64"],
    "components": { "readsb_wiedehopf": "0000000" },
    "managed_paths": [],
    "mutable_paths": [],
    "systemd": { "enable": [], "daemon_reload": true },
    "migrations": [],
    "compat": $compat_json
}
JSON
    printf '%s/manifest.json' "$dir"
}

# ---------------------------------------------------------------------------
# Schema version floor
# ---------------------------------------------------------------------------
@test "preflight: passes when manifest_schema_version matches updater" {
    local d="$BATS_TEST_TMPDIR/rel"
    install -d "$d"
    local m
    m="$(mk_manifest_with_floor "$d" 1 "1.0.0")"
    run airplanes_runtime_run_compat_preflight "$m" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}

@test "preflight: rejects manifest_schema_version higher than updater" {
    local d="$BATS_TEST_TMPDIR/rel"
    install -d "$d"
    local m
    m="$(mk_manifest_with_floor "$d" 99 "1.0.0")"
    run airplanes_runtime_run_compat_preflight "$m" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"manifest_schema_version=99"* ]]
}

# ---------------------------------------------------------------------------
# Installer min version floor
# ---------------------------------------------------------------------------
@test "preflight: passes when installer version meets floor" {
    local d="$BATS_TEST_TMPDIR/rel"
    install -d "$d"
    local m
    m="$(mk_manifest_with_floor "$d" 1 "1.0.0")"
    AIRPLANES_RUNTIME_INSTALLER_VERSION="1.0.0" \
        run airplanes_runtime_run_compat_preflight "$m" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}

@test "preflight: rejects installer version below floor" {
    local d="$BATS_TEST_TMPDIR/rel"
    install -d "$d"
    local m
    m="$(mk_manifest_with_floor "$d" 1 "2.0.0")"
    AIRPLANES_RUNTIME_INSTALLER_VERSION="1.0.0" \
        run airplanes_runtime_run_compat_preflight "$m" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"updater >= 2.0.0"* ]]
}

# ---------------------------------------------------------------------------
# Base-OS codename
# ---------------------------------------------------------------------------
@test "preflight: passes when base_os_codename matches" {
    local d="$BATS_TEST_TMPDIR/rel"
    install -d "$d"
    local m
    m="$(mk_manifest_with_floor "$d" 1 "1.0.0" "base_os_codename=fakecodename")"
    # Inject the codename into the target root's os-release.
    install -d -m 755 "$TARGET_ROOT/etc"
    printf 'VERSION_CODENAME=fakecodename\n' > "$TARGET_ROOT/etc/os-release"
    run airplanes_runtime_run_compat_preflight "$m" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}

@test "preflight: rejects wrong base_os_codename" {
    local d="$BATS_TEST_TMPDIR/rel"
    install -d "$d"
    local m
    m="$(mk_manifest_with_floor "$d" 1 "1.0.0" "base_os_codename=trixie")"
    install -d -m 755 "$TARGET_ROOT/etc"
    printf 'VERSION_CODENAME=bookworm\n' > "$TARGET_ROOT/etc/os-release"
    run airplanes_runtime_run_compat_preflight "$m" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"trixie"* ]]
    [[ "$output" == *"bookworm"* ]]
}

# ---------------------------------------------------------------------------
# Free-space check
# ---------------------------------------------------------------------------
@test "preflight: rejects when free space below floor" {
    local d="$BATS_TEST_TMPDIR/rel"
    install -d "$d"
    local m
    m="$(mk_manifest_with_floor "$d" 1 "1.0.0")"
    # Set an impossibly high floor.
    AIRPLANES_RUNTIME_MIN_FREE_BYTES=999999999999999 \
        run airplanes_runtime_run_compat_preflight "$m" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"insufficient free space"* ]]
}

@test "preflight: passes when free space above floor" {
    local d="$BATS_TEST_TMPDIR/rel"
    install -d "$d"
    local m
    m="$(mk_manifest_with_floor "$d" 1 "1.0.0")"
    # Set a trivially low floor.
    AIRPLANES_RUNTIME_MIN_FREE_BYTES=1 \
        run airplanes_runtime_run_compat_preflight "$m" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Python ABI (mlat_python_abi)
# ---------------------------------------------------------------------------

# Stub a python3 at the target root that reports a specific ABI tag.
_stub_python3() {
    local target_root="$1" abi_tag="$2"
    install -d -m 755 "$target_root/usr/bin"
    cat > "$target_root/usr/bin/python3" <<PYEOF
#!/bin/sh
# Stub python3 that emits only the ABI tag.
if [ "\$1" = "-c" ]; then
    echo "$abi_tag"
fi
PYEOF
    chmod 755 "$target_root/usr/bin/python3"
}

@test "preflight: passes when mlat_python_abi matches" {
    local d="$BATS_TEST_TMPDIR/rel"
    install -d "$d"
    local m
    m="$(mk_manifest_with_floor "$d" 1 "1.0.0" "mlat_python_abi=cp313")"
    _stub_python3 "$TARGET_ROOT" "cp313"
    run airplanes_runtime_run_compat_preflight "$m" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}

@test "preflight: rejects wrong mlat_python_abi" {
    local d="$BATS_TEST_TMPDIR/rel"
    install -d "$d"
    local m
    m="$(mk_manifest_with_floor "$d" 1 "1.0.0" "mlat_python_abi=cp313")"
    _stub_python3 "$TARGET_ROOT" "cp312"
    run airplanes_runtime_run_compat_preflight "$m" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cp313"* ]]
    [[ "$output" == *"cp312"* ]]
}

@test "preflight: rejects missing python3 when mlat_python_abi set" {
    local d="$BATS_TEST_TMPDIR/rel"
    install -d "$d"
    local m
    m="$(mk_manifest_with_floor "$d" 1 "1.0.0" "mlat_python_abi=cp313")"
    # No python3 stub — the helper should return empty.
    run airplanes_runtime_run_compat_preflight "$m" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"python3 is not installed"* ]]
}

@test "preflight: skips python abi check when not declared" {
    local d="$BATS_TEST_TMPDIR/rel"
    install -d "$d"
    local m
    m="$(mk_manifest_with_floor "$d" 1 "1.0.0" "base_os_codename=fakecodename")"
    install -d -m 755 "$TARGET_ROOT/etc"
    printf 'VERSION_CODENAME=fakecodename\n' > "$TARGET_ROOT/etc/os-release"
    # No mlat_python_abi in manifest — should pass without python3 present.
    run airplanes_runtime_run_compat_preflight "$m" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}
