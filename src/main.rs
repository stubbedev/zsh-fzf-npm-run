//! Completion engine for zsh-fzf-npm-run.
//!
//! Invoked by the zsh shim as:
//!   npm-run-comp complete --cwd "$PWD" --current $CURRENT -- "${words[@]}"
//!
//! Prints a prompt title on the first line and tab-separated
//! "candidate<TAB>description" items on the following lines. Exits non-zero
//! when it has nothing to offer so the shim can fall back to zsh's default
//! completion (e.g. package names after `npm install`).

mod wellknown;

use std::collections::HashSet;
use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::UNIX_EPOCH;

use serde_json::Value;

/// A completion candidate: name shown/inserted, description shown in preview.
type Item = (String, String);

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("complete") => {}
        Some("version") => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        _ => {
            eprintln!("usage: npm-run-comp complete --cwd DIR --current N -- WORDS...");
            return ExitCode::from(2);
        }
    }

    let mut cwd = None;
    let mut current = 0usize;
    let mut words: Vec<String> = Vec::new();
    let mut it = args.into_iter().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--cwd" => cwd = it.next(),
            "--current" => current = it.next().and_then(|v| v.parse().ok()).unwrap_or(0),
            "--" => {
                words = it.collect();
                break;
            }
            _ => {}
        }
    }
    let cwd = cwd
        .map(PathBuf::from)
        .or_else(|| env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."));

    match complete(&cwd, current, &words) {
        Some(output) => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(output.as_bytes());
            ExitCode::SUCCESS
        }
        None => ExitCode::FAILURE,
    }
}

/// What kind of thing we complete at the current position.
enum Mode {
    Scripts,
    DenoTasks,
    DenoRun,
    Bins,
}

/// Value-taking flags whose following token is a value, not a positional. We
/// skip that value so it never masquerades as the subcommand. `--flag=value`
/// forms are self-contained and need no entry here.
const VALUE_FLAGS: &[&str] = &[
    // directory-changing flags (also set the package.json resolution root)
    "--cwd",
    "--prefix",
    "-C",
    "--dir",
    "--chdir",
    // workspace/filter selectors that take a value
    "-w",
    "--workspace",
    "--filter",
    "-F",
];

/// Flags that change the directory package.json / node_modules are resolved
/// from (npm `--prefix`/`-C`, yarn/bun `--cwd`, pnpm `-C`/`--dir`).
const DIR_FLAGS: &[&str] = &["--cwd", "--prefix", "-C", "--dir", "--chdir"];

/// Flags whose value is a workspace/package name (pnpm `--filter`, npm/yarn/bun
/// `--workspace`/`-w`). We complete those from the monorepo's packages.
const WS_FLAGS: &[&str] = &["--filter", "-F", "--workspace", "-w"];

