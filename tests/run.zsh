#!/bin/zsh
# Test suite for zsh-fzf-npm-run
#
# Run: zsh tests/run.zsh
#
# Requirements: zsh. jq or node or deno for JSON parsing tests.

# ── Framework ─────────────────────────────────────────────────────────────────

typeset -i _PASS=0 _FAIL=0 _SKIP=0

_green()  { printf '\033[32m%s\033[0m' "$1" }
_red()    { printf '\033[31m%s\033[0m' "$1" }
_yellow() { printf '\033[33m%s\033[0m' "$1" }

pass() { printf '%s %s\n' "$(_green 'ok')" "$1";           ((_PASS++)) }
fail() { printf '%s %s\n' "$(_red   'FAIL')" "$1";
         [[ -n "${2:-}" ]] && printf '     %s\n' "$2";      ((_FAIL++)) }
skip() { printf '%s %s\n' "$(_yellow 'skip')" "$1";        ((_SKIP++)) }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc" "expected: $(printf '%s' "$expected" | head -3)"$'\n'"     actual:   $(printf '%s' "$actual" | head -3)"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc" "'$needle' not found in output"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc" "'$needle' unexpectedly found in output"
    fi
}

assert_empty() {
    local desc="$1" value="$2"
    if [[ -z "$value" ]]; then
        pass "$desc"
    else
        fail "$desc" "expected empty, got: $(printf '%s' "$value" | head -3)"
    fi
}

assert_file_exists() {
    local desc="$1" file="$2"
    if [[ -f "$file" ]]; then pass "$desc"
    else fail "$desc" "file not found: $file"
    fi
}

section() { printf '\n── %s ──\n' "$1" }

# ── Environment setup ─────────────────────────────────────────────────────────

TMPROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPROOT" }
trap cleanup EXIT INT TERM

# Mock fzf as a real executable in a temp bin on PATH so 'command -v fzf' finds it.
# It outputs the first non-empty line it receives (deterministic, non-interactive).
mkdir -p "${TMPROOT}/bin"
cat > "${TMPROOT}/bin/fzf" << 'EOF'
#!/bin/sh
while IFS= read -r line; do
    [ -n "$line" ] && printf '%s\n' "$line" && exit 0
done
EOF
chmod +x "${TMPROOT}/bin/fzf"
export PATH="${TMPROOT}/bin:$PATH"

# compdef is provided by compinit; stub it so the plugin loads in plain scripts.
compdef() { : }

# Source the plugin (registration loops will call compdef no-op and define _<cmd> fns).
PLUGIN="${0:a:h}/../zsh-fzf-npm-run.plugin.zsh"
if ! source "$PLUGIN" 2>/dev/null; then
    printf 'ERROR: failed to source plugin at %s\n' "$PLUGIN" >&2
    exit 1
fi

# Override cache dir AFTER sourcing — the plugin sets it to ~/.cache on load.
PACKAGE_COMPLETIONS_CACHE_DIR="${TMPROOT}/cache"
mkdir -p "$PACKAGE_COMPLETIONS_CACHE_DIR"

# Detect available JSON parsers for conditional skips
_has_json_parser() {
    command -v jq >/dev/null 2>&1 || command -v node >/dev/null 2>&1 || command -v deno >/dev/null 2>&1
}

# ── _parse_json_scripts ───────────────────────────────────────────────────────

section "_parse_json_scripts"

if ! _has_json_parser; then
    skip "_parse_json_scripts (no jq/node/deno available)"
