#!/bin/zsh

# fzf Package Manager Completions Plugin
# Provides fuzzy completion for npm, yarn, bun, pnpm, deno, npx, bunx, pnpx
# fzf is optional — falls back to native zsh completion when not available.

PACKAGE_COMPLETIONS_CACHE_DIR="${HOME}/.cache/package-completions"

_fzf_available() { command -v fzf >/dev/null 2>&1 }

_ensure_cache_dir() {
    [[ -d "$PACKAGE_COMPLETIONS_CACHE_DIR" ]] || mkdir -p "$PACKAGE_COMPLETIONS_CACHE_DIR"
}

# Parse JSON/JSONC scripts or tasks from a config file.
# Uses jq for plain JSON (fastest), node or deno for JSONC (requires comment stripping).
_parse_json_scripts() {
    local file="$1"
    local type="$2"   # "npm" or "deno"
    local field
    [[ "$type" == "npm" ]] && field="scripts" || field="tasks"

    if [[ "$file" == *.jsonc ]]; then
        # jq cannot handle JSONC comments — route through node or deno
        if command -v node >/dev/null 2>&1; then
            node -e "
                try {
                    const fs = require('fs');
                    let c = fs.readFileSync('$file', 'utf8');
                    c = c.replace(/\/\*[\s\S]*?\*\//g,'').replace(/\/\/.*$/gm,'');
                    const obj = JSON.parse(c)['$field'] || {};
                    process.stdout.write(Object.entries(obj).map(([k,v]) => k+'\t'+(typeof v==='string'?v:JSON.stringify(v))).join('\n'));
                } catch(e) {}
            " 2>/dev/null
        elif command -v deno >/dev/null 2>&1; then
            deno eval "
                try {
                    let c = Deno.readTextFileSync('$file');
                    c = c.replace(/\/\*[\s\S]*?\*\//g,'').replace(/\/\/.*$/gm,'');
                    const obj = JSON.parse(c)['$field'] || {};
                    console.log(Object.entries(obj).map(([k,v]) => k+'\t'+(typeof v==='string'?v:JSON.stringify(v))).join('\n'));
                } catch(e) {}
            " 2>/dev/null
        fi
    elif command -v jq >/dev/null 2>&1; then
        jq -r ".$field // {} | to_entries[] | \"\(.key)\t\(.value)\"" "$file" 2>/dev/null
    elif command -v node >/dev/null 2>&1; then
        node -e "
            try {
                const obj = JSON.parse(require('fs').readFileSync('$file', 'utf8'))['$field'] || {};
                process.stdout.write(Object.entries(obj).map(([k,v]) => k+'\t'+(typeof v==='string'?v:JSON.stringify(v))).join('\n'));
            } catch(e) {}
        " 2>/dev/null
    elif command -v deno >/dev/null 2>&1; then
        deno eval "
            try {
                const obj = JSON.parse(Deno.readTextFileSync('$file'))['$field'] || {};
                console.log(Object.entries(obj).map(([k,v]) => k+'\t'+(typeof v==='string'?v:JSON.stringify(v))).join('\n'));
            } catch(e) {}
        " 2>/dev/null
    fi
}

# Get package.json scripts, content-hash+dir cached. Optional label prepended to description.
_get_npm_scripts() {
    local label="${1:-}"
    [[ -f "./package.json" ]] || return

    _ensure_cache_dir

    local pkg_hash dir_hash cache_file
    pkg_hash=$(cksum ./package.json 2>/dev/null | cut -d' ' -f1)
    dir_hash=$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)
    cache_file="${PACKAGE_COMPLETIONS_CACHE_DIR}/scripts_${dir_hash}_${pkg_hash}.cache"

    if [[ ! -f "$cache_file" ]]; then
        rm -f "${PACKAGE_COMPLETIONS_CACHE_DIR}/scripts_${dir_hash}_"*.cache(N)
        _parse_json_scripts "./package.json" "npm" > "$cache_file"
    fi

    [[ -s "$cache_file" ]] || return

    if [[ -n "$label" ]]; then
        awk -F'\t' -v lbl="$label" '{print $1 "\t[" lbl "] " $2}' "$cache_file"
    else
        cat "$cache_file"
    fi
}

# Get deno tasks from deno.json/deno.jsonc, content-hash+dir cached. Optional label.
_get_deno_tasks() {
    local label="${1:-}"
    local deno_config=""
    if [[ -f "./deno.json" ]]; then
        deno_config="./deno.json"
    elif [[ -f "./deno.jsonc" ]]; then
        deno_config="./deno.jsonc"
    fi
    [[ -z "$deno_config" ]] && return

    _ensure_cache_dir

    local cfg_hash dir_hash cache_file
    cfg_hash=$(cksum "$deno_config" 2>/dev/null | cut -d' ' -f1)
    dir_hash=$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)
    cache_file="${PACKAGE_COMPLETIONS_CACHE_DIR}/deno_${dir_hash}_${cfg_hash}.cache"

    if [[ ! -f "$cache_file" ]]; then
        rm -f "${PACKAGE_COMPLETIONS_CACHE_DIR}/deno_${dir_hash}_"*.cache(N)
        _parse_json_scripts "$deno_config" "deno" > "$cache_file"
    fi

    [[ -s "$cache_file" ]] || return

    if [[ -n "$label" ]]; then
        awk -F'\t' -v lbl="$label" '{print $1 "\t[" lbl "] " $2}' "$cache_file"
    else
        cat "$cache_file"
    fi
}

