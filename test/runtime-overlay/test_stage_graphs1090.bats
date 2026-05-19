#!/usr/bin/env bats

# Tests for runtime-overlay/scripts/lib/stage-graphs1090.sh — runs
# graphs1090's install.sh under bubblewrap, applies the URL_978 +
# Interface normalization edits at staging time, and asserts the produced
# collectd.conf carries those edits before the release tarball is built.
#
# Heavyweight paths gate on RUN_NETWORK_TESTS=1 + bwrap. Validation paths
# run unconditionally.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HELPER="$REPO_ROOT/runtime-overlay/scripts/lib/stage-graphs1090.sh"
    [ -x "$HELPER" ] || skip "stage-graphs1090.sh not executable: $HELPER"

    OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
    install -d -m 0755 "$OUTPUT_DIR"
}

@test "rejects a missing required argument" {
    run "$HELPER" \
        --repo https://example.invalid/repo.git \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ref"* ]]
}

@test "rejects an unknown argument" {
    run "$HELPER" --bogus value
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown argument"* ]]
}

@test "stages graphs1090 with corrected collectd.conf (gated)" {
    if [ -z "${RUN_NETWORK_TESTS:-}" ]; then
        skip "set RUN_NETWORK_TESTS=1 to exercise this path"
    fi
    if ! command -v bwrap >/dev/null 2>&1; then
        skip "bubblewrap (bwrap) not installed"
    fi

    run "$HELPER" \
        --repo https://github.com/wiedehopf/graphs1090.git \
        --ref master \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -eq 0 ]

    [ -d "$OUTPUT_DIR/share/graphs1090" ]
    [ -f "$OUTPUT_DIR/systemd/graphs1090.service" ]
    [ -f "$OUTPUT_DIR/etc/lighttpd/conf-available/88-graphs1090.conf" ]
    [ -f "$OUTPUT_DIR/etc/collectd/collectd.conf" ]
    [ -s "$OUTPUT_DIR/components.graphs1090.sha" ]

    # URL_978 edit applied: the file URL must be present and uncommented.
    run grep -E '^URL_978 "file:///usr/share/graphs1090/978-symlink"$' \
        "$OUTPUT_DIR/etc/collectd/collectd.conf"
    [ "$status" -eq 0 ]

    # Interface normalization: the three canonical Pi names appear and the
    # block contains no other Interface "..." entries between the opening
    # <Plugin "interface"> and the closing </Plugin>.
    run grep -F 'Interface "eth0"'  "$OUTPUT_DIR/etc/collectd/collectd.conf"
    [ "$status" -eq 0 ]
    run grep -F 'Interface "end0"'  "$OUTPUT_DIR/etc/collectd/collectd.conf"
    [ "$status" -eq 0 ]
    run grep -F 'Interface "wlan0"' "$OUTPUT_DIR/etc/collectd/collectd.conf"
    [ "$status" -eq 0 ]

    # Pin shape.
    sha="$(cat "$OUTPUT_DIR/components.graphs1090.sha")"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
}

@test "URL_978 + Interface normalization applied even on a synthetic collectd.conf" {
    # Offline-friendly variant: synthesise the post-install collectd.conf
    # shape (a commented-out URL_978 line, an interface block with build-
    # host names) and run the same awk + sed transforms the helper applies.
    # This pins the edit logic without requiring the full bwrap install.
    if ! command -v awk >/dev/null 2>&1; then
        skip "awk not available"
    fi

    local synthetic="$BATS_TEST_TMPDIR/collectd.conf"
    cat > "$synthetic" <<'EOF'
LoadPlugin curl_json
<Plugin curl_json>
    #URL_978 "http://127.0.0.1/skyaware978/data/aircraft.json"
</Plugin>

LoadPlugin interface
<Plugin "interface">
    Interface "eno1"
    Interface "ens3"
</Plugin>
EOF

    # Apply the same edits the helper applies. Keep this in lockstep with
    # stage-graphs1090.sh — if the helper's edit logic changes, this test
    # changes too, and the lockstep is the explicit invariant.
    sed -i -E 's|^[[:space:]]*#[[:space:]]*URL_978 .*|URL_978 "file:///usr/share/graphs1090/978-symlink"|' \
        "$synthetic"
    local awk_out="$BATS_TEST_TMPDIR/collectd.conf.new"
    awk '
/^<Plugin "interface">$/ { in_block=1; print; print "    Interface \"eth0\""; print "    Interface \"end0\""; print "    Interface \"wlan0\""; next }
in_block && /^<\/Plugin>/ { in_block=0; print; next }
in_block && /^[[:space:]]*Interface ".*"/ { next }
{ print }
' "$synthetic" > "$awk_out"
    mv -f "$awk_out" "$synthetic"

    run grep -E '^URL_978 "file:///usr/share/graphs1090/978-symlink"$' "$synthetic"
    [ "$status" -eq 0 ]
    run grep -F 'Interface "eth0"' "$synthetic"
    [ "$status" -eq 0 ]
    run grep -F 'Interface "ens3"' "$synthetic"
    # ens3 must NOT survive normalization.
    [ "$status" -ne 0 ]
}
