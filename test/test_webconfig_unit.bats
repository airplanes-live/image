#!/usr/bin/env bats

# Static lint of airplanes-webconfig.service. Asserts the sandbox grants are
# consistent with what the running service (and its sudo children) write to.
# Chroot smoke does not exercise systemd sandboxing, so this is the cheapest
# guard against a ReadWritePaths regression that would surface only on a
# booted feeder.

setup() {
    UNIT="$BATS_TEST_DIRNAME/../stage-airplanes/05-install-webconfig/files/etc/systemd/system/airplanes-webconfig.service"
    [ -f "$UNIT" ] || skip "unit file missing"
}

unit_get() {
    local key="$1"
    grep -E "^${key}=" "$UNIT" | tail -n1 | sed -E "s/^${key}=//"
}

@test "ProtectSystem=strict" {
    [ "$(unit_get ProtectSystem)" = "strict" ]
}

@test "ReadWritePaths covers /var/lib/airplanes-webconfig" {
    val="$(unit_get ReadWritePaths)"
    [[ "$val" == *"/var/lib/airplanes-webconfig"* ]]
}

@test "ReadWritePaths covers /etc/airplanes" {
    val="$(unit_get ReadWritePaths)"
    [[ "$val" == *"/etc/airplanes"* ]]
}

@test "ReadWritePaths covers /run/airplanes" {
    val="$(unit_get ReadWritePaths)"
    [[ "$val" == *"/run/airplanes"* ]]
}

@test "ReadWritePaths covers /etc/NetworkManager/system-connections" {
    # apl-wifi runs as a sudo child of webconfig and inherits this unit's
    # mount namespace. Without the path here, atomic keyfile renames fail on
    # the booted feeder even though they succeed in chroot tests.
    val="$(unit_get ReadWritePaths)"
    [[ "$val" == *"/etc/NetworkManager/system-connections"* ]]
}

@test "NoNewPrivileges stays false (sudo elevation is the design)" {
    [ "$(unit_get NoNewPrivileges)" = "no" ]
}
