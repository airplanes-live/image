#!/usr/bin/env bash
# resolve-channel-and-tags.sh — derive the unified product release identity
# (channel, version, release tag) for one workflow run.
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
#                        semver+suffix (dev). Optional for dev.
#
# Outputs (written to $GITHUB_OUTPUT, also echoed on stdout):
#   channel        stable | dev
#   version        the semver string the manifest will carry
#   release_tag    vX.Y.Z (stable) | dev-latest (dev) | synthetic PR tag
#   prerelease     true | false
#   commit_sha     full 40-hex commit SHA
#   should_publish true | false
#   augment_version true | false — whether build-runtime-assets.sh should fold
#                  a bundled-payload fingerprint into the synthesised dev version
#
# Behaviour matrix:
#   - On `tags/v*` push:
#       channel=stable, version=tag minus the v prefix,
#       release_tag=<tag>, prerelease=false, should_publish=true.
#   - On `branches/dev` push:
#       channel=dev, version=<latest-stable-or-0.0.0>-dev-<YYYYMMDD>-<sha7>,
#       release_tag=dev-latest, prerelease=true, should_publish=true.
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
release_tag=""
prerelease="false"
should_publish="true"
# Only a version this script *synthesises* may be fingerprinted downstream. A
# version supplied verbatim (stable tag, explicit INPUT_VERSION) must publish
# exactly as given, so it defaults to false and is flipped true only in the
# synthesise branches below.
augment_version="false"

# Look up the latest stable product tag to use as a version-string base for
# dev releases. Best-effort: a clean tree at v0.0.0 is fine for the first
# few dev releases. We require `git` to be on PATH (CI installs it).
latest_stable_version() {
    git tag --list 'v*' --sort=-v:refname 2>/dev/null \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | head -n1 \
        | sed 's/^v//'
}

case "$EVENT" in
    push)
        if [[ "$REF" == refs/tags/v* ]]; then
            tag="${REF#refs/tags/}"
            if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                die "stable tag not in vX.Y.Z form: $tag"
            fi
            channel="stable"
            version="${tag#v}"
            release_tag="$tag"
            prerelease="false"
        elif [[ "$REF" == "refs/heads/dev" ]]; then
            channel="dev"
            base="$(latest_stable_version || true)"
            [[ -n "$base" ]] || base="0.0.0"
            version="${base}-dev-${today}-${short_sha}"
            release_tag="dev-latest"
            prerelease="true"
            augment_version="true"
        elif [[ "$REF" == "refs/heads/main" ]]; then
            channel="stable"
            version="$(latest_stable_version || true)"
            [[ -n "$version" ]] || version="0.0.0"
            release_tag="main-validation-${short_sha}"
            prerelease="false"
            should_publish="false"
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
            release_tag="v${INPUT_VERSION}"
            prerelease="false"
        else
            if [[ -n "$INPUT_VERSION" ]]; then
                if ! [[ "$INPUT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-dev-[0-9]{8}-[0-9a-f]{7,40}$ ]]; then
                    die "workflow_dispatch dev version must be X.Y.Z-dev-YYYYMMDD-<sha> (got: $INPUT_VERSION)"
                fi
                version="$INPUT_VERSION"
            else
                base="$(latest_stable_version || true)"
                [[ -n "$base" ]] || base="0.0.0"
                version="${base}-dev-${today}-${short_sha}"
                augment_version="true"
            fi
            release_tag="dev-latest"
            prerelease="true"
        fi
        ;;
    pull_request)
        # PR runs are validation-only — publish jobs are gated to skip on
        # pull_request, while signing uses a temporary test key. We still need a sane
        # channel/version/release_tag so the build and verify jobs can
        # render a manifest. Treat PR like a dev build (same version
        # shape so build-release.sh's strict regex accepts it). PR
        # number lives in the release_tag for log readability only —
        # the tag is never published.
        channel="dev"
        base="$(latest_stable_version || true)"
        [[ -n "$base" ]] || base="0.0.0"
        version="${base}-dev-${today}-${short_sha}"
        release_tag="pr-${GITHUB_PR_NUMBER:-0}-${short_sha}"
        prerelease="true"
        should_publish="false"
        augment_version="true"
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
emit release_tag "$release_tag"
emit prerelease "$prerelease"
emit commit_sha "$SHA"
emit should_publish "$should_publish"
emit augment_version "$augment_version"