fn complete(cwd: &Path, current: usize, words: &[String]) -> Option<String> {
    let tool = words.first().map(|w| {
        Path::new(w)
            .file_name()
            .and_then(OsStr::to_str)
            .unwrap_or(w)
    })?;

    let cur_idx = current.saturating_sub(1);
    let cur = words.get(cur_idx).map(String::as_str).unwrap_or("");
    let cur_is_flag = cur.starts_with('-');

    // Words already typed before the cursor (excluding the tool itself). Parse
    // them into positional args + the directory-resolution root, honoring
    // value-taking flags in any order.
    let typed_end = cur_idx.min(words.len());
    let typed = if typed_end >= 1 {
        &words[1..typed_end]
    } else {
        &[][..]
    };
    let (positionals, base_dir) = parse_typed(typed, cwd);
    let sub = positionals.first().map(String::as_str).unwrap_or("");

    // Value slot: the word before the cursor is a value-taking flag typed as
    // `--flag VALUE` (the `--flag=VALUE` form is handled as a flag word above).
    if let Some(prev) = cur_idx.checked_sub(1).and_then(|i| words.get(i)) {
        if WS_FLAGS.contains(&prev.as_str()) {
            return render("workspace", workspace_names(&base_dir));
        }
        if DIR_FLAGS.contains(&prev.as_str()) {
            return None; // a directory — let zsh's default file completion run
        }
    }

    // Executors always complete node_modules/.bin binaries. If the user is
    // typing a flag before any package is named, offer the executor's own
    // flags; once a package is present the flags belong to it, so defer.
    if matches!(tool, "npx" | "bunx" | "pnpx") {
        if cur_is_flag {
            return if sub.is_empty() {
                render(tool, scrape_flags(tool, ""))
            } else {
                None
            };
        }
        return render(tool, list_bin(&base_dir));
    }

    // Typing a flag → complete flags for the current (sub)command from its help.
    if cur_is_flag {
        let prompt = if sub.is_empty() {
            tool.to_string()
        } else {
            format!("{tool} {sub}")
        };
        return render(&prompt, scrape_flags(tool, sub));
    }

    // The subcommand is the first typed positional we recognize. Only complete
    // its argument when it is the last positional (nothing typed after it yet).
    let known = positionals
        .iter()
        .rev()
        .find_map(|p| subcommand_mode(tool, p).map(|m| (p.as_str(), m)));

    if let Some((sub, mode)) = known {
        if positionals.last().map(String::as_str) != Some(sub) {
            return None; // already past the argument slot
        }
        let prompt = format!("{tool} {sub}");
        return match mode {
            Mode::Scripts => render(&prompt, read_scripts(&base_dir)),
            Mode::DenoTasks => render(&prompt, read_deno_tasks(&base_dir)),
            Mode::DenoRun => {
                let mut items = read_deno_tasks(&base_dir);
                merge(&mut items, list_deno_files(&base_dir));
                render(&prompt, items)
            }
            Mode::Bins => render(&prompt, list_bin(&base_dir)),
        };
    }

    // No recognized subcommand. If nothing positional is typed we are at the
    // top-level slot; otherwise it is an argument to some other subcommand
    // (install, add, …) — defer to zsh's default completion.
    if !positionals.is_empty() {
        return None;
    }

    // Top-level: hardcoded commands, augmented with scraped --help extras, plus
    // directly-runnable scripts/tasks for tools that support them.
    let mut items: Vec<Item> = wellknown::commands(tool)
        .iter()
        .map(|(n, d)| (n.to_string(), d.to_string()))
        .collect();
    merge(&mut items, scrape(tool));
    match tool {
        "yarn" | "bun" | "pnpm" => merge(&mut items, labeled(read_scripts(&base_dir), "script")),
        "deno" => merge(&mut items, labeled(read_deno_tasks(&base_dir), "task")),
        _ => {}
    }
    render(tool, items)
}

fn subcommand_mode(tool: &str, sub: &str) -> Option<Mode> {
    if tool == "deno" {
        return match sub {
            "run" => Some(Mode::DenoRun),
            "task" => Some(Mode::DenoTasks),
            _ => None,
        };
    }
    if wellknown::is_run_subcommand(tool, sub) {
        return Some(Mode::Scripts);
    }
    if wellknown::is_exec_subcommand(tool, sub) {
        return Some(Mode::Bins);
    }
    None
}

/// Split typed words into positional arguments and the directory to resolve
/// package.json/node_modules from (default `cwd`, overridden by `--prefix`,
/// `-C`, `--cwd`, `--dir`). Relative flag values resolve against `cwd`.
fn parse_typed(typed: &[String], cwd: &Path) -> (Vec<String>, PathBuf) {
    let mut positionals = Vec::new();
    let mut base = cwd.to_path_buf();
    let mut i = 0;
    while i < typed.len() {
        let tok = typed[i].as_str();
        if let Some((flag, val)) = tok.split_once('=') {
            if DIR_FLAGS.contains(&flag) {
                base = resolve_dir(cwd, val);
            }
            i += 1;
            continue;
        }
        if VALUE_FLAGS.contains(&tok) {
            if DIR_FLAGS.contains(&tok) {
                if let Some(val) = typed.get(i + 1) {
                    base = resolve_dir(cwd, val);
                }
            }
            i += 2; // consume flag + its value
            continue;
        }
        if tok.starts_with('-') {
            i += 1; // boolean/unknown flag
            continue;
        }
        positionals.push(typed[i].clone());
        i += 1;
    }
    (positionals, base)
}

fn resolve_dir(cwd: &Path, val: &str) -> PathBuf {
    let p = Path::new(val);
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        cwd.join(p)
    }
}

/// First line = prompt title, remaining lines = "name\tdesc". None if empty.
fn render(prompt: &str, items: Vec<Item>) -> Option<String> {
    if items.is_empty() {
        return None;
    }
    let mut out = String::with_capacity(prompt.len() + items.len() * 24);
    out.push_str(prompt);
    out.push('\n');
    for (name, desc) in items {
        out.push_str(&name);
        out.push('\t');
        out.push_str(&desc);
        out.push('\n');
    }
    Some(out)
}

