#!/usr/bin/env bash
# resolve-channel-and-tags.sh — derive the release identity (channel,
# version, tag names) for a single runtime-release workflow run.
#
# Reads the github-actions trigger context from environment variables (so
# the script is testable outside CI) and emits a set of `key=value` lines
# to the file named by $GITHUB_OUTPUT (and a copy to stdout for log
# legibility).
#
# Required env:
#   GITHUB_EVENT_NAME    push | workflow_dispatch
#   GITHUB_REF           refs/tags/<tag>  | refs/heads/<branch>
#   GITHUB_SHA           40-hex commit SHA the workflow is running on
#
# Optional env (workflow_dispatch path):
#   INPUT_CHANNEL        stable | dev
#   INPUT_VERSION        explicit semver to publish (stable) or full
#                        semver+suffix (dev). Optional for dev; required
#                        for stable.
#
# Outputs (written to $GITHUB_OUTPUT, also echoed on stdout):
#   channel        stable | dev
#   version        the semver string the manifest will carry
#   floating_tag   runtime-dev-latest (dev) | "" (stable)
#   immutable_tag  runtime-vX.Y.Z (stable) | runtime-dev-<YYYYMMDD>-<sha7> (dev)
#   commit_sha     full 40-hex commit SHA
#   should_publish true | false
#
# Behaviour matrix:
#   - On `tags/runtime-v*` push:
#       channel=stable, version=tag minus the runtime-v prefix,
#       floating_tag="", immutable_tag=<tag>, should_publish=true.
#   - On `branches/dev` push:
#       channel=dev, version=<latest-stable-or-0.0.0>-dev-<YYYYMMDD>-<sha7>,
#       floating_tag=runtime-dev-latest,
#       immutable_tag=runtime-dev-<YYYYMMDD>-<sha7>, should_publish=true.
#   - On workflow_dispatch:
#       Honour INPUT_CHANNEL/INPUT_VERSION. Stable requires INPUT_VERSION.
#       Dev can synthesise a version like the branches/dev path.

set -euo pipefail

die() {
    echo "resolve-channel-and-tags: $*" >&2
    exit 1
}

EVENT="${GITHUB_EVENT_NAME:-}"
REF="${GITHUB_REF:-}"
SHA="${GITHUB_SHA:-}"
INPUT_CHANNEL="${INPUT_CHANNEL:-}"
INPUT_VERSION="${INPUT_VERSION:-}"

[[ -n "$EVENT" ]] || die "missing GITHUB_EVENT_NAME"
[[ -n "$REF" ]]   || die "missing GITHUB_REF"
[[ -n "$SHA" ]]   || die "missing GITHUB_SHA"

if ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
    die "GITHUB_SHA not 40-hex: $SHA"
fi

short_sha="${SHA:0:7}"
today="$(date -u +%Y%m%d)"

channel=""
version=""
floating_tag=""
immutable_tag=""
should_publish="true"

# Look up the latest stable runtime tag to use as a version-string base for
# dev releases. Best-effort: a clean tree at v0.0.0 is fine for the first
# few dev releases. We require `git` to be on PATH (CI installs it).
latest_stable_version() {
    git tag --list 'runtime-v*' --sort=-v:refname 2>/dev/null \
        | grep -E '^runtime-v[0-9]+\.[0-9]+\.[0-9]+$' \
        | head -n1 \
        | sed 's/^runtime-v//'
}

case "$EVENT" in
    push)
        if [[ "$REF" == refs/tags/runtime-v* ]]; then
            tag="${REF#refs/tags/}"
            if ! [[ "$tag" =~ ^runtime-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                die "stable tag not in runtime-vX.Y.Z form: $tag"
            fi
            channel="stable"
            version="${tag#runtime-v}"
            immutable_tag="$tag"
        elif [[ "$REF" == "refs/heads/dev" ]]; then
            channel="dev"
            base="$(latest_stable_version || true)"
            [[ -n "$base" ]] || base="0.0.0"
            version="${base}-dev-${today}-${short_sha}"
            immutable_tag="runtime-dev-${today}-${short_sha}"
            floating_tag="runtime-dev-latest"
        else
            die "unsupported push ref: $REF"
        fi
        ;;
    workflow_dispatch)
        if [[ "$INPUT_CHANNEL" != "stable" && "$INPUT_CHANNEL" != "dev" ]]; then
            die "workflow_dispatch requires inputs.channel=stable|dev (got: '$INPUT_CHANNEL')"
        fi
        channel="$INPUT_CHANNEL"
        if [[ "$channel" == "stable" ]]; then
            if [[ -z "$INPUT_VERSION" ]]; then
                die "workflow_dispatch channel=stable requires inputs.version (e.g. 1.4.0)"
            fi
            if ! [[ "$INPUT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                die "workflow_dispatch stable version must be X.Y.Z (got: $INPUT_VERSION)"
            fi
            version="$INPUT_VERSION"
            immutable_tag="runtime-v${INPUT_VERSION}"
        else
            if [[ -n "$INPUT_VERSION" ]]; then
                if ! [[ "$INPUT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-dev-[0-9]{8}-[0-9a-f]{7,40}$ ]]; then
                    die "workflow_dispatch dev version must be X.Y.Z-dev-YYYYMMDD-<sha> (got: $INPUT_VERSION)"
                fi
                version="$INPUT_VERSION"
                # Derive the immutable tag from the supplied version.
                suffix="${version#*-dev-}"
                immutable_tag="runtime-dev-${suffix}"
            else
                base="$(latest_stable_version || true)"
                [[ -n "$base" ]] || base="0.0.0"
                version="${base}-dev-${today}-${short_sha}"
                immutable_tag="runtime-dev-${today}-${short_sha}"
            fi
            floating_tag="runtime-dev-latest"
        fi
        ;;
    pull_request)
        # PR runs are validation-only — the workflow's sign and publish
        # jobs are gated to skip on pull_request. We still need a sane
        # channel/version/immutable_tag so the build and verify jobs can
        # render a manifest. Treat PR like a dev build (same version
        # shape so build-release.sh's strict regex accepts it). PR
        # number lives in the immutable_tag for log readability only —
        # the tag is never published.
        channel="dev"
        base="$(latest_stable_version || true)"
        [[ -n "$base" ]] || base="0.0.0"
        version="${base}-dev-${today}-${short_sha}"
        immutable_tag="runtime-dev-pr${GITHUB_PR_NUMBER:-0}-${short_sha}"
        floating_tag=""
        should_publish="false"
        ;;
    *)
        die "unsupported event: $EVENT"
        ;;
esac

# Emit. Echo to stdout so the workflow log surfaces the resolved identity,
# and write to $GITHUB_OUTPUT (job outputs) so downstream jobs consume it.
emit() {
    local k="$1" v="$2"
    echo "$k=$v"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "$k=$v" >> "$GITHUB_OUTPUT"
    fi
}

emit channel "$channel"
emit version "$version"
emit floating_tag "$floating_tag"
emit immutable_tag "$immutable_tag"
emit commit_sha "$SHA"
emit should_publish "$should_publish"
