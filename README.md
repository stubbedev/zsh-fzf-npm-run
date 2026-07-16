# zsh-fzf-npm-run

Tab completions for Node.js package managers that merge native subcommands with your project's scripts/tasks into a single fuzzy picker.

**Supported tools:** `npm`, `yarn`, `bun`, `pnpm`, `deno`, `npx`, `bunx`, `pnpx`

## Install

### Oh My Zsh

```sh
git clone https://github.com/stubbedev/zsh-fzf-npm-run \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-fzf-npm-run
```

Add to your `.zshrc`:

```zsh
plugins=(... zsh-fzf-npm-run)
```

### Zinit

```zsh
zinit light stubbedev/zsh-fzf-npm-run
```

### Antigen

```zsh
antigen bundle stubbedev/zsh-fzf-npm-run
```

### Zplug

```zsh
zplug "stubbedev/zsh-fzf-npm-run"
```

### Manual

```sh
git clone https://github.com/stubbedev/zsh-fzf-npm-run ~/.zsh/zsh-fzf-npm-run
echo 'source ~/.zsh/zsh-fzf-npm-run/zsh-fzf-npm-run.plugin.zsh' >> ~/.zshrc
```

---

## Requirements

- zsh
- `curl` or `wget` to auto-download the completion engine _(or `cargo` to build it locally — see [Development](#development))_
- [fzf](https://github.com/junegunn/fzf) _(optional — native zsh menu used as fallback)_

No `jq`, `node`, or `deno` is needed: the engine parses `package.json` and
`deno.json`/`deno.jsonc` natively.

## How it works

Completions are served by a small Rust binary, `npm-run-comp`. On first load the
plugin downloads the prebuilt release matching this checkout in the background
(verified against its published SHA-256) into `~/.cache/npm-run/bin/`; no local
toolchain is required and `git pull` upgrades everything. The shim just hands
the current command line to the binary and feeds its output to fzf.

## Features

- Fuzzy-search completions via [fzf](https://github.com/junegunn/fzf) (falls back to native zsh menu if fzf is not installed)
- Top-level command lists are **hardcoded tables merged with the tool's own `--help`** — so `npm <tab>` reliably offers `run` (and other aliases npm's help hides behind `run-script`) plus any version-specific or plugin subcommands
- Merges native subcommands and `package.json` scripts in one picker for tools that support direct script execution (`yarn`, `bun`, `pnpm`)
- `deno` merges native subcommands with tasks from `deno.json`/`deno.jsonc`
- `npx`, `bunx`, `pnpx` — and `bun x`, `pnpm dlx`, `yarn dlx` — complete from `node_modules/.bin`
- **Flag-aware**: completions work with arbitrary flags anywhere on the line (`npm run --silent <tab>`, `pnpm --filter web run <tab>`)
- **Completes flags too**: typing `-` offers the current (sub)command's options — both long and short forms — parsed from its own `--help` (`npm install --<tab>` → `--save-dev`/`-S`, …); `npx eslint --<tab>` defers, since those flags belong to the invoked package
- **Completes flag values**: `pnpm --filter <tab>` / `npm -w <tab>` offer the monorepo's package names; directory flags (`--prefix`, `-C`, `--cwd`, `--dir`) defer to zsh's file completion
- Robust config parsing: `deno.json`/`deno.jsonc` with comments and trailing commas are handled (strict JSON is tried first, so `package.json` costs nothing extra)
- **Honors directory flags**: `--prefix`, `-C`, `--cwd`, `--dir` resolve scripts and `node_modules/.bin` from the pointed-at (possibly nested) package
- `package.json`/`deno.json` are located by walking up from the working directory, like the tools themselves
- Completions only register for tools that are actually installed
- Unrecognized subcommands (`npm install <tab>`) fall through to zsh's default completion

## Usage

Press `Tab` after any supported command. Type to filter.

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

Everything lives under `~/.cache/npm-run/`.

- **Engine binary** — `~/.cache/npm-run/bin/`, tracked against the latest release
- **Scraped `--help` output** — keyed by the tool binary's mtime + size, so a tool upgrade invalidates it instantly with no extra process spawns

Project scripts/tasks are parsed fresh on every tab press (a native JSON parse
of one file — microseconds), so there is nothing to invalidate there.

To reset:

```sh
rm -rf ~/.cache/npm-run/
```

## Development

The engine is a Rust crate; [`just`](https://github.com/casey/just) wraps the
common tasks.

```sh
just build        # cargo build --release (the shim auto-uses target/release/)
just test         # cargo test
just smoke        # build + shim/engine smoke test (tests/run.zsh)
just check        # lint + test + smoke
```

Releases are cut with `just release-patch|minor|major`, which bumps
`Cargo.toml`, tags, and pushes; CI builds the per-platform binaries and attaches
them (with checksums) to the GitHub release the plugin downloads from.

A Nix flake is also provided:

```sh
nix run  github:stubbedev/zsh-fzf-npm-run   # run the engine
nix build github:stubbedev/zsh-fzf-npm-run  # ./result/bin/npm-run-comp
```

CI builds the flake package and pushes its closure to the `nix.stubbe.dev`
binary cache on every `master` push and release tag, so flake consumers pull a
prebuilt binary instead of compiling.
