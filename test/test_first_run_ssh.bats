#!/usr/bin/env bats

# Tests for the per-device SSH opt-in in airplanes-first-run: apply_ssh_password
# and apply_ssh_pubkey, plus the secret-safe handling around them.
#
# SSH_PASSWORD / SSH_PUBKEY are synthetic boot-config keys. apply_ssh_password
# sets the pi account password (via chpasswd) and drops the shared
# 99-airplanes-ssh-pi.conf snippet; apply_ssh_pubkey overwrites a managed
# authorized_keys file for pi. Both strip their key from BOOT_CFG so it can
# never reach feed.env. The password cleartext is redacted from the FAT source
# at apply time, decoupled from the later success rename.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/usr/local/sbin/airplanes-first-run"
    export APL_WIFI_LIB_DIR="${AIRPLANES_IMAGE_WEBCONFIG_ROOT:-$BATS_TEST_DIRNAME/../../image-webconfig}/files/usr/local/lib/airplanes"
    TMP="$(mktemp -d)"

    # Redirect all SSH-opt-in write targets into the tmpdir.
    export SSHD_PI_PWAUTH_CONF="$TMP/etc/ssh/sshd_config.d/99-airplanes-ssh-pi.conf"
    export SSH_AUTH_KEYS_DIR="$TMP/etc/ssh/authorized_keys.d"
    export SSH_PI_AUTH_KEYS="$SSH_AUTH_KEYS_DIR/pi"
    export BOOT_CONFIG="$TMP/boot/firmware/airplanes-config.txt"
    export FEED_ENV="$TMP/feed.env"
    export LOCK_FILE="$TMP/lock"
    mkdir -p "$TMP/etc/ssh/sshd_config.d" "$TMP/boot/firmware"

    # Stub chpasswd: record the stdin payload so tests can assert the right
    # user:password line was piped without that value reaching a real account.
    CHPASSWD_LOG="$TMP/chpasswd.log"
    export CHPASSWD_LOG
    chpasswd() { cat >> "$CHPASSWD_LOG"; return "${CHPASSWD_RC:-0}"; }
    # Stub systemctl so the best-effort `systemctl reload ssh` is a no-op here.
    systemctl() { return 0; }
    export -f chpasswd systemctl

    # shellcheck source=/dev/null
    source "$SCRIPT"
    BOOT_CFG=()
    BOOT_CFG_ERRORS=()
}

teardown() { rm -rf "$TMP"; }

# ---- apply_ssh_password ----------------------------------------------------

@test "password unset -> no-op (no snippet, no chpasswd)" {
    apply_ssh_password
    [ ! -f "$SSHD_PI_PWAUTH_CONF" ]
    [ ! -f "$CHPASSWD_LOG" ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
}

@test "valid password sets pi pw and drops the 99 snippet (byte-exact)" {
    BOOT_CFG=([SSH_PASSWORD]="supersecret1234")
    apply_ssh_password
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
    [ ! -v "BOOT_CFG[SSH_PASSWORD]" ]
    grep -qx 'pi:supersecret1234' "$CHPASSWD_LOG"

    # The snippet must match the cross-repo contract byte-for-byte.
    local expected
    expected="$(cat <<'EOF'
# airplanes.live per-device opt-in: enables password SSH for the pi account
# only (Match-scoped, so other users keep the 90-airplanes.conf default of
# PasswordAuthentication no). Written by airplanes-first-run (boot config) and
# webconfig's apl-ssh helper.
Match User pi
    PasswordAuthentication yes
Match all
EOF
)"
    [ "$(cat "$SSHD_PI_PWAUTH_CONF")" = "$expected" ]
    [ "$(stat -c '%a' "$SSHD_PI_PWAUTH_CONF")" = "644" ]
}

@test "password exactly 12 chars is accepted (boundary)" {
    BOOT_CFG=([SSH_PASSWORD]="abcdefghijkl")   # 12
    apply_ssh_password
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
    [ -f "$SSHD_PI_PWAUTH_CONF" ]
}

@test "password under 12 chars is rejected (secret-safe error, no value)" {
    BOOT_CFG=([SSH_PASSWORD]="elevenchar1")    # 11 chars
    apply_ssh_password
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"SSH_PASSWORD"* ]]
    # The value must NOT appear in the error message.
    [[ "${BOOT_CFG_ERRORS[0]}" != *"elevenchar1"* ]]
    [ ! -f "$SSHD_PI_PWAUTH_CONF" ]
    [ ! -f "$CHPASSWD_LOG" ]
    [ ! -v "BOOT_CFG[SSH_PASSWORD]" ]
}

@test "password with shell metacharacters is accepted (piped to chpasswd)" {
    BOOT_CFG=([SSH_PASSWORD]='p$ss"w\rd-longenough')
    apply_ssh_password
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
    grep -qF 'pi:p$ss"w\rd-longenough' "$CHPASSWD_LOG"
    [ -f "$SSHD_PI_PWAUTH_CONF" ]
}

@test "chpasswd failure surfaces an error and skips the snippet" {
    export CHPASSWD_RC=1
    BOOT_CFG=([SSH_PASSWORD]="supersecret1234")
    apply_ssh_password
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"SSH_PASSWORD"* ]]
    [ ! -f "$SSHD_PI_PWAUTH_CONF" ]
}

