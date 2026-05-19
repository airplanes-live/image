# shellcheck shell=bash
# component-pins.sh — pure library, source me, do not execute.
#
# Loads the component pin variables (AIRPLANES_*_REPO / AIRPLANES_*_BRANCH)
# for a given runtime overlay release channel from the channel-specific
# config file that lives alongside this library (runtime-overlay/config-dev,
# runtime-overlay/config-stable). The config files themselves are introduced
# in a later change in this series; this library defines the contract and
# the resolution rule so callers can wire against a stable name now.
#
# The function prints `KEY=VALUE` pairs on stdout, one per line, in the exact
# form `KEY='quoted-value'` so consumers can `eval` the output safely. Only
# variables whose names start with `AIRPLANES_` are emitted; everything else
# the config file might define is filtered out.
#
# Usage from a caller:
#
#   . "${_self_dir}/lib/component-pins.sh"
#   eval "$(airplanes_runtime_load_component_pins stable)"
#
# Tests rely on this contract — see test/runtime-overlay/test_build_release_layout.bats
# which uses a temporary config file in $BATS_TEST_TMPDIR and overrides the
# overlay root via AIRPLANES_RUNTIME_OVERLAY_DIR.

# airplanes_runtime_load_component_pins <channel>
#
# Resolution:
#   1. If $AIRPLANES_RUNTIME_OVERLAY_DIR is set, look up
#      "$AIRPLANES_RUNTIME_OVERLAY_DIR/config-<channel>".
#   2. Else, derive the overlay root from the directory containing this
#      library (.../runtime-overlay/scripts/lib → .../runtime-overlay) and
#      look up "config-<channel>" there.
#
# Exit codes:
#   0 — config sourced and pins printed (zero or more lines)
#   1 — config file missing or sourcing failed
#   2 — bad argument (missing or invalid channel name)
airplanes_runtime_load_component_pins() {
    if [[ $# -ne 1 ]]; then
        echo "airplanes_runtime_load_component_pins: expected 1 arg (channel), got $#" >&2
        return 2
    fi

    local channel="$1"
    case "$channel" in
        stable|dev) ;;
        *)
            echo "airplanes_runtime_load_component_pins: invalid channel: $channel (want stable|dev)" >&2
            return 2
            ;;
    esac

    local overlay_dir
    if [[ -n "${AIRPLANES_RUNTIME_OVERLAY_DIR:-}" ]]; then
        overlay_dir="$AIRPLANES_RUNTIME_OVERLAY_DIR"
    else
        # ${BASH_SOURCE[0]} is the path of this file as sourced.
        local _lib_dir
        _lib_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
        # _lib_dir is runtime-overlay/scripts/lib; overlay root is two levels up.
        overlay_dir="$(cd "$_lib_dir/../.." && pwd)"
    fi

    local config_path="$overlay_dir/config-$channel"
    if [[ ! -f "$config_path" ]]; then
        echo "airplanes_runtime_load_component_pins: config not found: $config_path" >&2
        return 1
    fi

    # Source in a subshell so the caller's environment is not polluted.
    # Snapshot the AIRPLANES_* variable names visible BEFORE sourcing so a
    # stray AIRPLANES_* var the caller already exported (e.g. the function's
    # own AIRPLANES_RUNTIME_OVERLAY_DIR resolution hook, CI runner env) does
    # not get echoed back as if it were a component pin defined by the
    # config. Only names introduced by the sourced file survive the diff,
    # and we further restrict the output to names matching the documented
    # AIRPLANES_*_REPO / AIRPLANES_*_BRANCH shape so a typo in the config
    # surfaces visibly instead of being silently emitted as a pseudo-pin.
    (
        # Snapshot pre-source state.
        local pre
        pre="$(compgen -v | grep -E '^AIRPLANES_' || true)"

        # shellcheck disable=SC1090
        . "$config_path" || exit 1

        # Names visible post-source minus the pre-existing ones.
        local post
        post="$(compgen -v | grep -E '^AIRPLANES_' || true)"
        local introduced
        introduced="$(LC_ALL=C comm -13 \
            <(printf '%s\n' "$pre"  | LC_ALL=C sort -u) \
            <(printf '%s\n' "$post" | LC_ALL=C sort -u))"

        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            case "$name" in
                AIRPLANES_*_REPO|AIRPLANES_*_BRANCH) ;;
                *)
                    echo "airplanes_runtime_load_component_pins: ignoring config variable with unrecognised shape: $name" >&2
                    continue
                    ;;
            esac
            local value="${!name-}"
            # Escape single quotes in value: ' → '\''
            local esc="${value//\'/\'\\\'\'}"
            printf "%s='%s'\n" "$name" "$esc"
        done <<<"$introduced"
    ) || return 1
}
