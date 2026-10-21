{
  perSystem = { config, lib, pkgs, ... }:
    let
      crate = (lib.importTOML ../Cargo.toml).package;
      npm-run-comp = config.packages.npm-run-comp;
    in
    {
      packages = {
        npm-run-comp = pkgs.rustPlatform.buildRustPackage {
          pname = crate.name;
          inherit (crate) version;

          src = lib.fileset.toSource {
            root = ../.;
            fileset = lib.fileset.difference (lib.fileset.gitTracked ../.) (
              lib.fileset.unions [
                ../flake.nix
                ../flake.lock
                ../nix
              ]
            );
          };

          # Vendors deps straight from the committed Cargo.lock, so there is no
          # separate hash to bump — `cargo update` + commit is the only step.
          cargoLock.lockFile = ../Cargo.lock;

          meta = {
            inherit (crate) description;
            homepage = "https://github.com/stubbedev/zsh-fzf-npm-run";
            license = lib.licenses.mit;
            mainProgram = crate.name;
            platforms = lib.platforms.unix;
          };
        };
        default = npm-run-comp;
      };

      apps.default = {
        type = "app";
        program = lib.getExe npm-run-comp;
      };

      checks.build = npm-run-comp;
    };
}
