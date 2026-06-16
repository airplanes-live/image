#!/bin/bash
# Generate the release-notes body for a stable airplanes.live feeder image
# release. The body is a combined changelog: the image repo's own PRs since the
# previous stable tag (via GitHub's native release-notes generator) plus a
# per-component section for every overlay pin that changed since that tag.
#
# Components are pinned in runtime-overlay/config-stable. The previous release's
# pins are read from `git show <prev_tag>:runtime-overlay/config-stable`, the new
# pins from the working-tree config passed via --config. For each changed pin a
# single GitHub compare API call yields the commit messages, from which merged
# PRs are extracted (number + title). Org repos that merge via "Merge pull
# request #N" or squash "title (#N)" commits render a PR list; anything without a
# parseable PR number (rebase-merge, upstream repos that commit directly) falls
# back to a compare link + commit count. This is intentional — accurate PR
# recovery for those would cost one API call per commit, and our org repos use
# merge commits.
#
# Usage:
#   build-changelog.sh --repo OWNER/REPO --tag vX.Y.Z --sha HEX \
#       --runtime-version VER --run-url URL --config PATH
#
# Emits markdown to stdout. Internal failures degrade per-component (compare
# link only) and the script still exits 0; the calling workflow keeps a minimal
# fallback for hard failures. `gh` is invoked through ${GH:-gh} so tests stub it.
#
# This is a CI/release script (like scripts/manifest-generator.sh); it is never
# packed into the device runtime overlay.
#
# Backticks inside the single-quoted printf format strings below are intentional
# markdown, not command substitution.
# shellcheck disable=SC2016
set -euo pipefail

GH="${GH:-gh}"

# Component table: label|owner/repo|pin-variable. The repo is explicit rather
# than derived from a *_REPO var because webconfig has no AIRPLANES_WEBCONFIG_REPO
# (its repo is hardcoded in stage-webconfig.sh) and is pinned by release tag.
COMPONENTS=(
    "Feed scripts|airplanes-live/feed|AIRPLANES_FEED_OVERLAY_BRANCH"
    "On-device webconfig|airplanes-live/image-webconfig|AIRPLANES_WEBCONFIG_RELEASE_TAG"
    "Feeder readsb|airplanes-live/readsb|AIRPLANES_FEED_READSB_BRANCH"
    "mlat-client|airplanes-live/mlat-client|AIRPLANES_MLAT_CLIENT_BRANCH"
    "readsb decoder|wiedehopf/readsb|AIRPLANES_READSB_DECODER_BRANCH"
    "tar1090|wiedehopf/tar1090|AIRPLANES_TAR1090_BRANCH"
    "tar1090-db|wiedehopf/tar1090-db|AIRPLANES_TAR1090_DB_BRANCH"
    "graphs1090|wiedehopf/graphs1090|AIRPLANES_GRAPHS1090_BRANCH"
    "dump978|flightaware/dump978|AIRPLANES_DUMP978_BRANCH"
)

# Pin variables to extract from a config file. Kept in sync with COMPONENTS plus
# the webconfig commit SHA (surfaced for provenance; the build gates on it).
PIN_VARS=(
    AIRPLANES_FEED_OVERLAY_BRANCH
    AIRPLANES_WEBCONFIG_RELEASE_TAG
    AIRPLANES_WEBCONFIG_COMMIT_SHA
    AIRPLANES_FEED_READSB_BRANCH
    AIRPLANES_MLAT_CLIENT_BRANCH
    AIRPLANES_READSB_DECODER_BRANCH
    AIRPLANES_TAR1090_BRANCH
    AIRPLANES_TAR1090_DB_BRANCH
    AIRPLANES_GRAPHS1090_BRANCH
    AIRPLANES_DUMP978_BRANCH
)

# ---------------------------------------------------------------------------
# Pure helpers (sourced and exercised directly by test/test_build_changelog.bats)
# ---------------------------------------------------------------------------

