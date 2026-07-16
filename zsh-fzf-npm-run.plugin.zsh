#--------------------------------------------------------------------------
# fzf package-manager completions for zsh
#--------------------------------------------------------------------------
#
# Fuzzy tab-completion for npm, yarn, bun, pnpm, deno and the npx/bunx/pnpx
# executors: scripts, tasks, node_modules/.bin binaries and built-in commands.
#
# Completions are served by the npm-run-comp binary. This script's job is to
# ensure the binary exists — it downloads the prebuilt release matching this
# checkout's version from GitHub in the background — and to hand its output to
# zsh/fzf. No local toolchain is needed; `git pull` upgrades everything.
# fzf is optional — falls back to native zsh completion when not available.

NPM_RUN_CACHE_DIR="${HOME}/.cache/npm-run"
mkdir -p "$NPM_RUN_CACHE_DIR"

# Downloaded binary lives under the (writable) cache dir — NOT the plugin dir,
# which is often read-only (Nix store, system oh-my-zsh, Homebrew).
typeset -g _NPM_RUN_BIN_DIR="${NPM_RUN_CACHE_DIR}/bin"

zmodload -s zsh/datetime

# Cache fzf availability at load time — avoids a fork on every tab press.
if command -v fzf >/dev/null 2>&1; then
  _npm_run_fzf_available() { return 0 }
else
  _npm_run_fzf_available() { return 1 }
fi

typeset -g _NPM_RUN_PLUGIN_DIR="${${(%):-%N}:A:h}"
typeset -g _NPM_RUN_COMP_BIN=""
typeset -g _NPM_RUN_REPO="stubbedev/zsh-fzf-npm-run"

#--------------------------------------------------------------------------
# npm-run-comp binary management
#--------------------------------------------------------------------------

# Resolves the newest published release tag from GitHub and caches it, so the
# binary tracks releases without a git pull. Uses the `releases/latest`
# redirect (no API token, no rate limit, no jq). Silent and best-effort.
function _npm_run_refresh_latest() {
  local stamp="$NPM_RUN_CACHE_DIR/latest.stamp"
  local old="" ots=0
  [[ -f "$stamp" ]] && read -r old ots <"$stamp"
  # Reject a poisoned token (e.g. an epoch shifted into field 1 when a past
  # write stored an empty version) so it can't propagate via the fallback.
  [[ "$old" == <->.<->.<-> ]] || old=""
  local url="" ver=""
  if command -v curl >/dev/null 2>&1; then
    url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
           "https://github.com/${_NPM_RUN_REPO}/releases/latest" 2>/dev/null)"
  fi
  ver="${url##*/tag/v}"
  [[ "$ver" == "$url" ]] && ver=""   # no `/tag/v` in the URL → lookup failed
  [[ "$ver" == <->.<->.<-> ]] || ver="$old"
  print -r -- "$ver ${EPOCHSECONDS:-0}" >"$stamp" 2>/dev/null
}

# Sets REPLY to the binary version to run: the newest published release
# (cached, refreshed in the background at most once a day), falling back to the
# Cargo.toml floor when no release has been resolved yet.
function _npm_run_wanted_version() {
  REPLY=""
  local stamp="$NPM_RUN_CACHE_DIR/latest.stamp"
  local cached="" ts=0
  [[ -f "$stamp" ]] && read -r cached ts <"$stamp"
  if (( ${EPOCHSECONDS:-0} - ${ts:-0} >= 86400 )); then
    _npm_run_refresh_latest &!
  fi
  if [[ "$cached" == <->.<->.<-> ]]; then
    REPLY="$cached"
    return 0
  fi
  local line
  while IFS= read -r line; do
    if [[ "$line" == version*=* ]]; then
      REPLY="${${line#*\"}%%\"*}"
      return 0
    fi
  done <"$_NPM_RUN_PLUGIN_DIR/Cargo.toml" 2>/dev/null
  return 1
}

function _npm_run_locate_binary() {
  local c
  # Prefer the downloaded binary; then one committed to the plugin's bin/; then
  # a local dev build (target/release, for unsupported platforms / development).
  for c in "$_NPM_RUN_BIN_DIR/npm-run-comp" "$_NPM_RUN_PLUGIN_DIR/bin/npm-run-comp" "$_NPM_RUN_PLUGIN_DIR/target/release/npm-run-comp"; do
    if [[ -x "$c" ]]; then
      _NPM_RUN_COMP_BIN="$c"
      return 0
    fi
  done
  return 1
}