/// Append `extra` to `into`, skipping names already present (first wins).
fn merge(into: &mut Vec<Item>, extra: Vec<Item>) {
    let mut seen: HashSet<String> = into.iter().map(|(n, _)| n.clone()).collect();
    for (name, desc) in extra {
        if seen.insert(name.clone()) {
            into.push((name, desc));
        }
    }
}

/// Prefix each description with `[label]` (used to tag scripts/tasks at the
/// top level so they read distinctly from built-in commands).
fn labeled(items: Vec<Item>, label: &str) -> Vec<Item> {
    items
        .into_iter()
        .map(|(n, d)| (n, format!("[{label}] {d}")))
        .collect()
}

// ─────────────────────────── package.json / deno ───────────────────────────

/// Nearest ancestor directory (including `start`) that contains `file`.
fn find_up(start: &Path, file: &str) -> Option<PathBuf> {
    let mut dir = start;
    loop {
        let candidate = dir.join(file);
        if candidate.is_file() {
            return Some(candidate);
        }
        dir = dir.parent()?;
    }
}

fn read_scripts(cwd: &Path) -> Vec<Item> {
    let Some(path) = find_up(cwd, "package.json") else {
        return Vec::new();
    };
    json_entries(&path, "scripts")
}

fn read_deno_tasks(cwd: &Path) -> Vec<Item> {
    let path = find_up(cwd, "deno.json").or_else(|| find_up(cwd, "deno.jsonc"));
    match path {
        Some(p) => json_entries(&p, "tasks"),
        None => Vec::new(),
    }
}

/// Parse `field` (an object) from a JSON/JSONC file into ordered name/value
/// items. Deno tasks can be `{ "command": "...", "description": "..." }`
/// objects rather than plain strings — we surface the command as the value.
fn json_entries(path: &Path, field: &str) -> Vec<Item> {
    let Ok(raw) = fs::read_to_string(path) else {
        return Vec::new();
    };
    // Strict JSON is the common case (package.json); only pay for the JSONC
    // clean-up (comments, trailing commas) when the strict parse fails, which
    // also transparently handles deno.json — Deno accepts comments there too.
    let value = match serde_json::from_str::<Value>(&raw) {
        Ok(v) => v,
        Err(_) => match serde_json::from_str::<Value>(&strip_jsonc(&raw)) {
            Ok(v) => v,
            Err(_) => return Vec::new(),
        },
    };
    let Some(obj) = value.get(field).and_then(Value::as_object) else {
        return Vec::new();
    };
    obj.iter()
        .map(|(k, v)| {
            let desc = match v {
                Value::String(s) => s.clone(),
                Value::Object(o) => o
                    .get("command")
                    .or_else(|| o.get("description"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .unwrap_or_else(|| v.to_string()),
                other => other.to_string(),
            };
            (k.clone(), desc)
        })
        .collect()
}

/// Turn JSONC into JSON serde_json accepts: strip `//` and `/* */` comments and
/// drop trailing commas, both only outside string literals. Operates on bytes
/// so multibyte UTF-8 inside strings is copied verbatim, never mangled.
fn strip_jsonc(src: &str) -> String {
    let no_comments = strip_comments(src.as_bytes());
    let no_trailing = strip_trailing_commas(&no_comments);
    String::from_utf8_lossy(&no_trailing).into_owned()
}

fn strip_comments(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    let mut in_str = false;
    while i < bytes.len() {
        let b = bytes[i];
        if in_str {
            out.push(b);
            if b == b'\\' && i + 1 < bytes.len() {
                out.push(bytes[i + 1]);
                i += 2;
                continue;
            }
            if b == b'"' {
                in_str = false;
            }
            i += 1;
            continue;
        }
        match b {
            b'"' => {
                in_str = true;
                out.push(b'"');
                i += 1;
            }
            b'/' if bytes.get(i + 1) == Some(&b'/') => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
            }
            b'/' if bytes.get(i + 1) == Some(&b'*') => {
                i += 2;
                while i + 1 < bytes.len() && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                    i += 1;
                }
                i += 2;
            }
            _ => {
                out.push(b);
                i += 1;
            }
        }
    }
    out
}

