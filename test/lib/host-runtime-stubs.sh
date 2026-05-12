# shellcheck shell=bash
#
# test/lib/host-runtime-stubs.sh
#
# Bash function stubs that intercept the few OS commands the production
# scripts call which would mutate the test host if left unstubbed. The
# canonical example is `hostnamectl set-hostname` in
# stage-airplanes/06-firstboot/files/usr/local/sbin/airplanes-first-run —
# the bats tests redirect /etc/hostname / /etc/hosts to temp files, but
# the script also calls `hostnamectl` (via D-Bus to systemd-hostnamed) and
# `hostname` (the BSD-style binary) unconditionally to apply the change
# for the running session. Without these stubs, `bats test/` literally
# changes the developer's machine hostname.
#
# Sourced from the `setup()` block of affected test files BEFORE
# `source "$SCRIPT"` so the script's `command -v` checks pick up these
# functions ahead of the real binaries.
#
# Each stub records its argv into an array so tests can assert on what
# the script tried to do. Call `reset_host_runtime_stubs` from `setup()`
# to zero the arrays between tests.

reset_host_runtime_stubs() {
    HOSTNAMECTL_CALLS=()
    HOSTNAME_CALLS=()
    RASPI_CONFIG_CALLS=()
}

hostnamectl() {
    HOSTNAMECTL_CALLS+=("$*")
    return 0
}

hostname() {
    # The production script only ever invokes `hostname "$raw"` (one
    # positional arg). The argless `$(hostname)` read-current path isn't
    # used, but other tests in this tree might do it indirectly — return
    # an empty string in that case rather than silently capturing nothing.
    if (( $# == 0 )); then
        printf ''
        return 0
    fi
    HOSTNAME_CALLS+=("$*")
    return 0
}

# Bash function names accept hyphens, so we can intercept `raspi-config`
# the same way as the other commands. apply_wifi_country invokes
# `raspi-config nonint do_wifi_country "$_WIFI_COUNTRY"`; without this
# stub the test would either reach the host's raspi-config (Raspberry Pi
# devboxes) or fall through to the production script's fallback that
# writes directly to /etc/wpa_supplicant/wpa_supplicant.conf on the host.
# shellcheck disable=SC1003,SC2317  # function-name hyphen is intentional
raspi-config() {
    RASPI_CONFIG_CALLS+=("$*")
    return 0
}

export -f hostnamectl hostname raspi-config

reset_host_runtime_stubs
