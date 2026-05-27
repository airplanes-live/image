#!/usr/bin/env bats

# Verify the overlay-staged airplanes-mlat.service includes the venv condition
# gate. The overlay post-processes the unit after staging from the feed repo to
# add ConditionPathExists=/usr/local/share/airplanes/venv/bin/mlat-client so the
# unit never starts when the venv is absent (e.g. a decoder-only release).
#
# This test constructs a minimal feed unit, runs the awk injection from
# stage-feed.sh, and asserts the result.

bats_require_minimum_version 1.5.0

setup() {
    UNIT_DIR="$BATS_TEST_TMPDIR/systemd"
    install -d -m 0755 "$UNIT_DIR"
}

_inject_condition() {
    local mlat_unit="$1"
    if [[ -f "$mlat_unit" ]] && ! grep -q '^ConditionPathExists=' "$mlat_unit"; then
        local tmp_unit
        tmp_unit="$(mktemp)"
        awk '
            /^\[Unit\]/ { print; in_unit = 1; next }
            in_unit && /^Description=/ {
                print
                print "ConditionPathExists=/usr/local/share/airplanes/venv/bin/mlat-client"
                next
            }
            /^\[/ && !/^\[Unit\]/ { in_unit = 0 }
            { print }
        ' "$mlat_unit" > "$tmp_unit"
        install -m 0644 "$tmp_unit" "$mlat_unit"
        rm -f -- "$tmp_unit"
    fi
}

@test "ConditionPathExists is injected into [Unit] after Description" {
    cat > "$UNIT_DIR/airplanes-mlat.service" <<'EOF'
[Unit]
Description=airplanes-mlat
Wants=network.target
After=network.target airplanes-first-run.service

[Service]
User=airplanes-feed
ExecStart=/usr/local/share/airplanes/airplanes-mlat.sh
Type=simple
Restart=always

[Install]
WantedBy=default.target
EOF

    _inject_condition "$UNIT_DIR/airplanes-mlat.service"

    # The condition must appear exactly once.
    local count
    count="$(grep -c '^ConditionPathExists=/usr/local/share/airplanes/venv/bin/mlat-client$' "$UNIT_DIR/airplanes-mlat.service")"
    [ "$count" -eq 1 ]

    # It must appear in the [Unit] section, after Description.
    run awk '
        /^\[Unit\]/ { in_unit = 1; next }
        /^\[/ && !/^\[Unit\]/ { in_unit = 0 }
        in_unit && /^Description=/ { saw_desc = 1 }
        in_unit && /^ConditionPathExists=/ { if (saw_desc) { print "OK"; exit 0 } }
    ' "$UNIT_DIR/airplanes-mlat.service"
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]
}

@test "injection is idempotent" {
    cat > "$UNIT_DIR/airplanes-mlat.service" <<'EOF'
[Unit]
Description=airplanes-mlat
Wants=network.target

[Service]
ExecStart=/usr/local/share/airplanes/airplanes-mlat.sh

[Install]
WantedBy=default.target
EOF

    _inject_condition "$UNIT_DIR/airplanes-mlat.service"
    _inject_condition "$UNIT_DIR/airplanes-mlat.service"

    local count
    count="$(grep -c '^ConditionPathExists=' "$UNIT_DIR/airplanes-mlat.service")"
    [ "$count" -eq 1 ]
}

@test "existing ConditionPathExists is not duplicated" {
    cat > "$UNIT_DIR/airplanes-mlat.service" <<'EOF'
[Unit]
Description=airplanes-mlat
ConditionPathExists=/usr/local/share/airplanes/venv/bin/mlat-client
Wants=network.target

[Service]
ExecStart=/usr/local/share/airplanes/airplanes-mlat.sh

[Install]
WantedBy=default.target
EOF

    _inject_condition "$UNIT_DIR/airplanes-mlat.service"

    local count
    count="$(grep -c '^ConditionPathExists=' "$UNIT_DIR/airplanes-mlat.service")"
    [ "$count" -eq 1 ]
}