fn strip_trailing_commas(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    let mut in_str = false;
    while i < bytes.len() {
        let b = bytes[i];
        if in_str {
            out.push(b);
            if b == b'\\' && i + 1 < bytes.len() {
                out.push(bytes[i + 1]);
                i += 2;
                continue;
            }
            if b == b'"' {
                in_str = false;
            }
            i += 1;
            continue;
        }
        if b == b'"' {
            in_str = true;
        } else if b == b',' {
            let mut j = i + 1;
            while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                j += 1;
            }
            if matches!(bytes.get(j), Some(b'}') | Some(b']')) {
                i += 1; // drop the trailing comma
                continue;
            }
        }
        out.push(b);
        i += 1;
    }
    out
}

// ─────────────────────────── node_modules/.bin ───────────────────────────

fn list_bin(cwd: &Path) -> Vec<Item> {
    let Some(pkg) = find_up(cwd, "package.json") else {
        return Vec::new();
    };
    let bin = pkg.with_file_name("node_modules").join(".bin");
    let Ok(entries) = fs::read_dir(&bin) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| !n.starts_with('.'))
        .collect();
    names.sort();
    names.dedup();
    names
        .into_iter()
        .map(|n| (n, "[bin]".to_string()))
        .collect()
}

// ─────────────────────────── workspace packages ───────────────────────────

/// Package names for `--filter`/`--workspace` values: every nested
/// `package.json`'s `name` field (falling back to its directory) under the
/// monorepo root, excluding the root itself and `node_modules`.
fn workspace_names(cwd: &Path) -> Vec<Item> {
    let root = find_up(cwd, "package.json")
        .and_then(|p| p.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| cwd.to_path_buf());
    let mut out = Vec::new();
    collect_packages(&root, &root, 0, &mut out);
    out.sort();
    out.dedup();
    out.truncate(200);
    out.into_iter()
        .map(|(name, rel)| (name, format!("[workspace] {rel}")))
        .collect()
}

fn collect_packages(root: &Path, dir: &Path, depth: usize, out: &mut Vec<(String, String)>) {
    if depth > 4 || out.len() >= 400 {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name == "node_modules" || name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let pkg = path.join("package.json");
        if pkg.is_file() {
            let rel = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .into_owned();
            let pkg_name = fs::read_to_string(&pkg)
                .ok()
                .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
                .and_then(|v| v.get("name").and_then(Value::as_str).map(str::to_string))
                .unwrap_or_else(|| rel.clone());
            out.push((pkg_name, rel));
        }
        collect_packages(root, &path, depth + 1, out);
    }
}

// ─────────────────────────── deno run: source files ───────────────────────────

/// TS/JS files up to 3 levels deep under `cwd`, excluding node_modules. Capped
/// so a huge tree never floods the picker.
fn list_deno_files(cwd: &Path) -> Vec<Item> {
    const EXTS: &[&str] = &["ts", "js", "mts", "mjs"];
    let mut out = Vec::new();
    collect_files(cwd, cwd, 0, EXTS, &mut out);
    out.sort();
    out.truncate(30);
    out.into_iter().map(|f| (f, "[file]".to_string())).collect()
}

fn collect_files(root: &Path, dir: &Path, depth: usize, exts: &[&str], out: &mut Vec<String>) {
    if depth > 2 || out.len() >= 200 {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name == "node_modules" || name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        if path.is_dir() {
            collect_files(root, &path, depth + 1, exts, out);
        } else if path
            .extension()
            .and_then(OsStr::to_str)
            .is_some_and(|e| exts.contains(&e))
        {
            if let Ok(rel) = path.strip_prefix(root) {
                out.push(rel.to_string_lossy().into_owned());
            }
        }
    }
}

// ─────────────────────────── --help scraping ───────────────────────────

/// Cache key that changes whenever the tool binary does: its path, mtime and
/// size, all from one stat. No fork, no `--version` call — a tool upgrade
/// rewrites the file, so the key changes and we rescrape exactly once.
fn tool_key(tool: &str) -> Option<u64> {
    let bin = which(tool)?;
    let (mtime, size) = fs::metadata(&bin)
        .map(|m| {
            let t = m
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            (t, m.len())
        })
        .unwrap_or((0, 0));
    Some(fnv(format!("{}:{mtime}:{size}", bin.display()).as_bytes()))
}