else
    PKG="${TMPROOT}/package.json"
    cat > "$PKG" << 'EOF'
{
  "scripts": {
    "dev":   "vite",
    "build": "tsc && vite build",
    "test":  "vitest"
  }
}
EOF

    result=$(_parse_json_scripts "$PKG" npm)
    assert_contains "returns script name"            "dev"             "$result"
    assert_contains "returns script command"         "vite"            "$result"
    assert_contains "returns multi-word command"     "tsc && vite build" "$result"
    assert_eq       "formats as name TAB cmd"        "dev	vite"  "$(printf '%s\n' "$result" | grep '^dev')"
    assert_eq       "returns one line per script"    "3"               "$(printf '%s\n' "$result" | grep -c .)"

    PKG_EMPTY="${TMPROOT}/pkg_noscripts.json"
    printf '{"name":"app"}' > "$PKG_EMPTY"
    assert_empty "returns empty when no scripts key" "$(_parse_json_scripts "$PKG_EMPTY" npm)"

    DENO="${TMPROOT}/deno.json"
    cat > "$DENO" << 'EOF'
{
  "tasks": {
    "start": "deno run main.ts",
    "check": "deno check **/*.ts"
  }
}
EOF
    result=$(_parse_json_scripts "$DENO" deno)
    assert_contains "returns deno task name"         "start"           "$result"
    assert_contains "returns deno task command"      "deno run main.ts" "$result"
    assert_eq       "formats deno task as name TAB cmd" "start	deno run main.ts" \
                    "$(printf '%s\n' "$result" | grep '^start')"

    DENO_JSONC="${TMPROOT}/deno.jsonc"
    cat > "$DENO_JSONC" << 'EOF'
{
  // dev tasks
  "tasks": {
    "dev": "deno run --watch main.ts" /* hot reload */
  }
}
EOF
    result=$(_parse_json_scripts "$DENO_JSONC" deno)
    assert_contains "strips comments from .jsonc"    "dev"             "$result"
    assert_not_contains "no comment text in output"  "//"              "$result"
fi

# ── _get_npm_scripts ──────────────────────────────────────────────────────────

section "_get_npm_scripts"

if ! _has_json_parser; then
    skip "_get_npm_scripts (no jq/node/deno available)"
else
    NPM_DIR="${TMPROOT}/npm_project"
    mkdir -p "$NPM_DIR" && cd "$NPM_DIR"

    cat > ./package.json << 'EOF'
{
  "scripts": {
    "dev":   "vite",
    "build": "vite build",
    "lint":  "eslint ."
  }
}
EOF

    result=$(_get_npm_scripts)
    assert_contains "returns scripts"                "dev	vite" "$result"
    assert_contains "returns all scripts"            "lint"         "$result"

    result_labeled=$(_get_npm_scripts script)
    assert_contains "label in description field"     "[script]"     "$result_labeled"
    assert_contains "name preserved with label"      "dev"          "$result_labeled"

    # Scope count to this project's dir-hash so other projects don't interfere
    local _dir_hash
    _dir_hash=$(printf '%s' "$NPM_DIR" | cksum | cut -d' ' -f1)
    cache_files=("${PACKAGE_COMPLETIONS_CACHE_DIR}"/scripts_${_dir_hash}_*.cache)
    assert_eq "creates exactly one cache file for this project" "1" "${#cache_files}"

    cached_result=$(_get_npm_scripts)
    assert_eq "cache hit returns same output"        "$result" "$cached_result"

    # Change file content → new cache key → fresh parse
    cat > ./package.json << 'EOF'
{
  "scripts": {
    "dev":    "vite",
    "build":  "vite build",
    "lint":   "eslint .",
    "format": "prettier --write ."
  }
}
EOF
    result_updated=$(_get_npm_scripts)
    assert_contains "detects new script after content change" "format" "$result_updated"

    cache_files_after=("${PACKAGE_COMPLETIONS_CACHE_DIR}"/scripts_${_dir_hash}_*.cache)
    assert_eq "still only one cache file after update" "1" "${#cache_files_after}"

    EMPTY_DIR="${TMPROOT}/empty_npm"
    mkdir -p "$EMPTY_DIR" && cd "$EMPTY_DIR"
    assert_empty "returns empty when no package.json" "$(_get_npm_scripts)"
fi

# ── _get_deno_tasks ───────────────────────────────────────────────────────────

section "_get_deno_tasks"

if ! _has_json_parser; then
    skip "_get_deno_tasks (no jq/node/deno available)"