# parse_pins: read a config file's text on stdin and print "VAR=value" for each
# PIN_VARS entry, resolved in a scrubbed environment. The config uses
# ${VAR:-default}, so any inherited AIRPLANES_* would corrupt the value; unset
# them in a subshell before evaluating so the file's own defaults win.
parse_pins() {
    local text
    text="$(cat)"
    (
        local v
        for v in $(compgen -v | grep '^AIRPLANES_' || true); do
            unset "$v"
        done
        set -uo pipefail
        # set -e does not abort on an eval syntax error, so check eval directly:
        # a malformed config must fail the whole extraction, not yield empties.
        # shellcheck disable=SC1090,SC2086
        eval "$text" || exit 1
        for v in "${PIN_VARS[@]}"; do
            printf '%s=%s\n' "$v" "${!v-}"
        done
    )
}

# shortref: shorten a 40-hex SHA to 12 chars; leave tags/other refs untouched.
shortref() {
    local r="$1"
    if [[ "$r" =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s' "${r:0:12}"
    else
        printf '%s' "$r"
    fi
}

# sanitize_title: make an externally-authored PR title safe to render on a public
# release page. Strip CR/LF and other control chars, collapse whitespace, escape
# the markdown metacharacters that could inject links/images/code/HTML, and
# defuse @mentions (a zero-width space after @) so a crafted title cannot notify
# users/teams or break the markdown list.
sanitize_title() {
    local t="$1"
    t="${t//$'\r'/ }"
    t="${t//$'\n'/ }"
    t="$(printf '%s' "$t" | tr -d '\000-\010\013\014\016-\037')"
    # Collapse runs of whitespace and trim via word-splitting.
    local -a words
    read -r -a words <<<"$t"
    t="${words[*]}"
    # Backslash-escape ] [ ` < > so a title cannot open a link/image/code span
    # or inline HTML in the release body.
    t="$(printf '%s' "$t" | sed -e 's/[][`<>]/\\&/g')"
    # Insert a zero-width space (U+200B) after every '@' to neutralize mentions.
    local zwsp; zwsp="$(printf '\342\200\213')"
    t="${t//@/@$zwsp}"
    printf '%s' "$t"
}

# extract_prs: read a GitHub compare API JSON document on stdin and print
# "NUMBER<TAB>title" for each merged PR found in the commit messages. Handles
# merge commits ("Merge pull request #N from ...") and default squash commits
# ("title (#N)"). Multi-line-message safe (parsing happens in jq).
extract_prs() {
    jq -r '
      .commits[]?.commit.message
      | (gsub("\r"; "")) as $m
      | ($m | split("\n")) as $lines
      | ($lines[0] // "") as $subj
      | ([$lines[] | select(length > 0)]) as $nonempty
      | if ($subj | test("^Merge pull request #[0-9]+ from "))
        then ($subj | capture("#(?<n>[0-9]+)").n) + "\t" + ($nonempty[1] // "")
        elif ($subj | test("\\(#[0-9]+\\)$"))
        then ($subj | capture("\\(#(?<n>[0-9]+)\\)$").n) + "\t" + ($subj | sub(" *\\(#[0-9]+\\)$"; ""))
        else empty
        end
    '
}

# prev_stable_tag: given the current tag as $1 and a version-descending tag list
# on stdin, print the previous stable (vX.Y.Z) tag, or nothing if none exists.
prev_stable_tag() {
    local current="$1" t
    local -a tags=()
    while read -r t; do
        [[ "$t" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && tags+=("$t")
    done
    local i found=-1
    for i in "${!tags[@]}"; do
        [[ "${tags[$i]}" == "$current" ]] && { found=$i; break; }
    done
    if (( found >= 0 )); then
        local nxt=$((found + 1))
        (( nxt < ${#tags[@]} )) && printf '%s\n' "${tags[$nxt]}"
        return 0
    fi
    # current not in the list yet: fall back to the highest stable tag != current.
    for t in "${tags[@]}"; do
        [[ "$t" != "$current" ]] && { printf '%s\n' "$t"; return 0; }
    done
    return 0
}

# render_component: emit the markdown section for one changed component.
# Args: label repo old new. Uses ${GH} for the compare call; degrades to a
# compare-unavailable form on API failure.
render_component() {
    local label="$1" repo="$2" old="$3" new="$4"
    local short_old short_new compare resp status total
    short_old="$(shortref "$old")"
    short_new="$(shortref "$new")"
    compare="https://github.com/$repo/compare/$old...$new"

    printf '### %s\n\n' "$label"

    if ! resp="$("$GH" api "repos/$repo/compare/$old...$new" 2>/dev/null)" || [[ -z "$resp" ]]; then
        printf -- '- [`%s`](https://github.com/%s/commit/%s) → [`%s`](https://github.com/%s/commit/%s) — compare unavailable\n\n' \
            "$short_old" "$repo" "$old" "$short_new" "$repo" "$new"
        return 0
    fi

    status="$(printf '%s' "$resp" | jq -r '.status // "unknown"')"
    total="$(printf '%s' "$resp" | jq -r '.total_commits // 0')"
    # The compare endpoint caps .commits without pagination, so a jump larger
    # than that page yields a partial commit list. total_commits is the true
    # count; if it exceeds what we received, any parsed PR list is incomplete.
    local got
    got="$(printf '%s' "$resp" | jq -r '.commits | length')"
    [[ "$got" =~ ^[0-9]+$ ]] || got=0
    [[ "$total" =~ ^[0-9]+$ ]] || total=0

    printf -- '- %s → %s · [compare](%s)\n' "$short_old" "$short_new" "$compare"

    local -A seen=()
    local -a prs=()
    local n title
    while IFS=$'\t' read -r n title; do
        [[ -n "$n" ]] || continue
        [[ -n "${seen[$n]:-}" ]] && continue
        seen[$n]=1
        prs+=("$n"$'\t'"$title")
    done < <(printf '%s' "$resp" | extract_prs)

    case "$status" in
        diverged|behind)
            # total_commits is graph-based and misleading here; don't assert it.
            printf -- '  - history diverged — see compare\n' ;;
        *)
            if (( total > got )); then
                # Commit list truncated by the API page limit — a PR list would
                # be partial, so point at the compare instead.
                printf -- '  - %s commit(s) — list truncated, see compare\n' "$total"
            elif (( ${#prs[@]} )); then
                local clean
                while IFS=$'\t' read -r n title; do
                    clean="$(sanitize_title "$title")"
                    if [[ -n "$clean" ]]; then
                        printf -- '  - %s#%s — %s\n' "$repo" "$n" "$clean"
                    else
                        printf -- '  - %s#%s\n' "$repo" "$n"
                    fi
                done < <(printf '%s\n' "${prs[@]}" | sort -t$'\t' -k1,1n)
            else
                printf -- '  - %s commit(s)\n' "$total"
            fi ;;
    esac
    printf '\n'
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

main() {
    local repo="" tag="" sha="" runtime_version="" run_url="" config=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)             repo="$2";            shift 2 ;;
            --tag)              tag="$2";             shift 2 ;;
            --sha)              sha="$2";             shift 2 ;;
            --runtime-version)  runtime_version="$2"; shift 2 ;;
            --run-url)          run_url="$2";         shift 2 ;;
            --config)           config="$2";          shift 2 ;;
            *) echo "unknown argument: $1" >&2; return 2 ;;
        esac
    done
    for req in repo tag sha config; do
        [[ -n "${!req}" ]] || { echo "missing --$req" >&2; return 2; }
    done
    [[ -f "$config" ]] || { echo "config not found: $config" >&2; return 2; }

    emit_meta() {
        printf -- '- Source: `%s @ %s`\n' "$repo" "$sha"
        printf -- '- Runtime overlay: `%s`\n' "$runtime_version"
        printf -- '- Workflow run: %s\n' "$run_url"
    }

    # emit_snapshot: list the current component pins (used when there is no
    # comparable baseline to diff against).
    emit_snapshot() {
        local row label crepo pin val
        for row in "${COMPONENTS[@]}"; do
            IFS='|' read -r label crepo pin <<<"$row"
            val="${NEW[$pin]:-}"
            [[ -n "$val" ]] && printf -- '- %s: `%s`\n' "$label" "$(shortref "$val")"
        done
    }

    # emit_image_section: image-repo changes via GitHub's native generator (the
    # webconfig analog). target_commitish guards workflow-dispatch runs where the
    # tag object may not have resolved yet.
    emit_image_section() {
        local p="$1" imgnotes
        printf '## Image\n\n'
        if imgnotes="$("$GH" api "repos/$repo/releases/generate-notes" \
                -f tag_name="$tag" \
                -f previous_tag_name="$p" \
                -f target_commitish="$sha" \
                --jq '.body' 2>/dev/null)" && [[ -n "$imgnotes" ]]; then
            printf '%s\n\n' "$imgnotes"
        else
            printf -- '- [Compare %s...%s](https://github.com/%s/compare/%s...%s)\n\n' \
                "$p" "$tag" "$repo" "$p" "$tag"
        fi
    }

    printf '# airplanes.live feeder %s\n\n' "$tag"
    printf 'Flashable image and runtime overlay update assets for %s.\n\n' "$tag"

    # NEW pins from the working-tree config. Capture so a parse failure (our own
    # config unparseable) hard-fails into the workflow's minimal fallback rather
    # than silently rendering every component as removed.
    local new_raw
    if ! new_raw="$(parse_pins < "$config")"; then
        echo "failed to parse pins from $config" >&2
        return 1
    fi
    local -A NEW=()
    local k v
    while IFS='=' read -r k v; do
        [[ -n "$k" ]] && NEW[$k]="$v"
    done <<<"$new_raw"

    local prev
    prev="$(git tag --list 'v*' --sort=-v:refname | prev_stable_tag "$tag")"

    if [[ -z "$prev" ]]; then
        # First stable release: no baseline to diff. Metadata + current snapshot.
        emit_meta
        printf '\n## Components\n\n'
        emit_snapshot
        printf '\n'
        return 0
    fi

    # OLD pins from the previous tag's config. If that tag predates the pin file
    # or its config won't parse, we have no comparable baseline — emit the image
    # section plus a current snapshot rather than a misleading all-"Added" diff.
    local old_raw old_parsed
    if ! old_raw="$(git show "$prev:runtime-overlay/config-stable" 2>/dev/null)" \
        || ! old_parsed="$(printf '%s\n' "$old_raw" | parse_pins)"; then
        emit_image_section "$prev"
        printf '## Components\n\n'
        printf -- '_No comparable component baseline in %s; current pins:_\n\n' "$prev"
        emit_snapshot
        printf '\n'
        emit_meta
        return 0
    fi
    local -A OLD=()
    while IFS='=' read -r k v; do
        [[ -n "$k" ]] && OLD[$k]="$v"
    done <<<"$old_parsed"

    emit_image_section "$prev"

    # Component sections (only changed pins).
    local comp_out="" any=0
    local row label crepo pin o n
    for row in "${COMPONENTS[@]}"; do
        IFS='|' read -r label crepo pin <<<"$row"
        o="${OLD[$pin]:-}"
        n="${NEW[$pin]:-}"
        if [[ -z "$n" && -n "$o" ]]; then
            comp_out+="### $label"$'\n\n'"- Removed (was \`$(shortref "$o")\`)"$'\n\n'
            any=1
            continue
        fi
        [[ -n "$n" ]] || continue
        if [[ -z "$o" ]]; then
            comp_out+="### $label"$'\n\n'"- Added: \`$(shortref "$n")\`"$'\n\n'
            any=1
            continue
        fi
        if [[ "$o" == "$n" ]]; then
            # webconfig is pinned by tag for the changelog, but COMMIT_SHA is the
            # build's provenance gate. A re-pin to a new SHA under the same tag
            # would otherwise be invisible — surface it explicitly.
            if [[ "$pin" == "AIRPLANES_WEBCONFIG_RELEASE_TAG" ]]; then
                local osha="${OLD[AIRPLANES_WEBCONFIG_COMMIT_SHA]:-}"
                local nsha="${NEW[AIRPLANES_WEBCONFIG_COMMIT_SHA]:-}"
                if [[ -n "$nsha" && "$osha" != "$nsha" ]]; then
                    comp_out+="### $label"$'\n\n'"- Re-pinned to \`$(shortref "$nsha")\` (release tag \`$n\` unchanged)"$'\n\n'
                    any=1
                fi
            fi
            continue
        fi
        # $(...) strips render_component's trailing blank line; re-add a blank
        # separator so the next ### heading is preceded by an empty line.
        comp_out+="$(render_component "$label" "$crepo" "$o" "$n")"$'\n\n'
        any=1
    done

    printf '## Components\n\n'
    if (( any )); then
        printf '%s' "$comp_out"
    else
        printf 'No component pins changed since %s.\n\n' "$prev"
    fi

    emit_meta
}

# Only run main when executed, not when sourced by the test suite.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
