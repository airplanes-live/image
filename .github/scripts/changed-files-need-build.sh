#!/usr/bin/env bash
# Decides whether a changed-file list (one path per line on stdin) touches
# image-build inputs. Prints "true" or "false" on stdout; a non-zero exit
# happens only on internal error — the calling job then fails instead of
# guessing, so a broken matcher can never silently skip a needed build.
#
# This list is the single source of truth for "what the image build
# consumes". It replaces the old workflow-level on.pull_request.paths
# filter in build-image.yml: the workflow now starts on every PR and its
# `changes` job uses this script to decide whether the heavy jobs run or
# report `skipped` (which branch rulesets count as passing — a
# path-filtered workflow that never starts produces no check runs at all,
# leaving test-/docs-only PRs permanently blocked on required checks).
#
# Pinned by test/test_changed_files_need_build.bats. The matcher itself
# and build-image.yml are in the list: changes to the gating must prove
# themselves against a full build.
set -euo pipefail

needs_build=false
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
        stage-airplanes/*) needs_build=true ;;
        stage0/*) needs_build=true ;;
        stage1/*) needs_build=true ;;
        stage2/*) needs_build=true ;;
        config-dev) needs_build=true ;;
        config-stable) needs_build=true ;;
        runtime-overlay/*) needs_build=true ;;
        scripts/*) needs_build=true ;;
        depends) needs_build=true ;;
        Dockerfile) needs_build=true ;;
        build.sh) needs_build=true ;;
        build-docker.sh) needs_build=true ;;
        export-image/*) needs_build=true ;;
        export-noobs/*) needs_build=true ;;
        test/boot-smoke/*) needs_build=true ;;
        .github/workflows/build-image.yml) needs_build=true ;;
        .github/scripts/changed-files-need-build.sh) needs_build=true ;;
    esac
done
printf '%s\n' "$needs_build"
