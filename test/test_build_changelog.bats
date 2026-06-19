#!/usr/bin/env bats

# Tests for scripts/build-changelog.sh, which builds the combined release-notes
# body for a stable image release. The script is sourced so the pure helpers can
# be exercised directly; the BASH_SOURCE guard keeps main() from running. The
# network-facing path (render_component's compare call) is tested by stubbing the
# gh client via the GH override.

setup() {
	REPO_ROOT="$BATS_TEST_DIRNAME/.."
	SCRIPT="$REPO_ROOT/scripts/build-changelog.sh"
	# shellcheck disable=SC1090
	source "$SCRIPT"
	TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

# ---- parse_pins --------------------------------------------------------------

@test "parse_pins applies file defaults and ignores inherited AIRPLANES_* env" {
	export AIRPLANES_FEED_OVERLAY_BRANCH="LEAKED_should_not_appear"
	out="$(printf 'export AIRPLANES_FEED_OVERLAY_BRANCH="${AIRPLANES_FEED_OVERLAY_BRANCH:-abc123}"\n' | parse_pins)"
	unset AIRPLANES_FEED_OVERLAY_BRANCH
	[[ "$out" == *"AIRPLANES_FEED_OVERLAY_BRANCH=abc123"* ]]
	[[ "$out" != *"LEAKED"* ]]
}

@test "parse_pins reads the real config-stable (PIN_VARS stay aligned with the file)" {
	out="$(parse_pins < "$REPO_ROOT/runtime-overlay/config-stable")"
	tar1090="$(sed -n 's/^AIRPLANES_TAR1090_BRANCH=//p' <<<"$out")"
	wc_tag="$(sed -n 's/^AIRPLANES_WEBCONFIG_RELEASE_TAG=//p' <<<"$out")"
	[[ "$tar1090" =~ ^[0-9a-f]{40}$ ]]
	[[ "$wc_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# ---- shortref ----------------------------------------------------------------

@test "shortref truncates a 40-hex SHA to 12 and passes tags through" {
	sha="$(printf '%040d' 0 | tr 0 a)"
	[ "$(shortref "$sha")" = "aaaaaaaaaaaa" ]
	[ "$(shortref v0.2.0)" = "v0.2.0" ]
	[ "$(shortref abc123)" = "abc123" ]
}

# ---- prev_stable_tag ---------------------------------------------------------

@test "prev_stable_tag returns the tag below current" {
	out="$(printf 'v0.2.0\nv0.1.0\nv0.0.1\n' | prev_stable_tag v0.2.0)"
	[ "$out" = "v0.1.0" ]
}

@test "prev_stable_tag is empty when current is the only stable tag" {
	out="$(printf 'v0.1.0\n' | prev_stable_tag v0.1.0)"
	[ -z "$out" ]
}

@test "prev_stable_tag ignores non-semver tags and dev throwaways" {
	out="$(printf 'v0.2.0\ndev-latest\nv0.1.0\nv0.0.1\n' | prev_stable_tag v0.2.0)"
	[ "$out" = "v0.1.0" ]
}

@test "prev_stable_tag falls back to highest tag when current absent from list" {
	out="$(printf 'v0.1.0\nv0.0.1\n' | prev_stable_tag v9.9.9)"
	[ "$out" = "v0.1.0" ]
}

# ---- extract_prs -------------------------------------------------------------

@test "extract_prs parses merge, squash, and skips plain commits" {
	cat > "$TMP/c.json" <<'JSON'
{"status":"ahead","total_commits":3,"commits":[
 {"commit":{"message":"Merge pull request #137 from x/y\n\nfix(feed-env): handle empty value"}},
 {"commit":{"message":"feat(config): add thing (#135)"}},
 {"commit":{"message":"chore: no pr number"}}
]}
JSON
	out="$(extract_prs < "$TMP/c.json")"
	[[ "$out" == *$'137\tfix(feed-env): handle empty value'* ]]
	[[ "$out" == *$'135\tfeat(config): add thing'* ]]
	[[ "$out" != *"no pr number"* ]]
}

@test "extract_prs tolerates CRLF in commit messages" {
	# CRLF arrives JSON-escaped (\r\n) from the API; jq decodes to real CR/LF,
	# which extract_prs strips. The quoted heredoc keeps the escapes literal.
	cat > "$TMP/c.json" <<'JSON'
{"commits":[{"commit":{"message":"Merge pull request #5 from a/b\r\n\r\ntitle here\r\n"}}]}
JSON
	out="$(extract_prs < "$TMP/c.json")"
	[[ "$out" == *$'5\ttitle here'* ]]
	[[ "$out" != *$'\r'* ]]
}

# ---- sanitize_title ----------------------------------------------------------

@test "sanitize_title strips CR/LF and collapses whitespace" {
	out="$(sanitize_title $'a\r\nb    c\td')"
	[ "$out" = "a b c d" ]
}

@test "sanitize_title inserts a zero-width space after @ to defuse mentions" {
	sanitize_title "ping @team now" | xxd -p | tr -d '\n' | grep -q '40e2808b'
}

@test "sanitize_title escapes markdown link/image/code/HTML metacharacters" {
	out="$(sanitize_title 'fix [evil](http://x) and `code` and <b>')"
	[[ "$out" == *'\[evil\]'* ]]
	[[ "$out" == *'\`code\`'* ]]
	[[ "$out" == *'\<b\>'* ]]
}

# ---- render_component (stubbed GH) -------------------------------------------

_stub_gh() { # $1 = file to cat, or "fail"
	if [ "$1" = "fail" ]; then
		printf '#!/bin/bash\nexit 1\n' > "$TMP/gh"
	else
		printf '#!/bin/bash\ncat %q\n' "$1" > "$TMP/gh"
	fi
	chmod +x "$TMP/gh"
	GH="$TMP/gh"
}

@test "render_component lists qualified PRs sorted by number for an ahead range" {
	cat > "$TMP/c.json" <<'JSON'
{"status":"ahead","total_commits":2,"commits":[
 {"commit":{"message":"Merge pull request #137 from x/y\n\nfix: b"}},
 {"commit":{"message":"feat: a (#135)"}}
]}
JSON
	_stub_gh "$TMP/c.json"
	run render_component "Feed scripts" "airplanes-live/feed" "aaaa" "bbbb"
	[ "$status" -eq 0 ]
	[[ "$output" == *"### Feed scripts"* ]]
	[[ "$output" == *"airplanes-live/feed#135 — feat: a"* ]]
	[[ "$output" == *"airplanes-live/feed#137 — fix: b"* ]]
	# 135 must render before 137
	[[ "$(grep -n '#135' <<<"$output" | cut -d: -f1)" -lt "$(grep -n '#137' <<<"$output" | cut -d: -f1)" ]]
}

@test "render_component dedupes a PR seen on multiple commits" {
	cat > "$TMP/c.json" <<'JSON'
{"status":"ahead","total_commits":2,"commits":[
 {"commit":{"message":"Merge pull request #42 from x/y\n\ntitle"}},
 {"commit":{"message":"backport (#42)"}}
]}
JSON
	_stub_gh "$TMP/c.json"
	run render_component "X" "airplanes-live/x" "aaaa" "bbbb"
	[ "$status" -eq 0 ]
	[ "$(grep -c '#42' <<<"$output")" -eq 1 ]
}

@test "render_component shows a commit count when no PRs are present (ahead, complete)" {
	cat > "$TMP/c.json" <<'JSON'
{"status":"ahead","total_commits":2,"commits":[
 {"commit":{"message":"direct commit one"}},
 {"commit":{"message":"direct commit two"}}
]}
JSON
	_stub_gh "$TMP/c.json"
	run render_component "tar1090" "wiedehopf/tar1090" "aaaa" "bbbb"
	[ "$status" -eq 0 ]
	[[ "$output" == *"2 commit(s)"* ]]
	[[ "$output" != *"truncated"* ]]
}

@test "render_component flags a truncated commit list (total > received)" {
	# total_commits exceeds the returned .commits page, so any PR list is partial.
	cat > "$TMP/c.json" <<'JSON'
{"status":"ahead","total_commits":300,"commits":[
 {"commit":{"message":"Merge pull request #1 from a/b\n\nonly one we can see"}}
]}
JSON
	_stub_gh "$TMP/c.json"
	run render_component "Feeder readsb" "airplanes-live/readsb" "aaaa" "bbbb"
	[ "$status" -eq 0 ]
	[[ "$output" == *"300 commit(s) — list truncated, see compare"* ]]
	# Must NOT render a partial PR list.
	[[ "$output" != *"#1 —"* ]]
}

@test "render_component avoids a misleading count when history diverged" {
	cat > "$TMP/c.json" <<'JSON'
{"status":"diverged","total_commits":999,"commits":[
 {"commit":{"message":"upstream rebase"}}
]}
JSON
	_stub_gh "$TMP/c.json"
	run render_component "readsb decoder" "wiedehopf/readsb" "aaaa" "bbbb"
	[ "$status" -eq 0 ]
	[[ "$output" == *"history diverged"* ]]
	[[ "$output" != *"999 commit"* ]]
}

@test "render_component degrades to commit links when the compare API fails" {
	_stub_gh fail
	run render_component "dump978" "flightaware/dump978" "aaaa" "bbbb"
	[ "$status" -eq 0 ]
	[[ "$output" == *"compare unavailable"* ]]
	[[ "$output" == *"flightaware/dump978/commit/aaaa"* ]]
	[[ "$output" == *"flightaware/dump978/commit/bbbb"* ]]
}

# ---- main() integration (throwaway git repo, stubbed gh) ---------------------

_init_repo() { # creates $TMP/repo as CWD with a config-stable committed + tagged
	mkdir -p "$TMP/repo/runtime-overlay"
	cd "$TMP/repo"
	git init -q
	git config user.email t@example.com
	git config user.name tester
	printf '#!/bin/bash\nprintf "## What'\''s Changed\\n- x\\n"\n' > "$TMP/ghnotes"
	chmod +x "$TMP/ghnotes"
	GH="$TMP/ghnotes"
}

@test "main surfaces a webconfig SHA re-pin under an unchanged release tag" {
	_init_repo
	cat > runtime-overlay/config-stable <<'CFG'
export AIRPLANES_WEBCONFIG_RELEASE_TAG="${AIRPLANES_WEBCONFIG_RELEASE_TAG:-v0.1.3}"
export AIRPLANES_WEBCONFIG_COMMIT_SHA="${AIRPLANES_WEBCONFIG_COMMIT_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
CFG
	git add -A && git commit -qm base && git tag v0.1.0
	# Re-pin only the commit SHA; the release tag stays v0.1.3.
	sed -i 's/aaaaaaaa/bbbbbbbb/' runtime-overlay/config-stable
	run main --repo o/r --tag v0.2.0 --sha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
		--runtime-version 0.2.0 --run-url http://run --config runtime-overlay/config-stable
	[ "$status" -eq 0 ]
	[[ "$output" == *"Re-pinned to"* ]]
	[[ "$output" == *"release tag \`v0.1.3\` unchanged"* ]]
}

@test "main falls back to a snapshot when the previous tag has no pin file" {
	_init_repo
	echo "placeholder" > README.md
	git add -A && git commit -qm base && git tag v0.1.0
	# config-stable only exists in the working tree, not at v0.1.0.
	cat > runtime-overlay/config-stable <<'CFG'
export AIRPLANES_TAR1090_BRANCH="${AIRPLANES_TAR1090_BRANCH:-cccccccccccccccccccccccccccccccccccccccc}"
CFG
	run main --repo o/r --tag v0.2.0 --sha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
		--runtime-version 0.2.0 --run-url http://run --config runtime-overlay/config-stable
	[ "$status" -eq 0 ]
	[[ "$output" == *"No comparable component baseline in v0.1.0"* ]]
	[[ "$output" == *"tar1090: \`cccccccccccc\`"* ]]
}

@test "main hard-fails (nonzero) when the working-tree config cannot be parsed" {
	_init_repo
	echo "ignore" > README.md
	git add -A && git commit -qm base && git tag v0.1.0
	printf 'export FOO="unterminated\n' > runtime-overlay/config-stable
	run main --repo o/r --tag v0.2.0 --sha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
		--runtime-version 0.2.0 --run-url http://run --config runtime-overlay/config-stable
	[ "$status" -ne 0 ]
}