# ---- redaction of the FAT source -------------------------------------------

@test "applying the password redacts SSH_PASSWORD from the source in place" {
    cat > "$BOOT_CONFIG" <<'EOF'
HOSTNAME=feeder1
SSH_PASSWORD=supersecret1234
FEED_HOST=feed.example
EOF
    BOOT_CFG=([SSH_PASSWORD]="supersecret1234")
    apply_ssh_password
    # cleartext gone, marker present, other lines intact + ordered.
    ! grep -q 'supersecret1234' "$BOOT_CONFIG"
    grep -qx '# SSH_PASSWORD applied and redacted' "$BOOT_CONFIG"
    grep -qx 'HOSTNAME=feeder1' "$BOOT_CONFIG"
    grep -qx 'FEED_HOST=feed.example' "$BOOT_CONFIG"
}

@test "redaction survives a later apply-step failure (source kept for retry)" {
    # Simulate the real main() flow: password applies, then FEED_HOST fails and
    # the source is kept for retry. The kept source must carry no cleartext.
    cat > "$BOOT_CONFIG" <<'EOF'
SSH_PASSWORD=supersecret1234
FEED_HOST=bad host with spaces
EOF
    BOOT_CFG=([SSH_PASSWORD]="supersecret1234" [FEED_HOST]="bad host with spaces")
    apply_ssh_password
    expand_feed_host   # records an error, leaves source unrenamed in main()
    ! grep -q 'supersecret1234' "$BOOT_CONFIG"
    grep -qx '# SSH_PASSWORD applied and redacted' "$BOOT_CONFIG"
}

# ---- apply_ssh_pubkey ------------------------------------------------------

@test "pubkey unset -> no-op" {
    apply_ssh_pubkey
    [ ! -f "$SSH_PI_AUTH_KEYS" ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
}

@test "valid ed25519 pubkey overwrites the managed keyfile (single key, 0644)" {
    local k="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTBLOB user@host"
    # Pre-seed a stale multi-line keyfile to prove OVERWRITE (not append).
    mkdir -p "$SSH_AUTH_KEYS_DIR"
    printf 'old-key-1\nold-key-2\n' > "$SSH_PI_AUTH_KEYS"
    BOOT_CFG=([SSH_PUBKEY]="$k")
    apply_ssh_pubkey
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
    [ ! -v "BOOT_CFG[SSH_PUBKEY]" ]
    [ "$(cat "$SSH_PI_AUTH_KEYS")" = "$k" ]
    [ "$(wc -l < "$SSH_PI_AUTH_KEYS")" -eq 1 ]
    [ "$(stat -c '%a' "$SSH_PI_AUTH_KEYS")" = "644" ]
}

@test "valid ecdsa and sk- key types accepted" {
    BOOT_CFG=([SSH_PUBKEY]="ecdsa-sha2-nistp256 AAAAE2Vj recovery")
    apply_ssh_pubkey
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
    [ -f "$SSH_PI_AUTH_KEYS" ]

    rm -f "$SSH_PI_AUTH_KEYS"
    BOOT_CFG_ERRORS=()
    BOOT_CFG=([SSH_PUBKEY]="sk-ssh-ed25519@openssh.com AAAAGnNr yubikey")
    apply_ssh_pubkey
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
    [ -f "$SSH_PI_AUTH_KEYS" ]
}

@test "invalid pubkey (bad type token) is rejected, no keyfile written" {
    BOOT_CFG=([SSH_PUBKEY]="not-a-key-type AAAAblob comment")
    apply_ssh_pubkey
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"SSH_PUBKEY"* ]]
    [ ! -f "$SSH_PI_AUTH_KEYS" ]
    [ ! -v "BOOT_CFG[SSH_PUBKEY]" ]
}

@test "invalid pubkey (missing blob) is rejected" {
    BOOT_CFG=([SSH_PUBKEY]="ssh-ed25519")
    apply_ssh_pubkey
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [ ! -f "$SSH_PI_AUTH_KEYS" ]
}

@test "invalid pubkey (non-base64 blob) is rejected" {
    BOOT_CFG=([SSH_PUBKEY]="ssh-rsa not*base64! comment")
    apply_ssh_pubkey
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [ ! -f "$SSH_PI_AUTH_KEYS" ]
}

# ---- end-to-end: SSH_* never reach feed.env --------------------------------

@test "SSH_PASSWORD and SSH_PUBKEY never appear in merged feed.env" {
    : > "$FEED_ENV"
    cat > "$BOOT_CONFIG" <<'EOF'
SSH_PASSWORD=supersecret1234
SSH_PUBKEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTBLOB user@host
FEED_HOST=feed.example
EOF
    parse_boot_config "$BOOT_CONFIG"
    [ "${BOOT_CFG[SSH_PASSWORD]}" = "supersecret1234" ]
    apply_ssh_password
    apply_ssh_pubkey
    expand_feed_host
    merge_feed_env
    ! grep -q '^SSH_PASSWORD=' "$FEED_ENV"
    ! grep -q '^SSH_PUBKEY=' "$FEED_ENV"
    ! grep -q 'supersecret1234' "$FEED_ENV"
    # Sanity: the non-SSH key still merged (MLATSERVER derived from FEED_HOST).
    grep -q '^MLATSERVER=' "$FEED_ENV"
}
