#!/usr/bin/env bats

# Static lint of airplanes-claim.service. Guards against re-introducing the
# network-online.target gate: pulling network-online activates
# NetworkManager-wait-online and stalls first boot for ~90s when WiFi hasn't
# associated. The timer's 5 min retry plus the claim cmd's fast-fail on
# no-network (curl rc=6/7/28) makes a hard gate on network-online buy nothing
# at the cost of first-boot UX.

setup() {
    UNIT="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/etc/systemd/system/airplanes-claim.service"
    [ -f "$UNIT" ] || skip "unit file missing"
}

# Returns the value of a directive (after the '=', whitespace trimmed). Last
# occurrence wins, mirroring systemd semantics.
unit_get() {
    local key="$1"
    grep -E "^${key}=" "$UNIT" | tail -n1 | sed -E "s/^${key}=//"
}

@test "no directive references network-online (boot-time stall regression)" {
    # Exclude comment and blank lines so a comment that explains the choice
    # doesn't trip the regression guard.
    ! grep -vE '^\s*(#|$)' "$UNIT" | grep -qE 'network-online'
}

@test "After= includes airplanes-first-run.service" {
    # Preserves first-run → claim ordering: the feeder-id must land on disk
    # before `apl-feed claim register` runs.
    val="$(unit_get After)"
    [[ "$val" == *"airplanes-first-run.service"* ]]
}

@test "After= includes NetworkManager.service" {
    # Soft ordering: wait for the NM daemon to be ready, not for any
    # connection to activate. Mostly a no-op once multi-user.target is
    # reached, but documents the preferred order if NM is restarting when
    # the timer fires.
    val="$(unit_get After)"
    [[ "$val" == *"NetworkManager.service"* ]]
}
