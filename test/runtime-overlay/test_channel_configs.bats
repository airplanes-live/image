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
    LOADER="$REPO_ROOT/runtime-overlay/scripts/lib/component-pins.sh"

    # Hard-fail (not skip) — these files are the subject of this suite.
    # A missing file should be a CI red, not a silent skipped test.
    [ -f "$STABLE" ] || { echo "config-stable missing: $STABLE" >&2; return 1; }
    [ -f "$DEV" ]    || { echo "config-dev missing: $DEV"       >&2; return 1; }
    [ -f "$LOADER" ] || { echo "component-pins.sh missing: $LOADER" >&2; return 1; }

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

# Round-trip the file through A-3b's loader and assert the emitted key set
# is EXACTLY the ten expected names — guards against:
#   - a typo in the config adding a stray pseudo-pin;
#   - a future helper edit relaxing the AIRPLANES_*_REPO|_BRANCH filter;
#   - silent shape drift between this file and the loader's contract.
@test "loader emits exactly the expected 10 pin keys for both channels" {
    for channel in stable dev; do
        run env -u AIRPLANES_RUNTIME_OVERLAY_DIR bash -c \
            ". \"$LOADER\" && airplanes_runtime_load_component_pins $channel"
        [ "$status" -eq 0 ]

        # Build the expected key list.
        local expected=""
        for c in "${COMPONENTS[@]}"; do
            expected+="${c}_BRANCH"$'\n'"${c}_REPO"$'\n'
        done
        expected="$(printf '%s' "$expected" | LC_ALL=C sort -u)"

        # Extract just the key names from the loader output (lines look like
        # `KEY='value'`). The loader writes warnings to stderr; `run` only
        # captures stdout into $output, so a stray-shape warning would not
        # contaminate the comparison.
        local got
        got="$(printf '%s\n' "$output" | sed -n "s/^\\([A-Z0-9_]\\+\\)=.*/\\1/p" | LC_ALL=C sort -u)"

        if [ "$got" != "$expected" ]; then
            echo "channel=$channel: loader key set drifted" >&2
            echo "expected:" >&2; printf '%s\n' "$expected" >&2
            echo "got:"      >&2; printf '%s\n' "$got"      >&2
            return 1
        fi
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