# List node_modules/.bin executables. Optional label.
_get_bin_executables() {
    local label="${1:-bin}"
    [[ -d "./node_modules/.bin" ]] || return

    ls ./node_modules/.bin 2>/dev/null | while read -r name; do
        printf '%s\t[%s]\n' "$name" "$label"
    done
}

# Get native subcommands from tool's --help, cached by tool version.
_get_native_commands() {
    local cmd="$1"
    _ensure_cache_dir

    local version cache_file
    version=$("$cmd" --version 2>/dev/null | head -1 | tr -d '[:space:]v')
    cache_file="${PACKAGE_COMPLETIONS_CACHE_DIR}/${cmd}_${version}.cache"

    if [[ ! -f "$cache_file" ]]; then
        rm -f "${PACKAGE_COMPLETIONS_CACHE_DIR}/${cmd}_"*.cache(N)
        _parse_native_commands "$cmd" > "$cache_file"
    fi

    cat "$cache_file"
}

# Extract commands+descriptions from each tool's help output.
_parse_native_commands() {
    local cmd="$1"
    case "$cmd" in
        npm)
            # Commands are listed comma-separated after "All commands:";
            # exit on the first non-indented line (not on blank lines).
            npm help 2>/dev/null \
                | awk '/All commands:/{f=1;next} f && /^[^[:space:]]/{exit} f{print}' \
                | tr ',' '\n' | tr -d ' \t' \
                | grep -E '^[a-z]' \
                | while read -r name; do printf '%s\tnpm command\n' "$name"; done
            ;;
        yarn)
            # yarn v1 lists commands as "    - commandname" under a "Commands:" section.
            # yarn v4/berry uses "  command   description" format.
            # Try v1 format first, then v4 format.
            local out
            out=$(yarn --help 2>/dev/null)

            # v1: "    - command" or "    - command / alias"
            local v1
            v1=$(echo "$out" \
                | awk '/^[[:space:]]+Commands:/{f=1;next} f && /^[[:space:]]*$/{exit} f{print}' \
                | grep -oE '[a-z][a-zA-Z-]+' \
                | grep -E '^[a-z][a-z-]+$' \
                | while read -r name; do printf '%s\tyarn command\n' "$name"; done)

            if [[ -n "$v1" ]]; then
                echo "$v1"
            else
                # v4/berry: "  command   description"
                echo "$out" \
                    | grep -E '^[[:space:]]{2,6}[a-z][a-z-]*[[:space:]]' \
                    | sed 's/^[[:space:]]*//' \
                    | awk '{cmd=$1; $1=""; sub(/^[[:space:]]+/,""); print cmd "\t" ($0!=""?$0:cmd)}'
            fi
            ;;
        bun)
            # Commands are "  cmd   description"; allow single-char commands (e.g. 'x').
            bun --help 2>/dev/null \
                | grep -E '^[[:space:]]{2,4}[a-z][a-z-]*[[:space:]]' \
                | sed 's/^[[:space:]]*//' \
                | awk '{cmd=$1; $1=""; sub(/^[[:space:]]+/,""); print cmd "\t" ($0!=""?$0:cmd)}'
            ;;
        pnpm)
            # Commands may have aliases ("i, install"); extract the canonical (last) name.
            pnpm help -a 2>/dev/null \
                | grep -E '^[[:space:]]{2,}[a-z]' \
                | grep -vE ':[[:space:]]*$' \
                | sed 's/^[[:space:]]*//' \
                | awk '{
                    match($0, /[[:space:]][[:space:]][[:space:]][[:space:]]*/)
                    if (RSTART > 0) {
                        cmd_part = substr($0, 1, RSTART-1)
                        desc = substr($0, RSTART+RLENGTH)
                        n = split(cmd_part, words, /[, ]+/)
                        cmd = words[n]
                        if (cmd ~ /^[a-z]/) printf "%s\t%s\n", cmd, desc
                    }
                }'
            ;;
        deno)
            # Commands are indented 4 spaces under section headers (2 spaces).
            deno --help 2>/dev/null \
                | grep -E '^[[:space:]]{4}[a-z]' \
                | grep -vE ':[[:space:]]*$' \
                | sed 's/^[[:space:]]*//' \
                | awk '{cmd=$1; $1=""; sub(/^[[:space:]]+/,""); print cmd "\t" ($0!=""?$0:cmd)}'
            ;;
    esac
}

