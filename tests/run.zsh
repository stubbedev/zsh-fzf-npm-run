#!/bin/zsh
# Smoke test for zsh-fzf-npm-run.
#
# Run: zsh tests/run.zsh   (or `just smoke`, which builds first)
#
# Verifies the plugin sources cleanly and locates the engine, then drives the
# npm-run-comp binary against a scratch project across the behaviours the shim
# relies on. Unit-level logic is covered by `cargo test`.

typeset -i _PASS=0 _FAIL=0

_green()  { printf '\033[32m%s\033[0m' "$1" }
_red()    { printf '\033[31m%s\033[0m' "$1" }

pass() { printf '%s %s\n' "$(_green 'ok')" "$1"; ((_PASS++)) }
fail() { printf '%s %s\n' "$(_red 'FAIL')" "$1"
         [[ -n "${2:-}" ]] && printf '     %s\n' "$2"; ((_FAIL++)) }

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    [[ "$haystack" == *"$needle"* ]] && pass "$desc" || fail "$desc" "'$needle' not in output"
}
assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    [[ "$haystack" != *"$needle"* ]] && pass "$desc" || fail "$desc" "'$needle' unexpectedly present"
}

section() { printf '\n── %s ──\n' "$1" }

PLUGIN_DIR="${0:a:h}/.."
BIN="$PLUGIN_DIR/target/release/npm-run-comp"
[[ -x "$BIN" ]] || BIN="$PLUGIN_DIR/target/debug/npm-run-comp"
if [[ ! -x "$BIN" ]]; then
    printf 'ERROR: build first (cargo build --release or `just smoke`)\n' >&2
    exit 1
fi

# ── plugin sourcing ──────────────────────────────────────────────────────────

section "plugin"
compdef() { : }   # provided by compinit in a real shell; stub for scripts
if source "$PLUGIN_DIR/zsh-fzf-npm-run.plugin.zsh" 2>/dev/null; then
    pass "plugin sources cleanly"
else
    fail "plugin failed to source"
fi
if functions _npm_run_comp >/dev/null; then pass "completion function defined"
else fail "completion function missing"; fi

# ── scratch project ──────────────────────────────────────────────────────────

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
cat > "$TMP/package.json" << 'EOF'
{ "scripts": { "dev": "vite", "build": "tsc && vite build", "test": "vitest" } }
EOF
mkdir -p "$TMP/node_modules/.bin"
touch "$TMP/node_modules/.bin/vite" "$TMP/node_modules/.bin/eslint"
mkdir -p "$TMP/packages/api"
echo '{ "scripts": { "serve": "node ." } }' > "$TMP/packages/api/package.json"

comp() { "$BIN" complete --cwd "$TMP" --current "$1" -- "${@:2}" }

section "npm"
out=$(comp 2 npm "")
assert_contains "base offers run alias"      "$(printf 'run\t')"  "$out"
assert_contains "base merges scraped extras" "install"            "$out"

out=$(comp 3 npm run "")
assert_contains "npm run lists scripts"      "$(printf 'dev\t')"  "$out"
assert_not_contains "no [script] label under run" "[script]"      "$out"

out=$(comp 4 npm run --silent "")
assert_contains "scripts survive a flag after run" "$(printf 'build\t')" "$out"

out=$(comp 5 npm --prefix packages/api run "")
assert_contains "--prefix resolves nested package.json" "$(printf 'serve\t')" "$out"
assert_not_contains "nested scope excludes root scripts" "$(printf 'dev\t')"   "$out"

comp 3 npm install "" && fail "npm install should defer (exit 0)" || pass "npm install defers to default"

section "executors"
out=$(comp 2 npx "")
assert_contains "npx lists node_modules/.bin" "vite" "$out"
assert_contains "npx lists all bins"          "eslint" "$out"

section "flags"
# Requires npm on PATH (present in CI); skip cleanly otherwise.
if command -v npm >/dev/null 2>&1; then
    out=$(comp 3 npm install "-")
    assert_contains "npm install -<tab> offers --save-dev" "$(printf 'save-dev\t')" "$out"
else
    printf 'skip flags (npm absent)\n'
fi

# ── summary ──────────────────────────────────────────────────────────────────

printf '\n─────────────────────────────────\n'
printf '  %s passed  %s failed\n' "$(_green $_PASS)" \
    "$( ((_FAIL > 0)) && _red $_FAIL || printf '%d' $_FAIL )"
printf '─────────────────────────────────\n'
((_FAIL == 0))
