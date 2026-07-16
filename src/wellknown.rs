//! Hardcoded command tables per package manager — the source of truth for
//! top-level (`npm <Tab>`) completion. Scraped `--help` output is merged on top
//! (see `main::scrape`), but these tables guarantee the common commands and
//! their aliases are always offered, regardless of the installed version's help
//! format. This is what makes `npm run` appear even though `npm help` only
//! lists the canonical `run-script`.

pub type Cmd = (&'static str, &'static str);

pub fn commands(tool: &str) -> &'static [Cmd] {
    match tool {
        "npm" => NPM,
        "yarn" => YARN,
        "bun" => BUN,
        "pnpm" => PNPM,
        "deno" => DENO,
        _ => &[],
    }
}

/// Subcommands that run a package.json script directly (offer scripts after them).
pub fn is_run_subcommand(tool: &str, sub: &str) -> bool {
    matches!(
        (tool, sub),
        ("npm", "run") | ("npm", "run-script") | (_, "run")
    )
}

/// Subcommands that execute a node_modules/.bin binary (offer bins after them).
pub fn is_exec_subcommand(tool: &str, sub: &str) -> bool {
    matches!(
        (tool, sub),
        ("npm", "exec")
            | ("npm", "x")
            | ("bun", "x")
            | ("pnpm", "dlx")
            | ("pnpm", "exec")
            | ("yarn", "dlx")
            | ("yarn", "exec")
    )
}

const NPM: &[Cmd] = &[
    ("run", "run a script defined in package.json"),
    ("run-script", "run a script defined in package.json"),
    ("install", "install dependencies"),
    ("i", "install dependencies"),
    ("ci", "clean install from lockfile"),
    ("test", "run the test script"),
    ("t", "run the test script"),
    ("start", "run the start script"),
    ("stop", "run the stop script"),
    ("restart", "restart a package"),
    ("exec", "run a command from a package"),
    ("x", "run a command from a package"),
    ("uninstall", "remove a package"),
    ("un", "remove a package"),
    ("update", "update packages"),
    ("up", "update packages"),
    ("outdated", "check for outdated packages"),
    ("dedupe", "reduce duplication in the package tree"),
    ("audit", "run a security audit"),
    ("publish", "publish a package"),
    ("pack", "create a tarball from a package"),
    ("version", "bump a package version"),
    ("view", "view registry info"),
    ("search", "search the registry"),
    ("init", "create a package.json"),
    ("link", "symlink a package folder"),
    ("ls", "list installed packages"),
    ("list", "list installed packages"),
    ("pkg", "manage package.json fields"),
    ("config", "manage the npm configuration"),
    ("get", "get a config value"),
    ("set", "set a config value"),
    ("fund", "show funding information"),
    ("rebuild", "rebuild a package"),
    ("prune", "remove extraneous packages"),
    ("explain", "explain why a package is installed"),
    ("doctor", "check your npm environment"),
    ("login", "log in to a registry"),
    ("logout", "log out of a registry"),
    ("whoami", "display the logged-in username"),
    ("help", "show help for a command"),
];

const YARN: &[Cmd] = &[
    ("run", "run a script defined in package.json"),
    ("install", "install dependencies"),
    ("add", "add a dependency"),
    ("remove", "remove a dependency"),
    ("up", "upgrade dependencies"),
    ("upgrade", "upgrade dependencies"),
    ("upgrade-interactive", "interactively upgrade dependencies"),
    ("dlx", "run a package in a temporary environment"),
    ("exec", "run a shell command in the project"),
    ("dedupe", "deduplicate dependencies"),
    ("info", "show package information"),
    ("why", "show why a package is installed"),
    ("init", "create a new package"),
    ("link", "connect a local package"),
    ("unlink", "disconnect a local package"),
    ("node", "run node with the project environment"),
    ("outdated", "check for outdated packages"),
    ("pack", "create a package tarball"),
    ("patch", "prepare a package for patching"),
    ("plugin", "manage yarn plugins"),
    ("publish", "publish a package"),
    ("rebuild", "rebuild native packages"),
    ("set", "set yarn configuration"),
    ("config", "manage yarn configuration"),
    ("version", "manage the package version"),
    ("workspace", "run a command in a workspace"),
    ("workspaces", "manage workspaces"),
    ("cache", "manage the yarn cache"),
];

