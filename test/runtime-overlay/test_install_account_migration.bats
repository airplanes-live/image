#!/usr/bin/env bats

# Tests the 0001-create-service-accounts shell migration (DEV-472):
#   - forward creates tar1090 + readsb when missing, with the EXACT adduser
#     flags the chroot stage uses (parity)
#   - forward is idempotent (no adduser when the account already exists)
#   - rollback is a no-op
#   - manifest-inputs ordering (create-service-accounts before
#     readsb-user-groups, so a group can't be assigned to a missing user)
#   - the declared script + rollback_script source files exist and are staged

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

FWD_REL="migrations/0001-create-service-accounts.sh"
RBK_REL="migrations/0001-create-service-accounts.rollback.sh"

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    RELEASE_DIR="$(mk_release_dir "$BATS_TEST_TMPDIR")"

    # Copy the REAL migration scripts into the synthetic release tree.
    cp "$OVERLAY_DIR/src/$FWD_REL" "$RELEASE_DIR/$FWD_REL"
    cp "$OVERLAY_DIR/src/$RBK_REL" "$RELEASE_DIR/$RBK_REL"
    chmod 755 "$RELEASE_DIR/$FWD_REL" "$RELEASE_DIR/$RBK_REL"

    # Mock adduser (logs argv) and getent (presence is test-controlled via
    # the GETENT_PRESENT file: each listed user is reported present).
    MOCK_BIN="$BATS_TEST_TMPDIR/mockbin"
    install -d -m 755 "$MOCK_BIN"
    ADDUSER_LOG="$BATS_TEST_TMPDIR/adduser.log"
    : > "$ADDUSER_LOG"
    GETENT_PRESENT="$BATS_TEST_TMPDIR/getent-present"
    : > "$GETENT_PRESENT"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf '\''%%s\\n'\'' "$*" >> %q\n' "$ADDUSER_LOG"
        printf 'exit 0\n'
    } > "$MOCK_BIN/adduser"
    # addgroup is logged to the same argv log (prefixed) so the airplanes-feed
    # group-create is observable. The migration calls `addgroup --system NAME`.
    ADDGROUP_LOG="$BATS_TEST_TMPDIR/addgroup.log"
    : > "$ADDGROUP_LOG"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf '\''%%s\\n'\'' "$*" >> %q\n' "$ADDGROUP_LOG"
        printf 'exit 0\n'
    } > "$MOCK_BIN/addgroup"
    {
        printf '#!/usr/bin/env bash\n'
        # getent passwd|group <name> : exit 0 if <name> listed present, else 2.
        printf 'u="${@: -1}"\n'
        printf 'grep -qxF "$u" %q && exit 0\n' "$GETENT_PRESENT"
        printf 'exit 2\n'
    } > "$MOCK_BIN/getent"
    chmod 755 "$MOCK_BIN/adduser" "$MOCK_BIN/addgroup" "$MOCK_BIN/getent"
    # Test seam: the migration pins PATH internally. Put the mock dir AHEAD of
    # the system dirs so mock adduser/getent shadow the real ones, while the
    # mocks' own interpreter (env bash) and helpers (grep) still resolve.
    export AIRPLANES_RUNTIME_MIGRATION_PATH="$MOCK_BIN:/usr/sbin:/usr/bin:/sbin:/bin"

    MANIFEST="$BATS_TEST_TMPDIR/manifest.json"
    cat > "$MANIFEST" <<JSON
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": [],
    "migrations": [
        { "id": "create-service-accounts", "type": "shell",
          "script": "$FWD_REL", "rollback_script": "$RBK_REL" }
    ]
}
JSON
}

@test "forward creates tar1090 + readsb + airplanes-feed + airplanes-aggregator when missing, with exact flags" {
    # GETENT_PRESENT empty → all users + the airplanes-feed group missing.
    run airplanes_runtime_run_migrations_forward "$MANIFEST" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run grep -E '^--system --home /usr/local/share/tar1090 --no-create-home --quiet tar1090$' "$ADDUSER_LOG"
    [ "$status" -eq 0 ]
    run grep -E '^--system --group --home /usr/local/share/readsb --no-create-home --quiet readsb$' "$ADDUSER_LOG"
    [ "$status" -eq 0 ]
    run grep -E '^--system --ingroup airplanes-feed --home /opt/airplanes/current/share/airplanes --no-create-home --quiet airplanes-feed$' "$ADDUSER_LOG"
    [ "$status" -eq 0 ]
    run grep -E '^--system --no-create-home --group airplanes-aggregator$' "$ADDUSER_LOG"
    [ "$status" -eq 0 ]
    run grep -E '^--system airplanes-feed$' "$ADDGROUP_LOG"
    [ "$status" -eq 0 ]
}