# Present tab-separated items as completions.
# With fzf: opens fuzzy picker, inserts selection.
# Without fzf: falls back to native zsh menu via _describe.
_complete_items() {
    local prompt="$1" query="$2" items="$3"
    [[ -z "$items" ]] && return

    local deduped
    deduped=$(echo "$items" | grep -v '^$' | awk -F'\t' '!seen[$1]++')
    [[ -z "$deduped" ]] && return

    if _fzf_available; then
        local selected
        selected=$(echo "$deduped" \
            | fzf \
                --preview 'echo {} | cut -f2-' \
                --preview-window=right:50%:wrap \
                --height=40% \
                --reverse \
                --prompt="$prompt > " \
                --delimiter=$'\t' \
                --with-nth=1 \
                --bind='tab:accept' \
                --query="$query" \
            | cut -f1)
        [[ -n "$selected" ]] && compadd -U -- "$selected"
    else
        local -a entries
        while IFS=$'\t' read -r name desc; do
            [[ -z "$name" ]] && continue
            entries+=("${name}:${desc:-$name}")
        done <<< "$deduped"
        _describe "$prompt" entries -U
    fi
}

# Determine fzf prefill query — suppress for known non-script words.
_fzf_query() {
    local word="$1" cmd="$2"
    case "$word" in
        "$cmd"|run|task|exec|x|dlx) echo "" ;;
        *) echo "$word" ;;
    esac
}

# Central completion dispatcher for all package managers.
_pm_complete() {
    local cmd="$1" subcmd="$2" word="$3"
    local query items selected

    query=$(_fzf_query "$word" "$cmd")

    if [[ -n "$subcmd" ]]; then
        case "${cmd}:${subcmd}" in
            # 'run' subcommand — only package.json scripts
            npm:run|pnpm:run|yarn:run|bun:run)
                items=$(_get_npm_scripts)
                ;;
            # 'task' subcommand — only deno tasks
            deno:task)
                items=$(_get_deno_tasks)
                ;;
            # 'deno run' — tasks + TS/JS files
            deno:run)
                local files
                files=$(find . -maxdepth 3 \
                    \( -name "*.ts" -o -name "*.js" -o -name "*.mts" -o -name "*.mjs" \) \
                    -not -path "*/node_modules/*" 2>/dev/null \
                    | sed 's|^\./||' \
                    | while read -r f; do printf '%s\t[file]\n' "$f"; done \
                    | head -30)
                items="$(_get_deno_tasks)"$'\n'"$files"
                ;;
            # Executor subcommands — node_modules/.bin
            bun:x|pnpm:dlx|yarn:dlx)
                items=$(_get_bin_executables)
                ;;
        esac
    else
        # Base command: native subcommands + scripts/tasks where tool supports direct execution
        items=$(_get_native_commands "$cmd")
        case "$cmd" in
            yarn|bun|pnpm)
                # These support 'cmd <script>' without 'run'
                local scripts
                scripts=$(_get_npm_scripts "script")
                [[ -n "$scripts" ]] && items="${items}"$'\n'"${scripts}"
                ;;
            deno)
                local tasks
                tasks=$(_get_deno_tasks "task")
                [[ -n "$tasks" ]] && items="${items}"$'\n'"${tasks}"
                ;;
            # npm: no scripts at base level — always requires 'npm run'
        esac
    fi

    _complete_items "$cmd${subcmd:+ $subcmd}" "$query" "$items"
}

# Factory: generate a _<cmd> completion function for a package manager.
_make_pm_completion() {
    local cmd="$1"
    eval "
_${cmd}() {
    local state last_word=\$words[-1]
    [[ -z \$last_word ]] && last_word=\$words[-2]
    _arguments '1: :->command' '*: :->args'
    case \$state in
        command)
            [[ \$last_word == ${cmd} ]] && last_word=''
            _pm_complete '${cmd}' '' \"\$last_word\"
            ;;
        args)
            _pm_complete '${cmd}' \"\$words[2]\" \"\$last_word\"
            ;;
    esac
}
"
}

# Factory: generate a _<cmd> completion function for executor commands (npx, bunx, pnpx).
_make_exec_completion() {
    local cmd="$1"
    eval "
_${cmd}() {
    local last_word=\$words[-1]
    [[ -z \$last_word ]] && last_word=\$words[-2]
    [[ \$last_word == ${cmd} ]] && last_word=''
    local items
    items=\$(_get_bin_executables)
    _complete_items '${cmd}' \"\$last_word\" \"\$items\"
}
"
}

# Register completions only for installed tools
for _pm in npm yarn bun pnpm deno; do
    if command -v "$_pm" >/dev/null 2>&1; then
        _make_pm_completion "$_pm"
        compdef "_${_pm}" "$_pm"
    fi
done

for _exec in npx bunx pnpx; do
    if command -v "$_exec" >/dev/null 2>&1; then
        _make_exec_completion "$_exec"
        compdef "_${_exec}" "$_exec"
    fi
done

unset _pm _exec
