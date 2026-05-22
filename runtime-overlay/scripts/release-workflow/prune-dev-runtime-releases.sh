#!/usr/bin/env bash
# prune-dev-runtime-releases.sh - delete stale immutable runtime-dev releases.
#
# Retention is additive:
#   - keep the newest RUNTIME_DEV_RELEASE_KEEP_COUNT immutable dev releases;
#   - keep releases created within RUNTIME_DEV_RELEASE_KEEP_DAYS days;
#   - keep any --protected-tag values, even if old.
#
# Only tags matching runtime-dev-YYYYMMDD-<sha> are eligible. The floating
# runtime-dev-latest release and stable runtime-v* releases are ignored.

set -euo pipefail

die() {
    echo "prune-dev-runtime-releases: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'USAGE'
Usage: prune-dev-runtime-releases.sh [--repo owner/name] [--protected-tag tag]

Environment:
  GITHUB_REPOSITORY                 default repo when --repo is omitted
  RUNTIME_DEV_RELEASE_KEEP_COUNT    newest immutable dev releases to retain (default: 5)
  RUNTIME_DEV_RELEASE_KEEP_DAYS     age window to retain, in days (default: 14)
  RUNTIME_DEV_RELEASE_DRY_RUN       true|false (default: true)
  RUNTIME_DEV_RELEASE_LIST_LIMIT    gh release list limit (default: 1000)

Test-only environment:
  RUNTIME_DEV_RELEASES_JSON         JSON array with tagName and createdAt
  RUNTIME_DEV_RELEASE_NOW_EPOCH     fixed "now" epoch for age calculation
USAGE
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

repo="${GITHUB_REPOSITORY:-}"
protected_tags=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            [[ $# -ge 2 ]] || die "--repo requires a value"
            repo="$2"
            shift 2
            ;;
        --protected-tag)
            [[ $# -ge 2 ]] || die "--protected-tag requires a value"
            protected_tags+=("$2")
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n "$repo" ]] || die "missing --repo or GITHUB_REPOSITORY"

keep_count="${RUNTIME_DEV_RELEASE_KEEP_COUNT:-5}"
keep_days="${RUNTIME_DEV_RELEASE_KEEP_DAYS:-14}"
dry_run="${RUNTIME_DEV_RELEASE_DRY_RUN:-true}"
list_limit="${RUNTIME_DEV_RELEASE_LIST_LIMIT:-1000}"
now_epoch="${RUNTIME_DEV_RELEASE_NOW_EPOCH:-$(date -u +%s)}"

is_uint "$keep_count" || die "RUNTIME_DEV_RELEASE_KEEP_COUNT must be an unsigned integer"
is_uint "$keep_days" || die "RUNTIME_DEV_RELEASE_KEEP_DAYS must be an unsigned integer"
is_uint "$list_limit" || die "RUNTIME_DEV_RELEASE_LIST_LIMIT must be an unsigned integer"
is_uint "$now_epoch" || die "RUNTIME_DEV_RELEASE_NOW_EPOCH must be an unsigned integer epoch"

case "$dry_run" in
    true|false) ;;
    *) die "RUNTIME_DEV_RELEASE_DRY_RUN must be true or false" ;;
esac

fetch_releases_json() {
    if [[ -n "${RUNTIME_DEV_RELEASES_JSON:-}" ]]; then
        printf '%s\n' "$RUNTIME_DEV_RELEASES_JSON"
        return
    fi

    command -v gh >/dev/null 2>&1 || die "gh is required"
    gh release list \
        -R "$repo" \
        --limit "$list_limit" \
        --json tagName,createdAt
}

command -v jq >/dev/null 2>&1 || die "jq is required"

declare -A protected=()
for tag in "${protected_tags[@]}"; do
    [[ -n "$tag" ]] || continue
    protected["$tag"]=1
done

release_json="$(fetch_releases_json)"
candidate_tsv="$(
    jq -r '
        map(select(.tagName | test("^runtime-dev-[0-9]{8}-[0-9a-f]{7,40}$")))
        | sort_by(.createdAt)
        | reverse
        | .[]
        | [.createdAt, .tagName]
        | @tsv
    ' <<<"$release_json"
)"

if [[ -z "$candidate_tsv" ]]; then
    echo "No immutable runtime-dev releases found in $repo."
    exit 0
fi

cutoff_epoch=0
if (( keep_days > 0 )); then
    cutoff_epoch=$((now_epoch - keep_days * 86400))
fi

index=0
to_delete=()

echo "Runtime dev release cleanup policy:"
echo "  repo: $repo"
echo "  keep_count: $keep_count"
echo "  keep_days: $keep_days"
echo "  dry_run: $dry_run"
if ((${#protected_tags[@]} > 0)); then
    printf '  protected_tags: %s\n' "${protected_tags[*]}"
else
    echo "  protected_tags: none"
fi

while IFS=$'\t' read -r created_at tag; do
    [[ -n "$tag" ]] || continue

    reason=""
    if [[ -n "${protected[$tag]:-}" ]]; then
        reason="protected"
    elif (( index < keep_count )); then
        reason="newest"
    else
        if ! created_epoch="$(date -u -d "$created_at" +%s 2>/dev/null)"; then
            die "could not parse createdAt for $tag: $created_at"
        fi
        if (( keep_days > 0 && created_epoch >= cutoff_epoch )); then
            reason="age"
        fi
    fi

    if [[ -n "$reason" ]]; then
        echo "keep   $tag ($created_at; $reason)"
    else
        echo "delete $tag ($created_at)"
        to_delete+=("$tag")
    fi

    index=$((index + 1))
done <<<"$candidate_tsv"

if ((${#to_delete[@]} == 0)); then
    echo "No stale immutable runtime-dev releases to delete."
    exit 0
fi

if [[ "$dry_run" == "true" ]]; then
    echo "Dry run only; would delete ${#to_delete[@]} release(s)."
    exit 0
fi

for tag in "${to_delete[@]}"; do
    gh release delete "$tag" -R "$repo" --yes --cleanup-tag
done

echo "Deleted ${#to_delete[@]} stale immutable runtime-dev release(s)."
