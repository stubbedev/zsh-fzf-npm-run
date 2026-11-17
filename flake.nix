{
  description = "npm-run-comp — completion engine for zsh-fzf-npm-run";

  # Pull prebuilt closures from the self-hosted xilo cache (populated by CI on
  # every master push and release tag) instead of compiling locally.
  nixConfig = {
    extra-substituters = [ "https://xilos.dev/c/stubbedev/main" ];
    extra-trusted-public-keys = [ "xilos.dev/stubbedev/main-1:397R6S49v/FSvP+mZ3HlKrVN1KXhgzHIEIHxA/UuG6Y=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      imports = [
        ./nix/package.nix
        ./nix/shell.nix
      ];
    };
}
