#!/usr/bin/env bats

# Tests for runtime-overlay/config-{stable,dev} — channel-pinning shell
# fragments sourced by the runtime-overlay build helpers. Asserts shape
# (5 *_REPO + 5 *_BRANCH vars), pin format per channel (40-hex SHA on
# stable, non-SHA branch ref on dev), HTTPS-only repo URLs, and that the
# `${VAR:-default}` idiom keeps a pre-set value intact when the file is
# sourced.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    STABLE="$REPO_ROOT/runtime-overlay/config-stable"
    DEV="$REPO_ROOT/runtime-overlay/config-dev"

    [ -f "$STABLE" ] || skip "config-stable missing: $STABLE"
    [ -f "$DEV" ]    || skip "config-dev missing: $DEV"

    COMPONENTS=(
        AIRPLANES_READSB_DECODER
        AIRPLANES_DUMP978
        AIRPLANES_TAR1090
        AIRPLANES_TAR1090_DB
        AIRPLANES_GRAPHS1090
    )
}

# Source the named config file in a subshell and emit `KEY=VALUE` lines for
# every AIRPLANES_* variable it introduces. Tests parse the output via
# associative arrays so missing keys surface as an empty value.
load_pins() {
    local file="$1"
    # shellcheck disable=SC1090
    ( . "$file" && \
        for c in "${COMPONENTS[@]}"; do
            repo="${c}_REPO"
            branch="${c}_BRANCH"
            printf '%s=%s\n' "$repo"   "${!repo-}"
            printf '%s=%s\n' "$branch" "${!branch-}"
        done )
}

@test "stable sources cleanly and sets all 10 component vars" {
    run load_pins "$STABLE"
    [ "$status" -eq 0 ]
    for c in "${COMPONENTS[@]}"; do
        [[ "$output" == *"${c}_REPO=https://"* ]]   || { echo "missing ${c}_REPO" >&2; return 1; }
        [[ "$output" == *"${c}_BRANCH="*[0-9a-f]* ]] || { echo "missing ${c}_BRANCH" >&2; return 1; }
    done
}

@test "stable pins are 40-hex SHAs" {
    run load_pins "$STABLE"
    [ "$status" -eq 0 ]
    declare -A vals
    while IFS='=' read -r k v; do
        vals[$k]="$v"
    done <<<"$output"
    for c in "${COMPONENTS[@]}"; do
        local sha="${vals[${c}_BRANCH]-}"
        [[ "$sha" =~ ^[0-9a-f]{40}$ ]] \
            || { echo "${c}_BRANCH is not a 40-hex SHA: '$sha'" >&2; return 1; }
    done
}

@test "dev sources cleanly and sets all 10 component vars" {
    run load_pins "$DEV"
    [ "$status" -eq 0 ]
    for c in "${COMPONENTS[@]}"; do
        [[ "$output" == *"${c}_REPO=https://"* ]] || { echo "missing ${c}_REPO" >&2; return 1; }
        [[ "$output" == *"${c}_BRANCH="*       ]] || { echo "missing ${c}_BRANCH" >&2; return 1; }
    done
}

@test "dev branches are non-SHA refs" {
    run load_pins "$DEV"
    [ "$status" -eq 0 ]
    declare -A vals
    while IFS='=' read -r k v; do
        vals[$k]="$v"
    done <<<"$output"
    for c in "${COMPONENTS[@]}"; do
        local ref="${vals[${c}_BRANCH]-}"
        [ -n "$ref" ] || { echo "${c}_BRANCH is empty" >&2; return 1; }
        if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
            echo "${c}_BRANCH on dev unexpectedly pinned to a SHA: '$ref'" >&2
            return 1
        fi
    done
}

@test "repo URLs use HTTPS on github.com" {
    for file in "$STABLE" "$DEV"; do
        run load_pins "$file"
        [ "$status" -eq 0 ]
        declare -A vals=()
        while IFS='=' read -r k v; do
            vals[$k]="$v"
        done <<<"$output"
        for c in "${COMPONENTS[@]}"; do
            local repo="${vals[${c}_REPO]-}"
            [[ "$repo" == https://github.com/* ]] \
                || { echo "$file: ${c}_REPO not HTTPS github.com: '$repo'" >&2; return 1; }
        done
    done
}

@test "stable honours a pre-set AIRPLANES_READSB_DECODER_BRANCH override" {
    AIRPLANES_READSB_DECODER_BRANCH=foo run bash -c \
        ". \"$STABLE\" && printf '%s' \"\$AIRPLANES_READSB_DECODER_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "foo" ]
}

@test "dev honours a pre-set AIRPLANES_READSB_DECODER_BRANCH override" {
    AIRPLANES_READSB_DECODER_BRANCH=foo run bash -c \
        ". \"$DEV\" && printf '%s' \"\$AIRPLANES_READSB_DECODER_BRANCH\""
    [ "$status" -eq 0 ]
    [ "$output" = "foo" ]
}