/// Read a `namespace_tool_slot`-prefixed cache, or generate + persist it. The
/// warm path is a single file read — no fork, no dir stat.
fn cached(namespace: &str, tool: &str, slot: &str, gen: impl FnOnce() -> Vec<Item>) -> Vec<Item> {
    let Some(key) = tool_key(tool) else {
        return Vec::new();
    };
    let dir = cache_dir();
    let prefix = format!("{namespace}_{tool}_{slot}_");
    let cache = dir.join(format!("{prefix}{key:016x}.cache"));

    if let Ok(text) = fs::read_to_string(&cache) {
        return parse_cache(&text);
    }

    let _ = fs::create_dir_all(&dir);
    prune(&dir, &prefix); // drop entries for this tool+slot from older versions
    let items = gen();
    let mut buf = String::new();
    for (n, d) in &items {
        buf.push_str(n);
        buf.push('\t');
        buf.push_str(d);
        buf.push('\n');
    }
    let _ = fs::write(&cache, &buf);
    items
}

/// Extra commands parsed from a tool's own `--help`, augmenting the hardcoded
/// tables with version-specific and plugin subcommands.
fn scrape(tool: &str) -> Vec<Item> {
    cached("cmd", tool, "_", || {
        let output = if tool == "npm" {
            Command::new("npm")
                .arg("help")
                .stderr(Stdio::null())
                .output()
        } else {
            Command::new(tool)
                .arg("--help")
                .stderr(Stdio::null())
                .output()
        };
        let Ok(output) = output else {
            return Vec::new();
        };
        let text = String::from_utf8_lossy(&output.stdout);
        if tool == "npm" {
            parse_npm_help(&text)
        } else {
            parse_indented_help(tool, &text)
        }
    })
}

/// Flags for `tool [sub]`, parsed from `tool [sub] --help`. Cached per tool+sub.
fn scrape_flags(tool: &str, sub: &str) -> Vec<Item> {
    let slot: String = if sub.is_empty() {
        "top".into()
    } else {
        // Sanitize the subcommand for use in a filename.
        sub.chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
            .collect()
    };
    cached("flags", tool, &slot, || {
        let mut cmd = Command::new(tool);
        if !sub.is_empty() {
            cmd.arg(sub);
        }
        let Ok(output) = cmd.arg("--help").stderr(Stdio::null()).output() else {
            return Vec::new();
        };
        parse_flags(&String::from_utf8_lossy(&output.stdout))
    })
}

fn parse_cache(text: &str) -> Vec<Item> {
    text.lines()
        .filter_map(|l| l.split_once('\t'))
        .map(|(n, d)| (n.to_string(), d.to_string()))
        .collect()
}

/// npm lists commands comma-separated under an "All commands:" header.
fn parse_npm_help(text: &str) -> Vec<Item> {
    let mut out = Vec::new();
    let mut in_section = false;
    for line in text.lines() {
        if line.starts_with("All commands:") {
            in_section = true;
            continue;
        }
        if in_section {
            // Section ends at the first non-indented, non-blank line.
            if !line.is_empty() && !line.starts_with(char::is_whitespace) {
                break;
            }
            for tok in line.split(',') {
                let name = tok.trim();
                if is_command_name(name) {
                    out.push((name.to_string(), "npm command".to_string()));
                }
            }
        }
    }
    out
}

/// Generic help layout: `  <command>   <description>` indented 2+ spaces.
fn parse_indented_help(tool: &str, text: &str) -> Vec<Item> {
    let mut out = Vec::new();
    for line in text.lines() {
        let indent = line.len() - line.trim_start().len();
        if !(2..=6).contains(&indent) {
            continue;
        }
        let rest = line.trim_start();
        // Split command from description on the first run of 2+ spaces.
        let (name, desc) = match rest.find("  ") {
            Some(pos) => (rest[..pos].trim(), rest[pos..].trim()),
            None => (rest.trim(), ""),
        };
        // Some tools list aliases as "i, install" — take the canonical last one.
        let name = name.split(',').next_back().unwrap_or(name).trim();
        if is_command_name(name) {
            let desc = if desc.is_empty() {
                format!("{tool} command")
            } else {
                desc.to_string()
            };
            out.push((name.to_string(), desc));
        }
    }
    out
}

