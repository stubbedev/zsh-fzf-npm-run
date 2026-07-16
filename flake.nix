{
  description = "npm-run-comp — completion engine for zsh-fzf-npm-run";

  # Pull prebuilt closures from the self-hosted xilo cache (populated by CI on
  # every master push and release tag) instead of compiling locally.
  nixConfig = {
    extra-substituters = [ "https://nix.stubbe.dev/c/default/default" ];
    extra-trusted-public-keys = [ "default:6uWvXutL9cXjV3lii+Ur5ff+ArQoG4kMBKNXWrIxhHg=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        npm-run-comp = pkgs.rustPlatform.buildRustPackage {
          pname = "npm-run-comp";
          version = "0.1.1";
          src = ./.;
          # Vendors deps straight from the committed Cargo.lock, so there is no
          # separate hash to bump — `cargo update` + commit is the only step.
          cargoLock.lockFile = ./Cargo.lock;
        };
      in
      {
        packages = {
          default = npm-run-comp;
          npm-run-comp = npm-run-comp;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = npm-run-comp;
          name = "npm-run-comp";
        };

        checks.build = npm-run-comp;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            cargo
            rustc
            rustfmt
            clippy
            just
          ];
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
