#!/usr/bin/env bats

# Static lint of airplanes-grant-sudo.service. Asserts sandbox directives
# stay aligned with what the script actually writes. Mirrors
# test_first_run_unit.bats — the cautionary tale here is the
# ProtectSystem=full trap that previously hid feeder-id silent failures
# in airplanes-first-run.service before commit 21b7100. systemd-analyze
# verify can't catch that class of bug because it doesn't simulate
# namespace re-mounts; this static lint is the cheapest guard against
# regression.

setup() {
    UNIT="$BATS_TEST_DIRNAME/../stage-airplanes/06c-grant-sudo/files/etc/systemd/system/airplanes-grant-sudo.service"
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06c-grant-sudo/files/usr/local/sbin/airplanes-grant-sudo"
    [ -f "$UNIT" ] || skip "unit file missing"
}

unit_get() {
    local key="$1"
    grep -E "^${key}=" "$UNIT" | tail -n1 | sed -E "s/^${key}=//"
}

# ---- sandbox directives ---------------------------------------------------

@test "ProtectSystem=true (NOT full or strict)" {
    # full would re-mount /etc read-only and silently break writes to
    # /etc/sudoers.d/. This is the exact trap airplanes-first-run hit
    # before commit 21b7100 — we are deliberately not repeating it.
    [ "$(unit_get ProtectSystem)" = "true" ]
}

@test "no CapabilityBoundingSet restriction (visudo needs DAC)" {
    # Empty bounding set would break visudo's ability to write/check
    # /etc/sudoers.d/ temp files. We leave caps intact for this unit
    # (airplanes-first-run can use an empty bounding set because hostnamectl
    # does the privileged work over D-Bus; we have no equivalent proxy).
    ! grep -qE '^CapabilityBoundingSet=' "$UNIT"
}

@test "no ReadOnlyPaths covering /etc/sudoers.d" {
    # Future-proofing against a "tighten the sandbox" commit accidentally
    # locking out the write path.
    ! grep -qE '^ReadOnlyPaths=.*sudoers' "$UNIT"
}

@test "PrivateNetwork=yes (no network needed for sudoers writes)" {
    [ "$(unit_get PrivateNetwork)" = "yes" ]
}

# ---- unit-type / lifecycle ------------------------------------------------

@test "Type=oneshot with RemainAfterExit=yes" {
    [ "$(unit_get Type)" = "oneshot" ]
    [ "$(unit_get RemainAfterExit)" = "yes" ]
}

@test "ConditionPathExists gates re-run on the success marker" {
    val="$(unit_get ConditionPathExists)"
    [ "$val" = "!/var/lib/airplanes/grant-sudo-done" ]
}

@test "WantedBy=multi-user.target" {
    [ "$(unit_get WantedBy)" = "multi-user.target" ]
}

# ---- ordering -------------------------------------------------------------

@test "After= includes cloud-final.service" {
    val="$(unit_get After)"
    [[ "$val" == *"cloud-final.service"* ]]
}

@test "Wants= includes cloud-final.service" {
    # Wants=, not Requires=: if cloud-final fails for any reason we still
    # want our oneshot to attempt the grant (e.g. against a pi-gen-baked
    # human account on an image flashed without rpi-imager customisation).
    val="$(unit_get Wants)"
    [[ "$val" == *"cloud-final.service"* ]]
}

# ---- script ↔ unit consistency -------------------------------------------

@test "ExecStart matches the installed script path" {
    [ "$(unit_get ExecStart)" = "/usr/local/sbin/airplanes-grant-sudo" ]
}

@test "marker path in unit matches the script's DONE_MARKER default" {
    [ -f "$SCRIPT" ] || skip "script missing"
    # The script's `DONE_MARKER="${DONE_MARKER:-/var/lib/airplanes/grant-sudo-done}"`
    # must match the unit's ConditionPathExists path — otherwise re-runs
    # are not actually gated.
    script_default="$(grep -E '^DONE_MARKER=' "$SCRIPT" | head -n1 | sed -E 's/.*\{DONE_MARKER:-([^}]+)\}.*/\1/')"
    [ "$script_default" = "/var/lib/airplanes/grant-sudo-done" ]
    val="$(unit_get ConditionPathExists)"
    [ "$val" = "!$script_default" ]
}