fn is_command_name(s: &str) -> bool {
    !s.is_empty()
        && s.as_bytes()[0].is_ascii_lowercase()
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// Parse option flags from help text. Handles the common
/// `  -x, --flag <val>   description` layout (pnpm/bun/yarn/deno); npm prints a
/// bracketed synopsis instead, handled by the fallback when this finds nothing.
fn parse_flags(text: &str) -> Vec<Item> {
    let mut out: Vec<Item> = Vec::new();
    let mut seen = HashSet::new();
    for line in text.lines() {
        let t = line.trim_start();
        if !t.starts_with('-') {
            continue;
        }
        let (flag_part, desc) = match t.find("  ") {
            Some(pos) => (&t[..pos], t[pos..].trim()),
            None => (t, ""),
        };
        // `--[no-]color` → the positive `--color` form.
        let flag_part = flag_part.replace("[no-]", "");
        // Offer every form on the line — long `--flag` first, then any short
        // `-x` alias — so both are completable.
        let mut long = None;
        let mut short = None;
        for piece in flag_part.split(|c: char| c == ',' || c.is_whitespace()) {
            let cleaned = clean_flag(piece);
            if cleaned.starts_with("--") && long.is_none() {
                long = Some(cleaned);
            } else if cleaned.len() == 2 && cleaned.starts_with('-') && short.is_none() {
                short = Some(cleaned);
            }
        }
        for flag in [long, short].into_iter().flatten() {
            if seen.insert(flag.clone()) {
                out.push((flag, desc.to_string()));
            }
        }
    }
    if out.is_empty() {
        return parse_npm_flags(text);
    }
    out
}

/// Strip a value placeholder (`--flag=<v>`, `--flag[=<v>]`) and validate.
fn clean_flag(piece: &str) -> String {
    let p = piece.trim();
    if !p.starts_with('-') {
        return String::new();
    }
    let end = p.find(['=', '[']).unwrap_or(p.len());
    let flag = &p[..end];
    let body = flag.trim_start_matches('-');
    if !body.is_empty() && body.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        flag.to_string()
    } else {
        String::new()
    }
}

/// npm prints options as a bracketed synopsis under `Options:`, e.g.
/// `[-S|--save|--no-save|...] [-g|--global]`. Pull both long `--flag` and short
/// `-x` tokens out (a short flag is a single dash + one alphanumeric, delimited
/// by `|`, `[`, `]` or whitespace so it is not confused with a `--flag`).
fn parse_npm_flags(text: &str) -> Vec<Item> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let mut in_opts = false;
    for line in text.lines() {
        if line.trim() == "Options:" {
            in_opts = true;
            continue;
        }
        if !in_opts {
            continue;
        }
        if line.trim().is_empty() {
            break;
        }
        let bytes = line.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] != b'-' {
                i += 1;
                continue;
            }
            let start = i;
            let long = bytes.get(i + 1) == Some(&b'-');
            i += if long { 2 } else { 1 };
            let body_start = i;
            while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'-') {
                i += 1;
            }
            // Long flag: 2+ body chars. Short flag: exactly one alphanumeric.
            let body_len = i - body_start;
            let ok = if long {
                body_len >= 2
            } else {
                body_len == 1 && bytes[body_start].is_ascii_alphanumeric()
            };
            if ok {
                let flag = &line[start..i];
                if seen.insert(flag.to_string()) {
                    out.push((flag.to_string(), "npm option".to_string()));
                }
            }
        }
    }
    out
}

// ─────────────────────────── utilities ───────────────────────────

/// First executable named `tool` on $PATH. Fork-free.
fn which(tool: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    for dir in env::split_paths(&path) {
        let candidate = dir.join(tool);
        if let Ok(meta) = fs::metadata(&candidate) {
            if meta.is_file() && meta.permissions().mode() & 0o111 != 0 {
                return Some(candidate);
            }
        }
    }
    None
}

fn cache_dir() -> PathBuf {
    if let Some(x) = env::var_os("PACKAGE_COMPLETIONS_CACHE_DIR") {
        return PathBuf::from(x);
    }
    let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join(".cache").join("npm-run-comp")
}