else
    DENO_DIR="${TMPROOT}/deno_project"
    mkdir -p "$DENO_DIR" && cd "$DENO_DIR"

    assert_empty "returns empty with no config file" "$(_get_deno_tasks)"

    cat > ./deno.json << 'EOF'
{
  "tasks": {
    "start": "deno run main.ts",
    "test":  "deno test"
  }
}
EOF

    result=$(_get_deno_tasks)
    assert_contains "returns task name"              "start"            "$result"
    assert_contains "returns task command"           "deno run main.ts" "$result"

    result_labeled=$(_get_deno_tasks task)
    assert_contains "label in description field"     "[task]"           "$result_labeled"

    # deno.json takes priority over deno.jsonc when both exist — use a fresh dir to avoid cache
    DENO_PRIO_DIR="${TMPROOT}/deno_prio"
    mkdir -p "$DENO_PRIO_DIR" && cd "$DENO_PRIO_DIR"
    cat > ./deno.json << 'EOF'
{ "tasks": { "from-json": "echo json" } }
EOF
    cat > ./deno.jsonc << 'EOF'
{ "tasks": { "from-jsonc": "echo jsonc" } }
EOF
    result=$(_get_deno_tasks)
    assert_contains     "prefers deno.json over deno.jsonc" "from-json"   "$result"
    assert_not_contains "does not read deno.jsonc"          "from-jsonc"  "$result"

    rm ./deno.json
    rm -f "${PACKAGE_COMPLETIONS_CACHE_DIR}/deno_"*.cache(N)  # clear cache after rm
    result=$(_get_deno_tasks)
    assert_contains "falls back to deno.jsonc"       "from-jsonc"       "$result"
fi

# ── _get_bin_executables ──────────────────────────────────────────────────────

section "_get_bin_executables"

BIN_DIR="${TMPROOT}/bin_project"
mkdir -p "${BIN_DIR}/node_modules/.bin"
cd "$BIN_DIR"

touch ./node_modules/.bin/vite
touch ./node_modules/.bin/vitest
touch ./node_modules/.bin/eslint

result=$(_get_bin_executables)
assert_contains "lists vite"   "vite"   "$result"
assert_contains "lists vitest" "vitest" "$result"
assert_contains "lists eslint" "eslint" "$result"

result_labeled=$(_get_bin_executables executor)
assert_contains "uses custom label" "[executor]" "$result_labeled"

result_default=$(_get_bin_executables)
assert_contains "default label is 'bin'" "[bin]" "$result_default"

cd "$TMPROOT"
assert_empty "returns empty when no node_modules/.bin" "$(_get_bin_executables)"

# ── _complete_items (fzf mode) ────────────────────────────────────────────────

section "_complete_items — fzf mode"

# _describe is a zsh completion built-in; stub it for unit-test context.
_describe() { : }

items="$(printf 'dev\tvite\nbuild\tvite build\nlint\teslint .')"

# Capture what compadd receives by stubbing it
_compadd_received=()
compadd() { _compadd_received+=("$@") }

_complete_items "npm run" "" "$items"
assert_contains "fzf mode: compadd receives first item" "dev" "${_compadd_received[*]}"

# Restore compadd
unfunction compadd

_complete_items "prompt" "" ""
pass "returns cleanly for empty items"  # would have errored if not

# Deduplication
_compadd_received=()
compadd() { _compadd_received+=("$@") }
items_duped="$(printf 'dev\tvite\ndev\tduplicate\nbuild\tvite build')"
_complete_items "npm run" "" "$items_duped"
assert_eq "fzf mode: deduplication keeps first occurrence" "dev" "${_compadd_received[-1]}"
unfunction compadd

# ── _complete_items (native fallback) ─────────────────────────────────────────

section "_complete_items — native fallback (no fzf)"

# Override _fzf_available to return false — works regardless of whether fzf is installed
_fzf_available() { return 1 }

_describe_received=()
_describe_entries=()
_describe() {
    _describe_received+=("$@")
    # $2 is the array name passed by _describe caller; dereference it
    local arr_name="$2"
    _describe_entries=("${(@P)arr_name}")
}

items="$(printf 'dev\tvite\nbuild\tvite build')"
_complete_items "npm run" "" "$items"

assert_contains "native mode: _describe is called"         "npm run"  "${_describe_received[*]}"
assert_contains "native mode: entries contain item name"   "dev"      "${_describe_entries[*]}"
assert_contains "native mode: entries contain description" "vite"     "${_describe_entries[*]}"
assert_contains "native mode: entry format is name:desc"   "dev:vite" "${_describe_entries[*]}"

unfunction _describe _fzf_available

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\n─────────────────────────────────\n'
printf '  %s passed  %s failed  %s skipped\n' \
    "$(_green $_PASS)" \
    "$( ((_FAIL > 0)) && _red $_FAIL || printf '%d' $_FAIL )" \
    "$(_yellow $_SKIP)"
printf '─────────────────────────────────\n'

((_FAIL == 0))