const BUN: &[Cmd] = &[
    ("run", "run a script or file"),
    ("install", "install dependencies"),
    ("i", "install dependencies"),
    ("add", "add a dependency"),
    ("a", "add a dependency"),
    ("remove", "remove a dependency"),
    ("rm", "remove a dependency"),
    ("update", "update dependencies"),
    ("x", "run a package binary"),
    ("create", "scaffold a new project"),
    ("init", "create a new bun project"),
    ("build", "bundle a project"),
    ("test", "run tests"),
    ("upgrade", "upgrade bun"),
    ("link", "link a local package"),
    ("unlink", "unlink a local package"),
    ("pm", "manage packages and the cache"),
    ("outdated", "check for outdated packages"),
    ("publish", "publish a package"),
    ("patch", "patch a dependency"),
    ("audit", "run a security audit"),
    ("why", "explain why a package is installed"),
    ("exec", "run a shell command"),
    ("repl", "start a bun repl"),
];

const PNPM: &[Cmd] = &[
    ("run", "run a script defined in package.json"),
    ("install", "install dependencies"),
    ("i", "install dependencies"),
    ("add", "add a dependency"),
    ("remove", "remove a dependency"),
    ("rm", "remove a dependency"),
    ("update", "update dependencies"),
    ("up", "update dependencies"),
    ("exec", "run a command from node_modules/.bin"),
    ("dlx", "run a package in a temporary environment"),
    ("create", "create a project from a template"),
    ("init", "create a package.json"),
    ("link", "link a local package"),
    ("unlink", "unlink a local package"),
    ("import", "generate a pnpm lockfile from another"),
    ("rebuild", "rebuild a package"),
    ("prune", "remove unneeded packages"),
    ("fetch", "fetch packages into the store"),
    ("dedupe", "deduplicate the lockfile"),
    ("patch", "prepare a package for patching"),
    ("publish", "publish a package"),
    ("pack", "create a package tarball"),
    ("audit", "run a security audit"),
    ("outdated", "check for outdated packages"),
    ("list", "list installed packages"),
    ("ls", "list installed packages"),
    ("why", "show why a package is installed"),
    ("store", "manage the content-addressable store"),
    ("config", "manage the pnpm configuration"),
    ("test", "run the test script"),
    ("t", "run the test script"),
    ("start", "run the start script"),
    ("deploy", "deploy a package from a workspace"),
    ("dev", "run the dev script"),
    ("root", "print the node_modules path"),
    ("bin", "print the node_modules/.bin path"),
    ("env", "manage node environments"),
    ("doctor", "check for common issues"),
];

const DENO: &[Cmd] = &[
    ("run", "run a program"),
    ("serve", "run a server"),
    ("task", "run a task defined in the config"),
    ("repl", "start a read-eval-print loop"),
    ("eval", "evaluate a script"),
    ("test", "run tests"),
    ("bench", "run benchmarks"),
    ("fmt", "format source files"),
    ("lint", "lint source files"),
    ("check", "type-check without running"),
    ("compile", "compile to a standalone executable"),
    ("doc", "show documentation"),
    ("info", "show info about a module"),
    ("install", "install a script as an executable"),
    ("uninstall", "uninstall a script"),
    ("add", "add dependencies"),
    ("remove", "remove dependencies"),
    ("cache", "cache dependencies"),
    ("coverage", "print coverage reports"),
    ("init", "scaffold a new project"),
    ("jupyter", "run the deno jupyter kernel"),
    ("lsp", "start the language server"),
    ("upgrade", "upgrade deno"),
    ("completions", "generate shell completions"),
    ("publish", "publish a package to jsr"),
];
