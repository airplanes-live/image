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

    # Source in a subshell so the caller's environment is not polluted; print
    # only AIRPLANES_* variables back to stdout. `set -a` would also auto-export,
    # but we explicitly list them so a stray non-AIRPLANES_ variable in the
    # config can never leak. The single-quote escaping mirrors `bash declare -p`'s
    # behavior for arbitrary string values.
    (
        # shellcheck disable=SC1090
        . "$config_path" || exit 1
        # Iterate the variables defined in this shell. compgen prints names.
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            local value="${!name-}"
            # Escape single quotes in value: ' → '\''
            local esc="${value//\'/\'\\\'\'}"
            printf "%s='%s'\n" "$name" "$esc"
        done < <(compgen -v | grep -E '^AIRPLANES_' || true)
    ) || return 1
}
