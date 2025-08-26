#!/bin/zsh

# fzf Package Manager Completions Plugin
# Provides fuzzy completion for yarn, npm, bun, and deno commands

# Check if fzf is available
if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf-package-completions: fzf is not installed" >&2
    return 1
fi

# Cache setup
PACKAGE_COMPLETIONS_CACHE_DIR="${HOME}/.cache/package-completions"
mkdir -p "$PACKAGE_COMPLETIONS_CACHE_DIR"

# Function to get npm scripts from package.json using node
_get_npm_scripts() {
    local package_json="./package.json"
    if [[ -f "$package_json" ]]; then
        # Extract script names and descriptions from package.json using node
        node -pe "
            try {
                const pkg = require('./package.json');
                const scripts = pkg.scripts || {};
                Object.entries(scripts).map(([name, cmd]) => 
                    \`\${name}\t\${cmd}\`
                ).join('\n');
            } catch (e) {
                '';
            }
        " 2>/dev/null
    fi
}

# Function to get npm scripts with labels for mixed completion
_get_npm_scripts_labeled() {
    local package_json="./package.json"
    if [[ -f "$package_json" ]]; then
        # Extract script names and descriptions from package.json using node
        node -pe "
            try {
                const pkg = require('./package.json');
                const scripts = pkg.scripts || {};
                Object.entries(scripts).map(([name, cmd]) => 
                    \`\${name}\t\${cmd} [package.json script]\`
                ).join('\n');
            } catch (e) {
                '';
            }
        " 2>/dev/null
    fi
}

# Function to get deno tasks from deno.json/deno.jsonc
_get_deno_tasks() {
    local deno_config=""
    
    # Check for deno.json or deno.jsonc
    if [[ -f "./deno.json" ]]; then
        deno_config="./deno.json"
    elif [[ -f "./deno.jsonc" ]]; then
        deno_config="./deno.jsonc"
    fi
    
    if [[ -n "$deno_config" && -f "$deno_config" ]]; then
        # Extract task names and commands from deno config using node
        node -pe "
            try {
                const fs = require('fs');
                let content = fs.readFileSync('$deno_config', 'utf8');
                // Remove comments for jsonc files
                if ('$deno_config'.endsWith('.jsonc')) {
                    content = content.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
                }
                const config = JSON.parse(content);
                const tasks = config.tasks || {};
                Object.entries(tasks).map(([name, cmd]) => {
                    const cmdStr = typeof cmd === 'string' ? cmd : JSON.stringify(cmd);
                    return \`\${name}\t\${cmdStr}\`;
                }).join('\n');
            } catch (e) {
                '';
            }
        " 2>/dev/null
    fi
}

# Function to get deno tasks with labels for mixed completion
_get_deno_tasks_labeled() {
    local deno_config=""
    
    # Check for deno.json or deno.jsonc
    if [[ -f "./deno.json" ]]; then
        deno_config="./deno.json"
    elif [[ -f "./deno.jsonc" ]]; then
        deno_config="./deno.jsonc"
    fi
    
    if [[ -n "$deno_config" && -f "$deno_config" ]]; then
        # Extract task names and commands from deno config using node
        node -pe "
            try {
                const fs = require('fs');
                let content = fs.readFileSync('$deno_config', 'utf8');
                // Remove comments for jsonc files
                if ('$deno_config'.endsWith('.jsonc')) {
                    content = content.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
                }
                const config = JSON.parse(content);
                const tasks = config.tasks || {};
                Object.entries(tasks).map(([name, cmd]) => {
                    const cmdStr = typeof cmd === 'string' ? cmd : JSON.stringify(cmd);
                    return \`\${name}\t\${cmdStr} [deno task]\`;
                }).join('\n');
            } catch (e) {
                '';
            }
        " 2>/dev/null
    fi
}

# Function to generate cached completions
_generate_base_completions() {
    local cmd="$1"
    local cache_file="$2"
    
    case "$cmd" in
        yarn)
            cat > "$cache_file" << 'EOF'
add	Add package to dependencies
remove	Remove package from dependencies
install	Install all dependencies
upgrade	Upgrade dependencies
run	Run script from package.json
build	Build the project
test	Run tests
start	Start the application
dev	Start development server
lint	Run linting
format	Format code
clean	Clean build artifacts
cache	Manage yarn cache
info	Show package information
list	List installed packages
outdated	Check for outdated packages
audit	Run security audit
init	Initialize new package
version	Manage package version
publish	Publish package
workspace	Manage workspace
workspaces	List workspaces
dlx	Download and execute package
node	Run node with yarn's resolution
exec	Execute command in project context
create	Create new project
why	Show why package is installed
EOF
            ;;
        npm)
            cat > "$cache_file" << 'EOF'
install	Install packages
uninstall	Remove packages
update	Update packages
run	Run package script
build	Build the project
test	Run tests
start	Start the application
init	Initialize package.json
publish	Publish package to registry
version	Manage package version
audit	Run security audit
fund	Display funding information
list	List installed packages
outdated	Check for outdated packages
cache	Manage npm cache
config	Manage npm configuration
doctor	Check npm environment
pack	Create tarball from package
ping	Ping npm registry
search	Search packages
view	View package information
whoami	Display npm username
EOF
            ;;
        bun)
            cat > "$cache_file" << 'EOF'
install	Install dependencies
add	Add dependency
remove	Remove dependency
update	Update dependencies
run	Run package script
build	Build project
test	Run tests
create	Create new project
init	Initialize package.json
upgrade	Upgrade bun version
link	Link package globally
unlink	Unlink package
pm	Package manager commands
dev	Start development server
x	Execute package
exec	Execute command
EOF
            ;;
        deno)
            cat > "$cache_file" << 'EOF'
run	Run TypeScript/JavaScript file
compile	Compile TypeScript to executable
bundle	Bundle modules
install	Install script as executable
cache	Cache dependencies
info	Show info about cache/modules
doc	Show documentation
fmt	Format source files
lint	Lint source files
test	Run tests
types	Print runtime TypeScript declarations
upgrade	Upgrade deno executable
eval	Evaluate script
repl	Start read-eval-print loop
task	Run task from deno.json
bench	Run benchmarks
check	Type-check files
coverage	Print coverage reports
init	Initialize new project
jupyter	Integration with Jupyter
publish	Publish module
serve	Start file server
uninstall	Uninstall script
vendor	Vendor dependencies
help	Show help
completions	Generate shell completions
EOF
            ;;
    esac
}

# Function to determine if we should prefill the query
_should_prefill() {
    local word="$1"
    
    # Don't prefill if the word is a command or subcommand
    case "$word" in
        yarn|npm|bun|deno|run|task)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Main completion function for package managers
_package_manager_completion() {
    local cmd="$1"
    local subcmd="$2"
    local current_word="$3"
    
    # Determine query for fzf
    local query=""
    if _should_prefill "$current_word"; then
        query="$current_word"
    fi
    
    # Handle explicit run/task subcommands - show ONLY scripts/tasks
    if [[ "$subcmd" == "run" && ("$cmd" == "yarn" || "$cmd" == "npm" || "$cmd" == "bun") ]]; then
        local scripts="$(_get_npm_scripts)"
        if [[ -n "$scripts" ]]; then
            local selected_script=$(echo "$scripts" | fzf \
                --preview 'echo {} | awk "{\$1=\"\"; print substr(\$0,2)}"' \
                --preview-window=right:50%:wrap \
                --height=40% \
                --reverse \
                --prompt="$cmd run > " \
                --with-nth 1 \
                --bind 'tab:accept' \
                --query="$query" | awk '{print $1}')
            
            if [[ -n "$selected_script" ]]; then
                compadd -U -- "$selected_script"
            fi
        fi
        return 0
    elif [[ "$subcmd" == "run" && "$cmd" == "deno" ]]; then
        # For deno run, combine scripts, tasks, and files
        local items=""
        local npm_scripts="$(_get_npm_scripts)"
        local deno_tasks="$(_get_deno_tasks)"
        local files=$(find . -maxdepth 2 \( -name "*.ts" -o -name "*.js" -o -name "*.mts" -o -name "*.mjs" \) 2>/dev/null | sed 's|^\./||' | head -20 | awk '{print $0 "\tTypeScript/JavaScript file"}')
        
        [[ -n "$npm_scripts" ]] && items="$npm_scripts"
        [[ -n "$deno_tasks" ]] && items="$items"$'\n'"$deno_tasks"
        [[ -n "$files" ]] && items="$items"$'\n'"$files"
        
        if [[ -n "$items" ]]; then
            local selected_item=$(echo "$items" | grep -v '^$' | fzf \
                --preview 'echo {} | awk "{\$1=\"\"; print substr(\$0,2)}"' \
                --preview-window=right:50%:wrap \
                --height=40% \
                --reverse \
                --prompt="deno run > " \
                --with-nth 1 \
                --bind 'tab:accept' \
                --query="$query" | awk '{print $1}')
            
            if [[ -n "$selected_item" ]]; then
                compadd -U -- "$selected_item"
            fi
        fi
        return 0
    elif [[ "$subcmd" == "task" && "$cmd" == "deno" ]]; then
        local tasks="$(_get_deno_tasks)"
        if [[ -n "$tasks" ]]; then
            local selected_task=$(echo "$tasks" | fzf \
                --preview 'echo {} | awk "{\$1=\"\"; print substr(\$0,2)}"' \
                --preview-window=right:50%:wrap \
                --height=40% \
                --reverse \
                --prompt="deno task > " \
                --with-nth 1 \
                --bind 'tab:accept' \
                --query="$query" | awk '{print $1}')
            
            if [[ -n "$selected_task" ]]; then
                compadd -U -- "$selected_task"
            fi
        fi
        return 0
    fi
    
    # For base commands, behavior differs by package manager
    local cache_key="$cmd"
    local cache_file="${PACKAGE_COMPLETIONS_CACHE_DIR}/${cache_key}.cache"
    
    # Generate base completions cache if it doesn't exist
    if [[ ! -f "$cache_file" ]]; then
        _generate_base_completions "$cmd" "$cache_file"
    fi
    
    local all_completions=""
    
    # Get base command completions
    if [[ -f "$cache_file" ]]; then
        all_completions="$(cat "$cache_file")"
    fi
    
    # For yarn and bun base commands (no subcommand), also include package.json scripts
    if [[ "$cmd" == "yarn" || "$cmd" == "bun" ]] && [[ -z "$subcmd" ]]; then
        local scripts="$(_get_npm_scripts_labeled)"
        if [[ -n "$scripts" ]]; then
            if [[ -n "$all_completions" ]]; then
                all_completions="$all_completions"$'\n'"$scripts"
            else
                all_completions="$scripts"
            fi
        fi
    fi
    
    # For deno base commands (no subcommand), also include tasks
    if [[ "$cmd" == "deno" && -z "$subcmd" ]]; then
        local tasks="$(_get_deno_tasks_labeled)"
        if [[ -n "$tasks" ]]; then
            if [[ -n "$all_completions" ]]; then
                all_completions="$all_completions"$'\n'"$tasks"
            else
                all_completions="$tasks"
            fi
        fi
    fi
    
    if [[ -n "$all_completions" ]]; then
        # Remove duplicates while preserving order
        all_completions="$(echo "$all_completions" | awk '!seen[$1]++' | grep -v '^$')"
        
        local selected_command=$(echo "$all_completions" | fzf \
            --preview 'echo {} | awk "{\$1=\"\"; print substr(\$0,2)}"' \
            --preview-window=right:50%:wrap \
            --height=40% \
            --reverse \
            --prompt="$cmd > " \
            --with-nth 1 \
            --bind 'tab:accept' \
            --query="$query" | awk '{print $1}')
        
        if [[ -n "$selected_command" ]]; then
            compadd -U -- "$selected_command"
        fi
    fi
}

# Completion function for yarn
function _yarn() {
    local state
    local last_word=$words[-1]
    if [[ -z $last_word ]]; then
        last_word=$words[-2]
    fi
    
    _arguments \
        '1: :->command' \
        '*: :->args'
    
    case $state in
        command)
            if [[ $last_word = "yarn" ]]; then
                last_word=""
            fi
            _package_manager_completion "yarn" "" "$last_word"
            ;;
        args)
            if [[ "$words[2]" == "run" ]]; then
                _package_manager_completion "yarn" "run" "$last_word"
            fi
            ;;
    esac
}

# Completion function for npm
function _npm() {
    local state
    local last_word=$words[-1]
    if [[ -z $last_word ]]; then
        last_word=$words[-2]
    fi
    
    _arguments \
        '1: :->command' \
        '*: :->args'
    
    case $state in
        command)
            if [[ $last_word = "npm" ]]; then
                last_word=""
            fi
            _package_manager_completion "npm" "" "$last_word"
            ;;
        args)
            if [[ "$words[2]" == "run" ]]; then
                _package_manager_completion "npm" "run" "$last_word"
            fi
            ;;
    esac
}

# Completion function for bun
function _bun() {
    local state
    local last_word=$words[-1]
    if [[ -z $last_word ]]; then
        last_word=$words[-2]
    fi
    
    _arguments \
        '1: :->command' \
        '*: :->args'
    
    case $state in
        command)
            if [[ $last_word = "bun" ]]; then
                last_word=""
            fi
            _package_manager_completion "bun" "" "$last_word"
            ;;
        args)
            if [[ "$words[2]" == "run" ]]; then
                _package_manager_completion "bun" "run" "$last_word"
            fi
            ;;
    esac
}

# Completion function for deno
function _deno() {
    local state
    local last_word=$words[-1]
    if [[ -z $last_word ]]; then
        last_word=$words[-2]
    fi
    
    _arguments \
        '1: :->command' \
        '*: :->args'
    
    case $state in
        command)
            if [[ $last_word = "deno" ]]; then
                last_word=""
            fi
            _package_manager_completion "deno" "" "$last_word"
            ;;
        args)
            if [[ "$words[2]" == "run" ]]; then
                _package_manager_completion "deno" "run" "$last_word"
            elif [[ "$words[2]" == "task" ]]; then
                _package_manager_completion "deno" "task" "$last_word"
            fi
            ;;
    esac
}

# Register completions
compdef _yarn yarn
compdef _npm npm
compdef _bun bun
compdef _deno deno
