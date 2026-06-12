#!/usr/bin/env bats

# Pins .github/scripts/changed-files-need-build.sh — the single source of
# truth for which paths trigger the full image build on a PR. A pattern
# accidentally dropped here means test-only PRs start spending the
# multi-hour arm64 build budget again, or worse: a build-input path that
# stops matching ships image changes without a pre-merge build.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../.github/scripts/changed-files-need-build.sh"
}

run_filter() {
    printf '%s\n' "$@" | bash "$SCRIPT"
}

@test "build inputs trigger a build" {
    [ "$(run_filter stage-airplanes/01-install-feed/00-run.sh)" = "true" ]
    [ "$(run_filter stage0/prerun.sh)" = "true" ]
    [ "$(run_filter config-dev)" = "true" ]
    [ "$(run_filter config-stable)" = "true" ]
    [ "$(run_filter runtime-overlay/src/share/airplanes/readsb.sh)" = "true" ]
    [ "$(run_filter scripts/render-status)" = "true" ]
    [ "$(run_filter depends)" = "true" ]
    [ "$(run_filter Dockerfile)" = "true" ]
    [ "$(run_filter build.sh)" = "true" ]
    [ "$(run_filter build-docker.sh)" = "true" ]
    [ "$(run_filter export-image/04-finalise/01-run.sh)" = "true" ]
    [ "$(run_filter test/boot-smoke/extra-probe.sh)" = "true" ]
    [ "$(run_filter .github/workflows/build-image.yml)" = "true" ]
    [ "$(run_filter .github/scripts/changed-files-need-build.sh)" = "true" ]
}

@test "test- and docs-only changes do not trigger a build" {
    [ "$(run_filter test/test_first_run_basic.bats)" = "false" ]
    [ "$(run_filter test/runtime-overlay/test_readsb_wrapper.bats)" = "false" ]
    [ "$(run_filter README.md)" = "false" ]
    [ "$(run_filter .github/workflows/ci.yml)" = "false" ]
    [ "$(run_filter .claude/CLAUDE.md)" = "false" ]
}

@test "a mixed change list triggers a build" {
    [ "$(run_filter README.md test/test_foo.bats stage-airplanes/00-prep/00-run.sh)" = "true" ]
}

@test "exact-name patterns do not prefix-match" {
    [ "$(run_filter config-dev-notes.md)" = "false" ]
    [ "$(run_filter Dockerfile.test)" = "false" ]
    [ "$(run_filter build.sh.bak)" = "false" ]
}

@test "empty input means no build" {
    [ "$(printf '' | bash "$SCRIPT")" = "false" ]
}
