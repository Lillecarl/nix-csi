let
  flake-compatish = builtins.fetchTree {
    type = "github";
    owner = "lillecarl";
    repo = "flake-compatish";
    ref = "main";
  };
  nixpkgs = builtins.fetchTree {
    type = "github";
    owner = "NixOS";
    repo = "nixpkgs";
    ref = "nixos-unstable";
  };
  nixng = builtins.fetchTree {
    type = "github";
    owner = "nix-community";
    repo = "nixNG";
    ref = "master";
  };
  pkgs = import nixpkgs {};
  flake = (import flake-compatish) nixpkgs;
  nglib = import "${nixng}/lib" flake.outputs.lib;
in
{
  inherit flake;
  nixNG = nglib.makeSystem {
    nixpkgs = flake.outputs;
    system = builtins.currentSystem;
    name = "nixng-nix";

    config = (
      { pkgs, ... }:
      {
        dumb-init = {
          enable = true;
          type.shell = { };
        };
        nix = {
          enable = true;
          package = pkgs.nixStable;
          config = {
            experimental-features = [
              "nix-command"
              "flakes"
            ];
            sandbox = false;
          };
        };
      }
    );
  };
}.nixNG.config.system.build.toplevel
