{ config, lib, ... }:
let
  cfg = config.nix-csi;
in
{
  config = lib.mkIf cfg.enable {
    kubernetes.resources.${cfg.namespace}.ConfigMap.nix-config.data = {
      "nix.conf" = ''
        # Use root as builder since that's the only user in the container.
        build-users-group = nobody
        # Auto allocare uids so we don't have to create lots of users in containers
        auto-allocate-uids = true
        # This supposedly helps with the sticky cache issue
        fallback = true
        # Enable common features
        experimental-features = nix-command flakes auto-allocate-uids fetch-closure pipe-operator
        # binary cache configuration
        ${lib.optionalString cfg.enableBinaryCache ''
          trusted-public-keys = ${builtins.readFile ../cache-public} cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
          substituters = http://nix-cache.${cfg.namespace}.svc https://cache.nixos.org
        ''}
        # Fuck purity
        warn-dirty = false
      '';
      "nix-path.nix" = # nix
        ''
          let
            paths = {
              nixpkgs = builtins.fetchTree {
                type = "github";
                owner = "nixos";
                repo = "nixpkgs";
                ref = "nixos-25.05";
              };
              nixos-unstable = builtins.fetchTree {
                type = "github";
                owner = "nixos";
                repo = "nixpkgs";
                ref = "nixos-unstable";
              };
              home-manager = builtins.fetchTree {
                type = "github";
                owner = "nix-community";
                repo = "home-manager";
                ref = "release-25.05";
              };
              home-manager-unstable = builtins.fetchTree {
                type = "github";
                owner = "nix-community";
                repo = "home-manager";
                ref = "master";
              };
              dinix = builtins.fetchTree {
                type = "github";
                owner = "lillecarl";
                repo = "dinix";
                ref = "main";
              };
              flake-compatish = builtins.fetchTree {
                type = "github";
                owner = "lillecarl";
                repo = "flake-compatish";
                ref = "main";
              };
            };

            pkgs = import paths.nixpkgs { };
            inherit (pkgs) lib;

          in
          lib.pipe paths [
            (lib.mapAttrsToList (name: value: "''${name}=''${value}"))
            (lib.concatStringsSep ":")
            (pkgs.writeText "NIX_PATH")
          ]
        '';
    };
  };
}