@test "forward is idempotent: present accounts trigger no adduser/addgroup" {
    printf 'readsb\ntar1090\nairplanes-feed\nairplanes-aggregator\n' > "$GETENT_PRESENT"
    run airplanes_runtime_run_migrations_forward "$MANIFEST" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    # Neither adduser nor addgroup may be invoked when all are present.
    [ ! -s "$ADDUSER_LOG" ]
    [ ! -s "$ADDGROUP_LOG" ]
}

@test "rollback is a no-op (no adduser/addgroup, no deletion)" {
    airplanes_runtime_run_migrations_forward "$MANIFEST" "$RELEASE_DIR" "$TARGET_ROOT"
    : > "$ADDUSER_LOG"
    : > "$ADDGROUP_LOG"
    run airplanes_runtime_run_migrations_rollback "$MANIFEST" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ ! -s "$ADDUSER_LOG" ]
    [ ! -s "$ADDGROUP_LOG" ]
}

@test "manifest-inputs: create-service-accounts is ordered before readsb-user-groups" {
    local mig="$OVERLAY_DIR/manifest-inputs/migrations.json"
    run jq -e . "$mig"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].id' "$mig")" = "create-service-accounts" ]
    local acct_idx grp_idx
    acct_idx="$(jq -r 'map(.id) | index("create-service-accounts")' "$mig")"
    grp_idx="$(jq -r 'map(.id) | index("readsb-user-groups")' "$mig")"
    [ "$grp_idx" != "null" ]
    [ "$acct_idx" -lt "$grp_idx" ]
}

@test "manifest-inputs: create-service-accounts runs on every install" {
    # every_install is what makes a new account added to 0001 (e.g.
    # airplanes-aggregator) reach a feeder that already recorded the migration
    # id from an earlier overlay — first_install_of_version would skip it once
    # recorded and strand the account, failing the unit with 217/USER.
    local mig="$OVERLAY_DIR/manifest-inputs/migrations.json"
    run jq -r '.[] | select(.id == "create-service-accounts") | .run_when // "every_install"' "$mig"
    [ "$status" -eq 0 ]
    [ "$output" = "every_install" ]
}

@test "declared script + rollback source files exist and are staged" {
    [ -f "$OVERLAY_DIR/src/$FWD_REL" ]
    [ -f "$OVERLAY_DIR/src/$RBK_REL" ]
    # build-runtime-assets.sh must copy src/migrations into the release tree.
    run grep -F 'src/migrations' "$OVERLAY_DIR/scripts/release-workflow/build-runtime-assets.sh"
    [ "$status" -eq 0 ]
}

@test "migration adduser flags match the chroot stage exactly (parity)" {
    local chroot="$REPO_ROOT/stage-airplanes/02-install-runtime-overlay/01-run-chroot.sh"
    local mig="$OVERLAY_DIR/src/$FWD_REL"
    local user
    for user in tar1090 readsb; do
        local from_chroot from_mig
        # Anchor on the account-CREATE line (`adduser --system …`) so the
        # chroot's `adduser readsb plugdev`/`dialout` group lines don't match.
        from_chroot="$(grep -E "adduser --system .*\b${user}\b" "$chroot" | sed 's/^[[:space:]]*//' | tr -s ' ')"
        from_mig="$(grep -E "adduser --system .*\b${user}\b" "$mig" | sed 's/^[[:space:]]*//' | tr -s ' ')"
        [ -n "$from_chroot" ]
        [ -n "$from_mig" ]
        [ "$from_chroot" = "$from_mig" ]
    done
}

@test "airplanes-aggregator migration adduser flags match stage 05 exactly (parity)" {
    # airplanes-aggregator is created at flash by stage 05 (a webconfig-feature
    # account), so its parity anchor is that stage, not the stage-02 chroot.
    local stage05="$REPO_ROOT/stage-airplanes/05-install-webconfig/01-run-chroot.sh"
    local mig="$OVERLAY_DIR/src/$FWD_REL"
    local from_stage from_mig
    from_stage="$(grep -E 'adduser --system .*\bairplanes-aggregator\b' "$stage05" | sed 's/^[[:space:]]*//' | tr -s ' ')"
    from_mig="$(grep -E 'adduser --system .*\bairplanes-aggregator\b' "$mig" | sed 's/^[[:space:]]*//' | tr -s ' ')"
    [ -n "$from_stage" ]
    [ -n "$from_mig" ]
    [ "$from_stage" = "$from_mig" ]
}
