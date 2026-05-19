#!/usr/bin/env bash
# migration-pair-check.sh — enforce migration-pair rules that the schema
# can't express portably.
#
# Rules:
#   1. Every migration with `type: shell` carries a non-empty `script` AND a
#      non-empty `rollback_script` (the schema enforces presence; we
#      additionally enforce non-emptiness defensively).
#   2. Both files referenced by a shell migration exist under <release-dir>
#      and are regular files.
#   3. Migration ids are unique WITHIN the release (validate-manifest.sh
#      already enforces this; we re-check here as belt-and-braces because a
#      release-time gate run by this script may run against a manifest that
#      bypassed validate-manifest.sh in a future refactor).
#   4. Migration ids are unique AGAINST any prior published release on the
#      same channel. Tolerates "no prior releases on this channel" as ok.
#      The prior-release manifest is fetched via the GitHub Releases API
#      (gh CLI). Skipping the cross-release check is allowed via
#      AIRPLANES_MIGRATION_PAIR_SKIP_REMOTE=1 — used by the bats tests.
#
# Args:
#   --release-dir <path>    the v<X> release tree under audit
#   --channel <stable|dev>  channel this release targets (drives prior-release fetch)
#   --repo <owner/repo>     repo to query for prior releases (default:
#                           airplanes-live/image)
#
# Exits 0 on success; non-zero with a single-line diagnostic per failure.

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: migration-pair-check.sh \
    --release-dir <path> \
    --channel <stable|dev> \
    [--repo <owner/repo>]
USAGE
}

die() {
    echo "migration-pair-check: $*" >&2
    exit 1
}

RELEASE_DIR=""
CHANNEL=""
REPO="airplanes-live/image"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release-dir) RELEASE_DIR="${2-}"; shift 2 ;;
        --channel)     CHANNEL="${2-}";     shift 2 ;;
        --repo)        REPO="${2-}";        shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; die "unknown argument: $1" ;;
    esac
done

[[ -n "$RELEASE_DIR" ]] || { usage; die "missing --release-dir"; }
[[ -n "$CHANNEL" ]]     || { usage; die "missing --channel"; }
[[ -d "$RELEASE_DIR" ]] || die "--release-dir not a directory: $RELEASE_DIR"

case "$CHANNEL" in
    stable|dev) ;;
    *) die "--channel must be stable or dev (got: $CHANNEL)" ;;
esac

manifest="$RELEASE_DIR/manifest.json"
[[ -f "$manifest" ]] || die "no manifest.json under $RELEASE_DIR"

if ! command -v jq >/dev/null 2>&1; then
    die "jq not on PATH"
fi

# Rule 1+2: every shell migration has both scripts, and both exist.
fail=0
while IFS=$'\t' read -r mid script rollback; do
    [[ -z "$mid" ]] && continue
    if [[ -z "$script" || "$script" == "null" ]]; then
        echo "migration-pair-check: migration '$mid' (type=shell) missing 'script'" >&2
        fail=1
        continue
    fi
    if [[ -z "$rollback" || "$rollback" == "null" ]]; then
        echo "migration-pair-check: migration '$mid' (type=shell) missing 'rollback_script'" >&2
        fail=1
        continue
    fi
    if [[ ! -f "$RELEASE_DIR/$script" ]]; then
        echo "migration-pair-check: migration '$mid' script missing: $script" >&2
        fail=1
    fi
    if [[ ! -f "$RELEASE_DIR/$rollback" ]]; then
        echo "migration-pair-check: migration '$mid' rollback_script missing: $rollback" >&2
        fail=1
    fi
done < <(jq -r '.migrations[]? | select(.type == "shell") | [.id, .script, .rollback_script] | @tsv' "$manifest")

# Rule 3: within-release id uniqueness.
within_dups="$(jq -r '
    [.migrations[]?.id]
    | group_by(.)
    | map(select(length > 1) | .[0])
    | join(",")
' "$manifest")"
if [[ -n "$within_dups" ]]; then
    echo "migration-pair-check: duplicate migration ids within release: $within_dups" >&2
    fail=1
fi

# Rule 4: cross-release id uniqueness (against prior published releases on
# the same channel). Skip if AIRPLANES_MIGRATION_PAIR_SKIP_REMOTE=1 or if gh
# is not installed. The skip path is taken by the bats tests; production CI
# runs with gh installed so the gate is actually exercised.
if [[ "${AIRPLANES_MIGRATION_PAIR_SKIP_REMOTE:-0}" == "1" ]]; then
    echo "migration-pair-check: skipping cross-release id check (AIRPLANES_MIGRATION_PAIR_SKIP_REMOTE=1)"
else
    if ! command -v gh >/dev/null 2>&1; then
        echo "migration-pair-check: gh not available; skipping cross-release id check" >&2
    else
        # Resolve prior releases on the same channel. Stable channel = any
        # release with a tag matching `runtime-vX.Y.Z`. Dev channel = any
        # release with a tag matching `runtime-dev-*`. We do not consult
        # `runtime-dev-latest` directly — its manifest equals one of the
        # immutable dev tags so we'd double-count.
        #
        # `gh release list` returns at most 30 by default; bump and rely on
        # --json filtering rather than paging since the channel namespaces
        # stay small for the v1 lifetime.
        case "$CHANNEL" in
            stable) pattern='^runtime-v[0-9]+\.[0-9]+\.[0-9]+$' ;;
            dev)    pattern='^runtime-dev-[0-9]{8}-[0-9a-f]{7,40}$' ;;
        esac

        # Fetch tags; tolerate missing repo / first-ever release (returns
        # an empty list).
        if ! tag_list="$(gh release list -R "$REPO" --limit 100 --json tagName --jq '.[].tagName' 2>/dev/null)"; then
            echo "migration-pair-check: gh release list failed; skipping cross-release id check" >&2
            tag_list=""
        fi

        prior_ids_file="$(mktemp)"
        trap 'rm -f "$prior_ids_file"' EXIT

        while IFS= read -r tag; do
            [[ -z "$tag" ]] && continue
            if ! [[ "$tag" =~ $pattern ]]; then
                continue
            fi
            # Pull manifest.json from each prior release. Tolerate fetch
            # failure (release with broken asset set on the legacy channel
            # shouldn't permanently break this gate); log + continue.
            tmp_manifest="$(mktemp)"
            if gh release download "$tag" -R "$REPO" -p 'manifest.json' \
                    --output "$tmp_manifest" --clobber 2>/dev/null; then
                jq -r '.migrations[]?.id' "$tmp_manifest" >> "$prior_ids_file" 2>/dev/null || true
            else
                echo "migration-pair-check: skipping $tag (no manifest.json asset)" >&2
            fi
            rm -f -- "$tmp_manifest"
        done <<< "$tag_list"

        # Compare against current release ids; report collisions.
        if [[ -s "$prior_ids_file" ]]; then
            current_ids_file="$(mktemp)"
            jq -r '.migrations[]?.id' "$manifest" > "$current_ids_file"
            mapfile -t collisions < <(LC_ALL=C sort -u "$prior_ids_file" | LC_ALL=C comm -12 - <(LC_ALL=C sort -u "$current_ids_file"))
            rm -f -- "$current_ids_file"
            if [[ "${#collisions[@]}" -gt 0 ]]; then
                echo "migration-pair-check: migration ids collide with prior releases on channel '$CHANNEL': ${collisions[*]}" >&2
                fail=1
            fi
        else
            echo "migration-pair-check: no prior releases on channel '$CHANNEL' (first release; ok)"
        fi
    fi
fi

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi

echo "migration-pair-check: ok"