/// Delete cache files starting with `prefix` (stale entries for a tool).
fn prune(dir: &Path, prefix: &str) {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            if entry.file_name().to_string_lossy().starts_with(prefix) {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
}

fn fnv(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(items: &[Item]) -> Vec<&str> {
        items.iter().map(|(n, _)| n.as_str()).collect()
    }

    #[test]
    fn npm_base_offers_run_alias() {
        // The whole point: `npm <Tab>` must offer `run`, which npm's own help
        // hides behind `run-script`.
        let out = complete(Path::new("/nonexistent"), 2, &["npm".into(), "".into()]).unwrap();
        let first = out.lines().next().unwrap();
        assert_eq!(first, "npm");
        assert!(out.lines().any(|l| l.starts_with("run\t")), "{out}");
    }

    #[test]
    fn merge_is_first_wins() {
        let mut a = vec![("run".into(), "hardcoded".into())];
        merge(
            &mut a,
            vec![("run".into(), "scraped".into()), ("x".into(), "new".into())],
        );
        assert_eq!(names(&a), ["run", "x"]);
        assert_eq!(a[0].1, "hardcoded");
    }

    #[test]
    fn parses_scripts_and_deno_tasks() {
        let dir = env::temp_dir().join(format!("nrc-test-{}", fnv(b"scripts")));
        let _ = fs::create_dir_all(&dir);
        fs::write(
            dir.join("package.json"),
            r#"{"scripts":{"dev":"vite","build":"tsc && vite build"}}"#,
        )
        .unwrap();
        let items = read_scripts(&dir);
        assert_eq!(names(&items), ["dev", "build"]);
        assert_eq!(items[1].1, "tsc && vite build");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn strips_jsonc_comments() {
        let src = r#"{
            // a comment
            "tasks": { "dev": "deno run --watch main.ts" } /* inline */
        }"#;
        let cleaned = strip_jsonc(src);
        assert!(!cleaned.contains("comment"));
        assert!(!cleaned.contains("inline"));
        let v: Value = serde_json::from_str(&cleaned).unwrap();
        assert_eq!(v["tasks"]["dev"], "deno run --watch main.ts");
    }

    #[test]
    fn npm_help_parser_extracts_run_script() {
        let help = "npm <command>\n\nAll commands:\n\n    access, run-script, install,\n    test, view\n\nSpecify configs\n";
        let cmds = parse_npm_help(help);
        assert!(names(&cmds).contains(&"run-script"));
        assert!(names(&cmds).contains(&"install"));
        assert!(!names(&cmds).contains(&"Specify"));
    }

    #[test]
    fn unknown_subcommand_yields_nothing() {
        // `npm install <Tab>` — no scripts here; shim should fall back.
        let out = complete(
            Path::new("/nonexistent"),
            3,
            &["npm".into(), "install".into(), "".into()],
        );
        assert!(out.is_none());
    }

    fn scripts_dir(tag: &str) -> PathBuf {
        let dir = env::temp_dir().join(format!("nrc-{}-{:x}", tag, fnv(tag.as_bytes())));
        let _ = fs::create_dir_all(&dir);
        fs::write(
            dir.join("package.json"),
            r#"{"scripts":{"dev":"vite","build":"tsc"}}"#,
        )
        .unwrap();
        dir
    }

    fn w(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn scripts_survive_flags_before_and_after_run() {
        let dir = scripts_dir("flags");
        // Flag before `run`, value-flag consuming its value, flag after `run`.
        for words in [
            w(&["npm", "run", ""]),
            w(&["npm", "run", "--silent", ""]),
            w(&["npm", "--workspace", "pkg-a", "run", ""]),
            w(&["pnpm", "--filter", "web", "run", ""]),
        ] {
            let cur = words.len();
            let out = complete(&dir, cur, &words).unwrap_or_default();
            assert!(
                out.lines().any(|l| l.starts_with("dev\t")),
                "expected scripts for {words:?}, got: {out}"
            );
        }
        // Past the script slot → defer.
        let words = w(&["npm", "run", "dev", ""]);
        assert!(complete(&dir, words.len(), &words).is_none());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn executor_flag_after_package_defers() {
        // `npx eslint --<Tab>` — flags belong to eslint, not npx, so defer to
        // zsh's default completion. Deterministic (no --help fork).
        let words = w(&["npx", "eslint", "--"]);
        assert!(complete(Path::new("/nonexistent"), words.len(), &words).is_none());
    }

    #[test]
    fn jsonc_comments_and_trailing_commas() {
        let src = r#"{
            // leading comment
            "tasks": {
                "dev": "deno run main.ts", // trailing line comment
                "build": "deno task check", /* block */
            },
        }"#;
        let cleaned = strip_jsonc(src);
        let v: Value = serde_json::from_str(&cleaned).unwrap();
        assert_eq!(v["tasks"]["dev"], "deno run main.ts");
        assert_eq!(v["tasks"]["build"], "deno task check");
    }

    #[test]
    fn jsonc_preserves_multibyte_and_url_slashes() {
        // `//` inside a string is not a comment; multibyte must survive.
        let src = r#"{ "scripts": { "greet": "echo café — https://x/y" } }"#;
        let v: Value = serde_json::from_str(&strip_jsonc(src)).unwrap();
        assert_eq!(v["scripts"]["greet"], "echo café — https://x/y");
    }

    #[test]
    fn parse_flags_generic_layout() {
        let help = "\nOptions:\n  -c, --config <FILE>   path to config\n      --[no-]color      toggle color\n      --dry-run         no changes\n";
        let flags = parse_flags(help);
        let n = names(&flags);
        assert!(n.contains(&"--config"), "{n:?}");
        assert!(n.contains(&"--color"), "{n:?}");
        assert!(n.contains(&"--dry-run"), "{n:?}");
        // Description is carried through.
        assert_eq!(
            flags.iter().find(|(f, _)| f == "--config").unwrap().1,
            "path to config"
        );
    }

    #[test]
    fn parse_flags_offers_short_and_long() {
        let help = "\nOptions:\n  -g, --global      install globally\n";
        let flags = parse_flags(help);
        let n = names(&flags);
        assert!(n.contains(&"--global"), "{n:?}");
        assert!(n.contains(&"-g"), "{n:?}");
    }

    #[test]
    fn parse_flags_npm_synopsis_fallback() {
        let help = "Usage:\nnpm install\n\nOptions:\n[-S|--save|--no-save|--save-dev] [-g|--global]\n[--install-strategy <hoisted|nested>]\n\naliases: add\n";
        let flags = parse_flags(help);
        let n = names(&flags);
        assert!(n.contains(&"--save"), "{n:?}");
        assert!(n.contains(&"--save-dev"), "{n:?}");
        assert!(n.contains(&"--global"), "{n:?}");
        assert!(n.contains(&"--install-strategy"), "{n:?}");
        // Short flags from the bracketed synopsis too.
        assert!(n.contains(&"-S"), "{n:?}");
        assert!(n.contains(&"-g"), "{n:?}");
    }

    #[test]
    fn workspace_value_completion() {
        let root = env::temp_dir().join(format!("nrc-ws-{:x}", fnv(b"ws")));
        let _ = fs::create_dir_all(root.join("packages/api"));
        let _ = fs::create_dir_all(root.join("packages/web"));
        fs::write(
            root.join("package.json"),
            r#"{"workspaces":["packages/*"]}"#,
        )
        .unwrap();
        fs::write(
            root.join("packages/api/package.json"),
            r#"{"name":"@acme/api"}"#,
        )
        .unwrap();
        fs::write(
            root.join("packages/web/package.json"),
            r#"{"name":"@acme/web"}"#,
        )
        .unwrap();
        // `pnpm --filter <Tab>` → package names.
        let words = w(&["pnpm", "--filter", ""]);
        let out = complete(&root, words.len(), &words).unwrap();
        assert_eq!(out.lines().next(), Some("workspace"));
        assert!(out.lines().any(|l| l.starts_with("@acme/api\t")), "{out}");
        assert!(out.lines().any(|l| l.starts_with("@acme/web\t")), "{out}");
        // `npm --prefix <Tab>` is a directory → defer to zsh.
        let words = w(&["npm", "--prefix", ""]);
        assert!(complete(&root, words.len(), &words).is_none());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn prefix_flag_points_at_nested_package_json() {
        let root = env::temp_dir().join(format!("nrc-nested-{:x}", fnv(b"nested")));
        let nested = root.join("packages").join("api");
        let _ = fs::create_dir_all(&nested);
        fs::write(
            nested.join("package.json"),
            r#"{"scripts":{"serve":"node ."}}"#,
        )
        .unwrap();
        // Running npm from `root` but pointing --prefix at the nested package.
        for words in [
            w(&["npm", "--prefix", "packages/api", "run", ""]),
            w(&["npm", "--prefix=packages/api", "run", ""]),
            w(&["npm", "-C", "packages/api", "run", ""]),
        ] {
            let out = complete(&root, words.len(), &words).unwrap_or_default();
            assert!(
                out.lines().any(|l| l.starts_with("serve\t")),
                "expected nested scripts for {words:?}, got: {out}"
            );
        }
        let _ = fs::remove_dir_all(&root);
    }
}
