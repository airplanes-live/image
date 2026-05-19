#!/usr/bin/env bats

# Tests for runtime-overlay/scripts/lib/stage-tar1090.sh — runs tar1090's
# install.sh against a scratch sysroot under bubblewrap and assembles a
# staging tree the runtime-overlay release tarball will consume.
#
# Heavyweight paths (network clone + install.sh execution) gate on
# RUN_NETWORK_TESTS=1 and on bwrap being present. Validation/arg-error
# paths run everywhere.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HELPER="$REPO_ROOT/runtime-overlay/scripts/lib/stage-tar1090.sh"
    [ -x "$HELPER" ] || skip "stage-tar1090.sh not executable: $HELPER"

    OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
    install -d -m 0755 "$OUTPUT_DIR"
}

@test "rejects a missing required argument" {
    run "$HELPER" \
        --repo https://example.invalid/repo.git \
        --ref master \
        --db-repo https://example.invalid/db.git \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"db-ref"* ]]
}

@test "rejects an unknown argument" {
    run "$HELPER" --frobnicate value
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown argument"* ]]
}

@test "stages tar1090 + tar1090-db (gated; requires network + bwrap)" {
    if [ -z "${RUN_NETWORK_TESTS:-}" ]; then
        skip "set RUN_NETWORK_TESTS=1 to exercise this path"
    fi
    if ! command -v bwrap >/dev/null 2>&1; then
        skip "bubblewrap (bwrap) not installed"
    fi

    run "$HELPER" \
        --repo https://github.com/wiedehopf/tar1090.git \
        --ref master \
        --db-repo https://github.com/wiedehopf/tar1090-db.git \
        --db-ref master \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -eq 0 ]

    # Required staging tree.
    [ -d "$OUTPUT_DIR/share/tar1090" ]
    [ -d "$OUTPUT_DIR/share/tar1090/git-db" ]
    [ -f "$OUTPUT_DIR/share/tar1090/tar1090.sh" ]
    [ -f "$OUTPUT_DIR/systemd/tar1090.service" ]
    [ -f "$OUTPUT_DIR/etc/lighttpd/conf-available/88-tar1090.conf" ]
    [ -s "$OUTPUT_DIR/components.tar1090.sha" ]
    [ -s "$OUTPUT_DIR/components.tar1090_db.sha" ]

    # Pin shape.
    sha="$(cat "$OUTPUT_DIR/components.tar1090.sha")"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
    sha="$(cat "$OUTPUT_DIR/components.tar1090_db.sha")"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
}

@test "path-relocatability: no SYSROOT/SCRATCH path leaks (gated)" {
    if [ -z "${RUN_NETWORK_TESTS:-}" ]; then
        skip "set RUN_NETWORK_TESTS=1 to exercise this path"
    fi
    if ! command -v bwrap >/dev/null 2>&1; then
        skip "bubblewrap (bwrap) not installed"
    fi

    run "$HELPER" \
        --repo https://github.com/wiedehopf/tar1090.git \
        --ref master \
        --db-repo https://github.com/wiedehopf/tar1090-db.git \
        --db-ref master \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -eq 0 ]

    # The helper's own post-stage check already fails the run on a leak;
    # asserting again here pins the contract from the test's perspective.
    # Look for any reference to /tmp/stage-tar1090.* in shell/unit/conf
    # files inside the staging tree.
    run grep -RFn -- '/tmp/stage-tar1090' \
        "$OUTPUT_DIR/share/tar1090" \
        "$OUTPUT_DIR/systemd" \
        "$OUTPUT_DIR/etc/lighttpd"
    # grep exits 1 on zero matches; that's the desired outcome.
    [ "$status" -eq 1 ]
}
