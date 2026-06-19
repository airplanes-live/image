#!/usr/bin/env bats

# Static lint of airplanes-first-run.service. Parses the unit file and asserts
# the sandbox directives are consistent with the script's actual write paths.
#
# Why a separate test: chroot smoke (first-run-chroot-smoke.sh) bypasses
# systemd's namespacing, so it cannot catch a ProtectSystem= misconfig that
# only manifests under real systemd. This lint is the cheapest static guard
# against that class of regression — every directive listed below is one the
# script depends on at runtime.

setup() {
    UNIT="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/etc/systemd/system/airplanes-first-run.service"
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/usr/local/sbin/airplanes-first-run"
    [ -f "$UNIT" ] || skip "unit file missing"
}

# Returns the value of a directive (after the '=', whitespace trimmed). Last
# occurrence wins, mirroring systemd semantics.
unit_get() {
    local key="$1"
    grep -E "^${key}=" "$UNIT" | tail -n1 | sed -E "s/^${key}=//"
}

# ---- sandbox directives ----------------------------------------------------

@test "ProtectSystem=true (NOT full or strict)" {
    # full would re-mount /etc read-only, breaking writes to /etc/hostname,
    # /etc/airplanes/, /etc/NetworkManager/system-connections/, etc.
    # strict would require enumerating every /etc subpath in ReadWritePaths.
    [ "$(unit_get ProtectSystem)" = "true" ]
}

@test "ReadWritePaths contains /boot/firmware" {
    # Required for consume_boot_config's rename and write_error_file's write.
    # Without this, the unit appears to succeed (chroot tests pass) but the
    # rename fails under real systemd.
    val="$(unit_get ReadWritePaths)"
    [[ "$val" == *"/boot/firmware"* ]]
}

@test "RuntimeDirectory=airplanes" {
    # Creates /run/airplanes/ so the feed.env flock has a parent dir on a
    # fresh boot. Matches webconfig's expected lock-file directory.
    [ "$(unit_get RuntimeDirectory)" = "airplanes" ]
}

@test "RuntimeDirectoryPreserve=yes" {
    # Keep /run/airplanes across the oneshot exit so webconfig (which assumes
    # the directory exists) doesn't race on startup.
    [ "$(unit_get RuntimeDirectoryPreserve)" = "yes" ]
}

# ---- script ↔ unit consistency --------------------------------------------

@test "script LOCK_FILE is the canonical /run/airplanes/feed-env.lock" {
    # first-run.sh flocks the same file that `apl-feed apply --json` uses
    # so concurrent edits to feed.env can never interleave. The canonical
    # path lives in feed/'s scripts/lib/feed-env-apply.sh; here we pin the
    # value so the first-run side cannot drift independently.
    script_lock="$(grep -E '^LOCK_FILE=' "$SCRIPT" | head -n1 | sed -E 's/.*"\$\{LOCK_FILE:-([^}]+)\}".*/\1/')"
    [ -n "$script_lock" ]
    [ "$script_lock" = "/run/airplanes/feed-env.lock" ]
}

@test "unit has no obsolete ConditionPathExists for the removed marker" {
    # The /var/lib/airplanes/first-run-done marker is gone in the consume-and-
    # rename model — file presence on FAT is the state. A leftover
    # ConditionPathExists referencing the marker would prevent the unit from
    # running at all once the marker existed from a previous boot.
    ! grep -qE 'ConditionPathExists=.*first-run-done' "$UNIT"
}

# ---- ordering directives (regression guards) -------------------------------

@test "Before= includes NetworkManager.service" {
    # WiFi keyfile must land before NM starts so the keyfile is picked up on
    # first auto-connect.
    val="$(unit_get Before)"
    [[ "$val" == *"NetworkManager.service"* ]]
}

@test "Before= includes lighttpd.service" {
    # Hostname must be applied before lighttpd serves its first response so
    # mDNS broadcasts the configured name.
    val="$(unit_get Before)"
    [[ "$val" == *"lighttpd.service"* ]]
}

@test "Before= includes ssh.service" {
    # The SSH_PASSWORD opt-in's 99-airplanes-ssh-pi.conf drop-in and the pi
    # authorized_keys file must land before sshd reads its config on the same
    # first boot.
    val="$(unit_get Before)"
    [[ "$val" == *"ssh.service"* ]]
}

# ---- SSH-opt-in write paths stay inside the writable sandbox ----------------

@test "ProtectSystem=true keeps the SSH-opt-in /etc writes valid" {
    # apply_ssh_password / apply_ssh_pubkey write /etc/ssh/sshd_config.d/,
    # /etc/ssh/authorized_keys.d/, and (via chpasswd) /etc/shadow. All live
    # under /etc, which ProtectSystem=true leaves writable — so no extra
    # ReadWritePaths entry is needed. Guard against a future tightening to
    # ProtectSystem=full/strict that would re-mount /etc read-only and silently
    # break these writes (chroot tests can't see it).
    [ "$(unit_get ProtectSystem)" = "true" ]
    # The script writes under /etc/ssh; assert it really targets /etc so a
    # refactor moving the keyfile under /home (ProtectHome=yes territory) trips
    # this lint.
    grep -qE 'SSHD_PI_PWAUTH_CONF=.*/etc/ssh/' "$SCRIPT"
    grep -qE 'SSH_AUTH_KEYS_DIR=.*/etc/ssh/' "$SCRIPT"
}

@test "Type=oneshot with RemainAfterExit=yes" {
    # The unit must be Type=oneshot so it runs to completion each boot, and
    # RemainAfterExit=yes so downstream units that order After=this unit
    # don't fight the inactive state after main exits.
    [ "$(unit_get Type)" = "oneshot" ]
    [ "$(unit_get RemainAfterExit)" = "yes" ]
}
