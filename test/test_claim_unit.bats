#!/usr/bin/env bats

# Static lint of airplanes-claim.service.
#
# The unit now intentionally depends on network-online.target so the first
# claim attempt waits for usable DNS instead of failing at curl rc=6 and
# parking in `failed` state (which the timer's OnUnitActiveSec=5min doesn't
# re-arm cleanly from). On this image NetworkManager-wait-online is already
# pulled into boot by other services, so the marginal boot cost is zero;
# on a network-less Pi the target's wait-online consumer times out (default
# 60s) and Wants= ensures we still run afterwards.
#
# Pairs with airplanes-live/feed's claim.sh returning 75 (EX_TEMPFAIL) on
# curl rc 6/7/28, plus SuccessExitStatus=75 here, so a transient failure
# keeps the unit out of `failed` state.

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

@test "After= includes airplanes-first-run.service" {
    # Preserves first-run → claim ordering: the feeder-id must land on disk
    # before `apl-feed claim register` runs.
    val="$(unit_get After)"
    [[ "$val" == *"airplanes-first-run.service"* ]]
}

@test "After= includes network-online.target" {
    # Defer the first attempt until DNS is reachable; without this the
    # timer fires at boot+30s, curl rc=6 fails the unit, and the 5min
    # retry doesn't re-arm cleanly from `failed` state.
    val="$(unit_get After)"
    [[ "$val" == *"network-online.target"* ]]
}

@test "Wants= includes network-online.target" {
    # After= is ordering-only; without Wants= the target wouldn't be
    # pulled into the timer-triggered transaction and the ordering would
    # silently no-op.
    val="$(unit_get Wants)"
    [[ "$val" == *"network-online.target"* ]]
}

@test "SuccessExitStatus=75 (EX_TEMPFAIL) keeps unit out of failed state" {
    # Paired with feed's claim_register returning 75 on transient curl
    # failures (rc 6/7/28). Without this the timer's OnUnitActiveSec=5min
    # doesn't re-arm cleanly after a failed run.
    val="$(unit_get SuccessExitStatus)"
    [[ "$val" == *"75"* ]]
}
