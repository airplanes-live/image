#!/usr/bin/env bats

# Tests for stage-airplanes/prerun.sh's SKIP-file gating between the legacy
# in-chroot decoder stages and the new runtime-overlay stage.
#
# Strategy: synthesise a stage-airplanes/ skeleton in a tmpdir (no real
# build), point BASE_DIR at it, and source prerun.sh under each flag value.
# Assert exactly the right SKIP files exist and stale ones are cleaned.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    PRERUN_SRC="$REPO_ROOT/stage-airplanes/prerun.sh"
    [[ -f "$PRERUN_SRC" ]] || { echo "prerun.sh missing: $PRERUN_SRC" >&2; return 1; }

    # Build a stand-in stage-airplanes/ directory with just the four
    # subdirs the gating logic touches. ROOTFS_DIR points at a tmpdir so
    # the prerun.sh top-of-file copy_previous branch is skipped.
    FAKE_BASE="$BATS_TEST_TMPDIR/repo"
    FAKE_ROOTFS="$BATS_TEST_TMPDIR/rootfs"
    install -d -m 755 "$FAKE_ROOTFS"
    install -d -m 755 \
        "$FAKE_BASE/stage-airplanes/02-install-decoder" \
        "$FAKE_BASE/stage-airplanes/03-install-tar1090" \
        "$FAKE_BASE/stage-airplanes/04-install-graphs1090" \
        "$FAKE_BASE/stage-airplanes/02-install-runtime-overlay"
    install -m 755 "$PRERUN_SRC" "$FAKE_BASE/stage-airplanes/prerun.sh"

    LEGACY_SKIPS=(
        "$FAKE_BASE/stage-airplanes/02-install-decoder/SKIP"
        "$FAKE_BASE/stage-airplanes/03-install-tar1090/SKIP"
        "$FAKE_BASE/stage-airplanes/04-install-graphs1090/SKIP"
    )
    OVERLAY_SKIP="$FAKE_BASE/stage-airplanes/02-install-runtime-overlay/SKIP"
}

run_prerun() {
    # Provide a no-op copy_previous so the ROOTFS_DIR-exists branch is the
    # only path executed.
    env \
        BASE_DIR="$FAKE_BASE" \
        ROOTFS_DIR="$FAKE_ROOTFS" \
        AIRPLANES_USE_LEGACY_DECODER_STAGES="$1" \
        bash -c "copy_previous() { :; }; export -f copy_previous; cd \"\${BASE_DIR}/stage-airplanes\" && ./prerun.sh"
}

@test "flag=0 SKIPs legacy stages and keeps overlay stage active" {
    run run_prerun 0
    [ "$status" -eq 0 ]
    [ -f "$FAKE_BASE/stage-airplanes/02-install-decoder/SKIP" ]
    [ -f "$FAKE_BASE/stage-airplanes/03-install-tar1090/SKIP" ]
    [ -f "$FAKE_BASE/stage-airplanes/04-install-graphs1090/SKIP" ]
    [ ! -f "$OVERLAY_SKIP" ]
}

@test "flag=1 SKIPs overlay stage and keeps legacy stages active" {
    run run_prerun 1
    [ "$status" -eq 0 ]
    [ ! -f "$FAKE_BASE/stage-airplanes/02-install-decoder/SKIP" ]
    [ ! -f "$FAKE_BASE/stage-airplanes/03-install-tar1090/SKIP" ]
    [ ! -f "$FAKE_BASE/stage-airplanes/04-install-graphs1090/SKIP" ]
    [ -f "$OVERLAY_SKIP" ]
}

@test "flag flip from 1 to 0 cleans stale legacy SKIPs" {
    run run_prerun 1
    [ "$status" -eq 0 ]
    [ -f "$OVERLAY_SKIP" ]

    run run_prerun 0
    [ "$status" -eq 0 ]
    [ ! -f "$OVERLAY_SKIP" ]
    [ -f "$FAKE_BASE/stage-airplanes/02-install-decoder/SKIP" ]
    [ -f "$FAKE_BASE/stage-airplanes/03-install-tar1090/SKIP" ]
    [ -f "$FAKE_BASE/stage-airplanes/04-install-graphs1090/SKIP" ]
}

@test "flag flip from 0 to 1 cleans stale overlay SKIP" {
    run run_prerun 0
    [ "$status" -eq 0 ]
    for s in "${LEGACY_SKIPS[@]}"; do
        [ -f "$s" ]
    done

    run run_prerun 1
    [ "$status" -eq 0 ]
    for s in "${LEGACY_SKIPS[@]}"; do
        [ ! -f "$s" ]
    done
    [ -f "$OVERLAY_SKIP" ]
}

@test "unset flag defaults to overlay (=0)" {
    run env \
        BASE_DIR="$FAKE_BASE" \
        ROOTFS_DIR="$FAKE_ROOTFS" \
        bash -c "copy_previous() { :; }; export -f copy_previous; cd \"\${BASE_DIR}/stage-airplanes\" && ./prerun.sh"
    [ "$status" -eq 0 ]
    for s in "${LEGACY_SKIPS[@]}"; do
        [ -f "$s" ]
    done
    [ ! -f "$OVERLAY_SKIP" ]
}