# Download the release binary for this platform in the background. A stamp file
# records the attempted version so a failing download (offline, release missing)
# is retried only after the wanted version changes or the TTL lapses.
function _npm_run_ensure_binary() {
  _npm_run_wanted_version || return 1
  local wanted=$REPLY

  if _npm_run_locate_binary; then
    # Dev build (target/release) is a local escape hatch — never touched.
    [[ "$_NPM_RUN_COMP_BIN" == "$_NPM_RUN_PLUGIN_DIR/target/release/"* ]] && return 0
    local vfile="" have=""
    [[ "$_NPM_RUN_COMP_BIN" == "$_NPM_RUN_BIN_DIR/"* ]] && vfile="$_NPM_RUN_BIN_DIR/.version"
    if [[ -n "$vfile" && -f "$vfile" ]]; then
      have="$(<$vfile)"
    else
      have=$("$_NPM_RUN_COMP_BIN" version 2>/dev/null)
      [[ -n "$have" && -n "$vfile" ]] && print -r -- "$have" >"$vfile" 2>/dev/null
    fi
    [[ "$have" == "$wanted" ]] && return 0
  fi

  local stamp="$NPM_RUN_CACHE_DIR/download.stamp"
  if [[ -f "$stamp" ]]; then
    local sver sts
    read -r sver sts <"$stamp"
    (( ${EPOCHSECONDS:-0} - ${sts:-0} < 3600 )) && [[ "$sver" == "$wanted" ]] && return 1
  fi

  local os arch
  case "$OSTYPE" in
    darwin*) os="apple-darwin" ;;
    linux*)  os="unknown-linux-musl" ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="aarch64" ;;
    x86_64|amd64)  arch="x86_64" ;;
    *) return 1 ;;
  esac

  print -r -- "$wanted ${EPOCHSECONDS:-0}" >"$stamp"
  # Silent, background, best-effort: the user never sees the update happen.
  (
    local base="https://github.com/${_NPM_RUN_REPO}/releases/download/v${wanted}/npm-run-comp-${arch}-${os}"
    local dest="$_NPM_RUN_BIN_DIR/npm-run-comp"
    local tmp="$_NPM_RUN_BIN_DIR/.npm-run-comp.$$.$RANDOM"
    local sum="$tmp.sha256"
    mkdir -p "$_NPM_RUN_BIN_DIR"

    local fetch
    if command -v curl >/dev/null 2>&1; then
      fetch() { curl -fsSL -o "$1" "$2" }
    elif command -v wget >/dev/null 2>&1; then
      fetch() { wget -qO "$1" "$2" }
    else
      exit 1
    fi

    { fetch "$tmp" "$base" && fetch "$sum" "${base}.sha256" } || { rm -f "$tmp" "$sum"; exit 1 }

    # Verify the SHA-256 published alongside the binary before trusting it.
    local expected actual
    expected="${$(<"$sum")%% *}"
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$tmp")"; actual="${actual%% *}"
    elif command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "$tmp")"; actual="${actual%% *}"
    fi
    rm -f "$sum"
    if [[ -z "$expected" || -z "$actual" || "$actual" != "$expected" ]]; then
      rm -f "$tmp"
      exit 1
    fi

    chmod +x "$tmp"
    if [[ "$("$tmp" version 2>/dev/null)" == "$wanted" ]]; then
      mv -f "$tmp" "$dest"
      print -r -- "$wanted" >"$_NPM_RUN_BIN_DIR/.version"
      rm -f "$stamp"
    else
      rm -f "$tmp"
    fi
  ) &>/dev/null &!
  return 1
}

_npm_run_ensure_binary

#--------------------------------------------------------------------------
# completions
#--------------------------------------------------------------------------

# Present tab-separated "name\tdescription" items as completions.
# With fzf: opens the fuzzy picker. Without fzf: falls back to zsh _describe.
function _npm_run_present() {
  local prompt="$1" query="$2" items="$3"
  [[ -z "$items" ]] && return 1

  if _npm_run_fzf_available; then
    local selected
    selected=$(fzf \
      --preview 'echo {2..}' \
      --preview-window=right:50%:wrap \
      --height=40% \
      --reverse \
      --prompt="$prompt > " \
      --delimiter=$'\t' \
      --with-nth=1 \
      --bind='tab:accept' \
      --query="$query" \
      <<< "$items")
    selected=${selected%%$'\t'*}
    [[ -n "$selected" ]] && compadd -U -- "$selected"
  else
    local -a entries
    local name desc
    while IFS=$'\t' read -r name desc; do
      [[ -z "$name" ]] && continue
      entries+=("${name//:/\\:}:${desc:-$name}")
    done <<< "$items"
    _describe "$prompt" entries
  fi
  return 0
}

function _npm_run_comp() {
  # The binary may have finished downloading since plugin load — or still be
  # missing, in which case (re)trigger the background download and fall back to
  # zsh's default completion rather than block the prompt.
  if [[ -z "$_NPM_RUN_COMP_BIN" ]] && ! _npm_run_locate_binary; then
    _npm_run_ensure_binary
    _default
    return
  fi

  local out
  if ! out=$("$_NPM_RUN_COMP_BIN" complete --cwd "$PWD" --current "$CURRENT" -- "${words[@]}" 2>/dev/null); then
    # Nothing tool-specific to offer here (e.g. `npm install <Tab>`) — hand off
    # to zsh's default completion so package names etc. still work.
    _default
    return
  fi

  # First line is the prompt title, the rest are "candidate\tdescription" items.
  local prompt="${out%%$'\n'*}"
  local items="${out#*$'\n'}"
  [[ -z "$out" || -z "$items" || "$items" == "$out" ]] && { _default; return }

  local last_word=$words[CURRENT]
  _npm_run_present "$prompt" "$last_word" "$items"
}

# Register the one completion for every installed tool.
for _pm in npm yarn bun pnpm deno npx bunx pnpx; do
  if command -v "$_pm" >/dev/null 2>&1; then
    compdef _npm_run_comp "$_pm"
  fi
done
unset _pm
