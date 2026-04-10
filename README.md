# zsh-fzf-npm-run

Tab completions for Node.js package managers that merge native subcommands with your project's scripts/tasks into a single fuzzy picker.

**Supported tools:** `npm`, `yarn`, `bun`, `pnpm`, `deno`, `npx`, `bunx`, `pnpx`

## Features

- Fuzzy-search completions via [fzf](https://github.com/junegunn/fzf) (falls back to native zsh menu if fzf is not installed)
- Merges native subcommands and `package.json` scripts in one picker for tools that support direct script execution (`yarn`, `bun`, `pnpm`)
- `npm` correctly requires `npm run <tab>` — scripts are not shown at the base level
- `deno` merges native subcommands with tasks from `deno.json`/`deno.jsonc`
- `npx`, `bunx`, `pnpx` complete from `node_modules/.bin`
- `bun x`, `pnpm dlx`, `yarn dlx` also complete from `node_modules/.bin`
- Completions only register for tools that are actually installed
- Native command lists are cached by tool version and regenerated automatically on upgrade
- Project scripts/tasks are cached by file content hash — updates instantly when `package.json` or `deno.json` changes

## Requirements

- zsh
- One of: `jq`, `node`, or `deno` (for parsing `package.json` / `deno.json`)
- [fzf](https://github.com/junegunn/fzf) _(optional — native zsh menu used as fallback)_

## Installation

### Oh My Zsh

```sh
git clone https://github.com/stubbedev/zsh-fzf-npm-run \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-fzf-npm-run
```

Then add the plugin to your `.zshrc`:

```zsh
plugins=(... zsh-fzf-npm-run)
```

### Zinit

```zsh
zinit light stubbedev/zsh-fzf-npm-run
```

### Zplug

```zsh
zplug "stubbedev/zsh-fzf-npm-run"
```

### Antigen

```zsh
antigen bundle stubbedev/zsh-fzf-npm-run
```

### Manual

```sh
git clone https://github.com/stubbedev/zsh-fzf-npm-run ~/.zsh/zsh-fzf-npm-run
```

Then source it in your `.zshrc`:

```zsh
source ~/.zsh/zsh-fzf-npm-run/zsh-fzf-npm-run.plugin.zsh
```

## Usage

Just press `Tab` after a supported command. The fuzzy picker opens with all relevant completions.

| Command | Completes |
|---|---|
| `npm <tab>` | Native npm subcommands |
| `npm run <tab>` | `package.json` scripts |
| `yarn <tab>` | Native subcommands + `package.json` scripts |
| `yarn run <tab>` | `package.json` scripts |
| `bun <tab>` | Native subcommands + `package.json` scripts |
| `pnpm <tab>` | Native subcommands + `package.json` scripts |
| `pnpm run <tab>` | `package.json` scripts |
| `deno <tab>` | Native subcommands + `deno.json` tasks |
| `deno task <tab>` | `deno.json` tasks |
| `deno run <tab>` | `deno.json` tasks + local TS/JS files |
| `npx <tab>` | `node_modules/.bin` executables |
| `bunx <tab>` | `node_modules/.bin` executables |
| `pnpx <tab>` | `node_modules/.bin` executables |
| `bun x <tab>` | `node_modules/.bin` executables |
| `pnpm dlx <tab>` | `node_modules/.bin` executables |
| `yarn dlx <tab>` | `node_modules/.bin` executables |

## Cache

Caches are stored in `~/.cache/package-completions/`.

- **Native subcommands** — cached per tool version, refreshed automatically when the tool is upgraded
- **Project scripts/tasks** — cached per file content hash, refreshed automatically when `package.json` or `deno.json` changes

To clear all caches manually:

```sh
rm -rf ~/.cache/package-completions/
```

## Testing

```sh
zsh tests/run.zsh
```
