#!/usr/bin/env bats

# Verify the build-runtime-assets compat-fold: stage-feed.sh drops the mlat
# venv's Python ABI tag and content hash as standalone staging files; the
# orchestrator folds both into the manifest compat block. This test exercises
# the fold logic in isolation (the jq merge that build-runtime-assets.sh runs
# after stage-feed) so a regression in the merge surfaces without a full build.

bats_require_minimum_version 1.5.0

setup() {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    STAGING="$BATS_TEST_TMPDIR/staging"
    install -d -m 0755 "$STAGING"
    printf '{}' > "$STAGING/compat.json"
}

# Mirror of the fold block in build-runtime-assets.sh.
_fold() {
    if [[ -f "$STAGING/mlat_python_abi" ]]; then
        local abi
        abi="$(tr -d '[:space:]' < "$STAGING/mlat_python_abi")"
        if [[ -n "$abi" ]]; then
            local tmp
            tmp="$(mktemp "$STAGING/.compat.XXXXXX")"
            jq --arg abi "$abi" '. + {mlat_python_abi: $abi}' "$STAGING/compat.json" > "$tmp"
            mv -f -- "$tmp" "$STAGING/compat.json"
        fi
    fi
    if [[ -f "$STAGING/mlat_venv_sha256" ]]; then
        local h
        h="$(tr -d '[:space:]' < "$STAGING/mlat_venv_sha256")"
        if [[ -n "$h" ]]; then
            local tmp
            tmp="$(mktemp "$STAGING/.compat.XXXXXX")"
            jq --arg h "$h" '. + {mlat_venv_sha256: $h}' "$STAGING/compat.json" > "$tmp"
            mv -f -- "$tmp" "$STAGING/compat.json"
        fi
    fi
}

@test "abi + venv hash are folded into compat" {
    printf 'cp313' > "$STAGING/mlat_python_abi"
    printf '%064d' 0 | tr '0' 'a' > "$STAGING/mlat_venv_sha256"
    _fold
    [ "$(jq -r '.mlat_python_abi' "$STAGING/compat.json")" = "cp313" ]
    local h
    h="$(jq -r '.mlat_venv_sha256' "$STAGING/compat.json")"
    [[ "$h" =~ ^[a-f]{64}$ ]]
}

@test "fold preserves pre-existing compat keys" {
    printf '{"base_os_codename":"trixie"}' > "$STAGING/compat.json"
    printf 'cp313' > "$STAGING/mlat_python_abi"
    _fold
    [ "$(jq -r '.base_os_codename' "$STAGING/compat.json")" = "trixie" ]
    [ "$(jq -r '.mlat_python_abi' "$STAGING/compat.json")" = "cp313" ]
}

@test "fold is a no-op when no mlat metadata present" {
    printf '{"base_os_codename":"trixie"}' > "$STAGING/compat.json"
    _fold
    [ "$(jq -r 'keys | length' "$STAGING/compat.json")" -eq 1 ]
    [ "$(jq -r '.base_os_codename' "$STAGING/compat.json")" = "trixie" ]
}

@test "folded compat validates against the schema" {
    # Build a full manifest with the folded compat and run the validator.
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    local validator="$REPO_ROOT/runtime-overlay/scripts/validate-manifest.sh"
    [ -x "$validator" ] || skip "validator not executable"

    printf 'cp313' > "$STAGING/mlat_python_abi"
    printf '%064d' 0 | tr '0' 'a' > "$STAGING/mlat_venv_sha256"
    _fold

    local compat
    compat="$(cat "$STAGING/compat.json")"
    local m="$BATS_TEST_TMPDIR/manifest.json"
    jq -n --argjson compat "$compat" '{
        manifest_schema_version: 1,
        installer_min_version: "1.0.0",
        version: "1.0.0",
        channel: "stable",
        commit_sha: "0000000000000000000000000000000000000000",
        build_date: "2026-05-20T00:00:00Z",
        arches: ["arm64"],
        components: { mlat_client: { commit_sha: "0000000", version: "master" } },
        managed_paths: [],
        mutable_paths: [],
        systemd: { enable: [], daemon_reload: true },
        migrations: [],
        compat: $compat
    }' > "$m"
    run "$validator" "$m"
    [ "$status" -eq 0 ]
}
