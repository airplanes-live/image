#!/usr/bin/env bats

# Pin the symmetry between airplanes-*.{service,timer} files shipped from the
# airplanes-live/feed repo and the runtime-overlay manifest inputs that lay
# them down on the image.
#
# The historical defect this guards: stage-feed.sh and the manifest inputs
# hand-listed a closed allowlist of feed unit names. When feed added
# airplanes-diagnostics.{service,timer} and airplanes-config-sync.{service,timer},
# the overlay silently dropped both pairs and no test caught the gap until a
# claimed feeder's dashboard sat permanently "Offline · Waiting for next
# diagnostics push". Now stage-feed.sh globs feed/scripts/airplanes-*.{service,timer}
# at staging time, so a future unit added to feed lands on the image automatically;
# this test pins the matching manifest-input rows so the symlinks and
# enable-list keep up.
#
# Enable-list invariant uses the unit's `[Install]` section presence: a unit
# that declares an install target (timer wired into timers.target, or a
# long-running daemon with WantedBy=multi-user.target) must be in
# systemd.json enable. Oneshot units triggered solely via their timer's
# `Unit=` directive carry no `[Install]` and must NOT be in enable — they're
# activated by the timer firing. This shape catches a future feed
# `airplanes-foo.service` that ships with `[Install]` and would otherwise be
# silently skipped on the image.
#
# Requires a feed checkout. CI's shell-tests job sets AIRPLANES_FEED_SRC; for
# local runs, place a feed checkout at ../feed relative to this repo (matches
# the apl-workspace layout). The test skips cleanly when neither is available;
# a populated checkout that yields zero matching units is treated as structural
# breakage and fails.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    MANAGED_PATHS_JSON="$REPO_ROOT/runtime-overlay/manifest-inputs/managed_paths.json"
    SYSTEMD_JSON="$REPO_ROOT/runtime-overlay/manifest-inputs/systemd.json"

    if [[ -n "${AIRPLANES_FEED_SRC:-}" ]]; then
        # Explicit env var — a missing scripts/ dir is a CI-config or checkout
        # bug, not a "no feed available" condition. Fail hard so the invariant
        # cannot be silently bypassed by a path typo.
        FEED_SRC="$AIRPLANES_FEED_SRC"
        [[ -d "$FEED_SRC/scripts" ]] \
            || { echo "AIRPLANES_FEED_SRC set but does not contain scripts/: $FEED_SRC" >&2; return 1; }
    elif [[ -d "$REPO_ROOT/../feed/scripts" ]]; then
        FEED_SRC="$(cd "$REPO_ROOT/../feed" && pwd)"
    else
        skip "no feed checkout available (set AIRPLANES_FEED_SRC or place a sibling feed/)"
    fi

    command -v jq >/dev/null 2>&1 || skip "jq not installed"
}

# Collect every airplanes-*.service / airplanes-*.timer file feed ships from
# scripts/, sorted under LC_ALL=C for reproducibility. Empty result inside a
# populated checkout is structural breakage — callers fail rather than skip.
_feed_units() {
    local f
    shopt -s nullglob
    local -a units=("$FEED_SRC"/scripts/airplanes-*.service "$FEED_SRC"/scripts/airplanes-*.timer)
    shopt -u nullglob
    if (( ${#units[@]} == 0 )); then
        return 1
    fi
    for f in "${units[@]}"; do
        basename "$f"
    done | LC_ALL=C sort
}

# A unit "needs enabling" iff it carries an [Install] section that wires it
# into a target at boot. Oneshot timer-driven services carry no [Install] —
# the timer's `Unit=` directive activates them — and must stay out of the
# enable list. Tolerate leading whitespace on the section header (systemd
# accepts ` [Install]`); inline trailing content after the header is invalid
# per systemd.unit(5) so we don't need to match it.
_unit_needs_enable() {
    local unit_file="$1"
    grep -qE '^[[:space:]]*\[Install\][[:space:]]*$' "$unit_file"
}

@test "every feed airplanes-*.{service,timer} is symlinked by managed_paths.json" {
    local units_out
    units_out="$(_feed_units)" \
        || { echo "no airplanes-*.{service,timer} in $FEED_SRC/scripts/ — feed restructure?" >&2; return 1; }
    mapfile -t units <<< "$units_out"

    local missing=()
    local unit expected_link expected_target
    for unit in "${units[@]}"; do
        expected_link="/etc/systemd/system/$unit"
        expected_target="/opt/airplanes-runtime/current/systemd/$unit"
        if ! jq -e --arg link "$expected_link" --arg target "$expected_target" '
            any(.[]; .mode == "symlink" and .link == $link and .target == $target)
        ' "$MANAGED_PATHS_JSON" >/dev/null; then
            missing+=("$unit")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        printf 'managed_paths.json missing symlink for feed unit: %s\n' "${missing[@]}" >&2
        echo "expected entry shape:" >&2
        echo '  { "mode": "symlink", "link": "/etc/systemd/system/<unit>", "target": "/opt/airplanes-runtime/current/systemd/<unit>" }' >&2
        return 1
    fi
}

@test "systemd.json enable matches feed units with [Install] sections" {
    local units_out
    units_out="$(_feed_units)" \
        || { echo "no airplanes-*.{service,timer} in $FEED_SRC/scripts/ — feed restructure?" >&2; return 1; }
    mapfile -t units <<< "$units_out"

    local missing=() unexpected=()
    local unit
    for unit in "${units[@]}"; do
        local needs_enable=false
        if _unit_needs_enable "$FEED_SRC/scripts/$unit"; then
            needs_enable=true
        fi
        local in_enable=false
        if jq -e --arg name "$unit" '.enable | index($name)' "$SYSTEMD_JSON" >/dev/null; then
            in_enable=true
        fi

        if $needs_enable && ! $in_enable; then
            missing+=("$unit")
        elif ! $needs_enable && $in_enable; then
            unexpected+=("$unit")
        fi
    done

    local fail=0
    if (( ${#missing[@]} > 0 )); then
        printf 'systemd.json enable is missing feed unit with [Install]: %s\n' "${missing[@]}" >&2
        fail=1
    fi
    if (( ${#unexpected[@]} > 0 )); then
        printf 'systemd.json enable lists feed unit without [Install]: %s\n' "${unexpected[@]}" >&2
        echo "(oneshot units triggered by a timer must not be enabled directly)" >&2
        fail=1
    fi
    return "$fail"
}
