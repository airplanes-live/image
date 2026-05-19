# shellcheck shell=bash
# manifest-render.sh — pure library, source me, do not execute.
#
# Composes a runtime-overlay release manifest (manifest.json) from a set of
# pre-staged JSON snippets in an input directory plus a handful of build-time
# arguments. The output is byte-deterministic across runs given identical
# inputs and identical --build-date.
#
# Inputs expected under <input-dir>:
#
#   components.json         {"<name>": "<git-sha>", ...}                  required
#   managed_paths.json      [ { ... }, ... ]                              optional
#   mutable_paths.json      [ "/abs/path", ... ]                          optional
#   systemd.json            {"enable":[],"disable":[],"daemon_reload":true} optional
#   migrations.json         [ { ... }, ... ]                              optional
#   compat.json             { "requires_webconfig": "...", ... }          optional
#
# Missing optional files default to a sensible empty value (arrays → [],
# compat → {}, systemd → {enable:[],disable:[],daemon_reload:true}). A missing
# components.json is a hard error — every release has at least one component
# pinned.
#
# All output passes through `jq -S` so key ordering is canonical at every
# nesting level — that property is what makes the build byte-deterministic
# and what test_build_release_layout.bats relies on.

# airplanes_runtime_render_manifest <version> <channel> <commit_sha> \
#                                   <build_date> <arch> <input-dir> <output-path>
airplanes_runtime_render_manifest() {
    if [[ $# -ne 7 ]]; then
        echo "airplanes_runtime_render_manifest: expected 7 args, got $#" >&2
        return 2
    fi

    local version="$1"
    local channel="$2"
    local commit_sha="$3"
    local build_date="$4"
    local arch="$5"
    local input_dir="$6"
    local output_path="$7"

    if [[ ! -d "$input_dir" ]]; then
        echo "airplanes_runtime_render_manifest: input dir not found: $input_dir" >&2
        return 2
    fi

    local components_path="${input_dir}/components.json"
    if [[ ! -f "$components_path" ]]; then
        echo "airplanes_runtime_render_manifest: required components.json not found in $input_dir" >&2
        return 2
    fi
    if ! jq -e 'type == "object"' "$components_path" >/dev/null 2>&1; then
        echo "airplanes_runtime_render_manifest: components.json must be a JSON object" >&2
        return 1
    fi

    # Resolve optional snippets to either the on-disk file or a literal empty
    # default. jq's --slurpfile cannot accept missing paths, so we materialize
    # the defaults via heredoc-free `printf` into per-snippet tempfiles. Each
    # tempfile holds a single JSON document.
    local tmpdir
    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$tmpdir'" RETURN

    _airplanes_runtime_resolve_snippet \
        "$input_dir/managed_paths.json" "[]" "$tmpdir/managed_paths.json" || return 1
    _airplanes_runtime_resolve_snippet \
        "$input_dir/mutable_paths.json" "[]" "$tmpdir/mutable_paths.json" || return 1
    _airplanes_runtime_resolve_snippet \
        "$input_dir/systemd.json" \
        '{"enable":[],"disable":[],"daemon_reload":true}' \
        "$tmpdir/systemd.json" || return 1
    _airplanes_runtime_resolve_snippet \
        "$input_dir/migrations.json" "[]" "$tmpdir/migrations.json" || return 1
    _airplanes_runtime_resolve_snippet \
        "$input_dir/compat.json" "{}" "$tmpdir/compat.json" || return 1

    # Compose. Top-level keys are projected explicitly so the manifest shape
    # cannot drift on a snippet that smuggles extra keys. compat is omitted
    # when empty so the schema's additionalProperties:false constraint stays
    # happy (the field itself is optional).
    local rendered
    rendered="$(
        jq -nS \
            --arg version "$version" \
            --arg channel "$channel" \
            --arg commit_sha "$commit_sha" \
            --arg build_date "$build_date" \
            --arg arch "$arch" \
            --slurpfile components  "$components_path" \
            --slurpfile managed     "$tmpdir/managed_paths.json" \
            --slurpfile mutable     "$tmpdir/mutable_paths.json" \
            --slurpfile systemd     "$tmpdir/systemd.json" \
            --slurpfile migrations  "$tmpdir/migrations.json" \
            --slurpfile compat      "$tmpdir/compat.json" \
            '{
                version:       $version,
                channel:       $channel,
                commit_sha:    $commit_sha,
                build_date:    $build_date,
                arches:        [ $arch ],
                components:    $components[0],
                managed_paths: $managed[0],
                mutable_paths: $mutable[0],
                systemd:       $systemd[0],
                migrations:    $migrations[0]
            }
            | if ($compat[0] | length) > 0 then .compat = $compat[0] else . end'
    )" || {
        echo "airplanes_runtime_render_manifest: jq composition failed" >&2
        return 1
    }

    # Atomic write so a partial manifest never appears on disk.
    local tmp_out
    tmp_out="$(mktemp "${output_path}.XXXXXX")"
    printf '%s\n' "$rendered" > "$tmp_out"
    mv -f -- "$tmp_out" "$output_path"
}

# Internal helper. Copies <src> to <dst> if it exists, else writes <default>
# (which must itself be a valid JSON document) to <dst>. The default is
# parsed by jq to keep this gate consistent with the validation we apply to
# user-supplied input.
_airplanes_runtime_resolve_snippet() {
    local src="$1"
    local default_json="$2"
    local dst="$3"

    if [[ -f "$src" ]]; then
        if ! jq -e . "$src" >/dev/null 2>&1; then
            echo "airplanes_runtime_render_manifest: not valid JSON: $src" >&2
            return 1
        fi
        cp -- "$src" "$dst"
    else
        if ! jq -e . <<<"$default_json" >"$dst" 2>/dev/null; then
            echo "airplanes_runtime_render_manifest: internal: invalid default JSON literal" >&2
            return 1
        fi
    fi
}
