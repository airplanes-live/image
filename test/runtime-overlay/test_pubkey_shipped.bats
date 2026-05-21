#!/usr/bin/env bats

# The runtime-overlay release public key must ship with the image. Stage
# 00-prep installs it from files/usr/share/airplanes/runtime-release.pub
# to /usr/share/airplanes/runtime-release.pub in the rootfs; on-device
# install.sh verifies SHA256SUMS against the same key.
#
# Tests assert the file is committed, has the documented two-line minisign
# shape, and exercises minisign parsing if the binary is on the host.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    PUBKEY="$REPO_ROOT/stage-airplanes/00-prep/files/usr/share/airplanes/runtime-release.pub"
}

@test "pubkey file is committed at the expected path" {
    [ -f "$PUBKEY" ]
}

@test "pubkey has the documented two-line minisign shape" {
    local lines
    lines="$(wc -l < "$PUBKEY")"
    # POSIX wc counts newlines; the file must end with one newline so two
    # logical lines + trailing newline = 2.
    [ "$lines" -eq 2 ]

    local first second
    first="$(sed -n 1p "$PUBKEY")"
    second="$(sed -n 2p "$PUBKEY")"

    [[ "$first" =~ ^untrusted\ comment:\ minisign\ public\ key ]] \
        || { echo "first line: '$first'" >&2; return 1; }
    [[ "$second" =~ ^RW ]] \
        || { echo "second line should start with RW (minisign Ed25519 key id): '$second'" >&2; return 1; }
}

@test "pubkey is wired into a stage 00-prep run script" {
    # The file is installed via 06-run.sh; assert at least one stage 00-prep
    # run script references it. Tolerant of future refactors that may
    # consolidate the install into another sub-stage.
    if ! grep -rlE 'runtime-release\.pub' "$REPO_ROOT/stage-airplanes/00-prep/" >/dev/null; then
        echo "no stage 00-prep run script installs runtime-release.pub" >&2
        return 1
    fi
}

@test "minisign can parse the shipped pubkey" {
    if ! command -v minisign >/dev/null 2>&1; then
        skip "minisign not installed on this host"
    fi
    # minisign -V needs a message + signature to verify, but `-h` is not
    # universal across versions. Use the side effect that supplying an
    # unreadable signature/message with a parseable pubkey gives a
    # different error string than supplying an unparseable pubkey.
    local out
    out="$(minisign -V -p "$PUBKEY" -m /dev/null -x /dev/null 2>&1 || true)"
    # An unparseable pubkey emits "Invalid public key" or "Error in"; a
    # parseable pubkey with junk message gets to "Error: invalid trusted
    # comment" / "signature ... is invalid". Either way, the error MUST
    # NOT mention the public key file itself.
    if [[ "$out" == *"public key"* && "$out" == *"invalid"* ]]; then
        # Some minisign builds phrase pubkey parse errors as
        # "invalid public key" — that's the failure mode we want to catch.
        echo "minisign rejected the pubkey: $out" >&2
        return 1
    fi
}
