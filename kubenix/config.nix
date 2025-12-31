{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nix-csi;

  defaultSystemFeatures = [
    "nixos-test"
    "benchmark"
    "big-parallel"
    # "kvm"
  ];

  semanticConfType =
    with lib.types;
    let
      confAtom =
        nullOr (oneOf [
          bool
          int
          float
          str
          path
          package
        ])
        // {
          description = "Nix config atom (null, bool, int, float, str, path or package)";
        };
    in
    attrsOf (either confAtom (listOf confAtom));

  nixSubmodule =
    with lib;
    types.submodule (
      { config, ... }:
      {
        options = {
          nixConf = mkOption {
            type = types.package;
            internal = true;
          };

          checkConfig = mkOption {
            type = types.bool;
            default = true;
          };

          checkAllErrors = mkOption {
            type = types.bool;
            default = true;
          };

          extraOptions = mkOption {
            type = types.lines;
            default = "";
          };

          settings = mkOption {
            type = types.submodule {
              freeformType = semanticConfType;
              options = { };
            };
            default = { };
          };
        };
        config = {
          settings = {
            trusted-public-keys = [
              "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
              "nix-csi.cachix.org-1:i4w33gR4efO67jpz8U7g/MdvRQ6mQ3LEF9fB8tES60g="
            ];
            substituters = [
              "https://cache.nixos.org"
              "https://nix-csi.cachix.org"
            ];
            trusted-users = [ "root" ];
            system-features = defaultSystemFeatures;
          };
          nixConf =
            (pkgs.formats.nixConf {
              inherit (config)
                checkAllErrors
                checkConfig
                extraOptions
                ;
              package = pkgs.lixPackageSets.lix_2_93.lix.out;
              inherit (pkgs.lixPackageSets.lix_2_93.lix) version;
            }).generate
              "nix.conf"
              config.settings;
        };
      }
    );
in
{
  options.nix-csi.nixNodeConfig = lib.mkOption {
    type = nixSubmodule;
  };
  options.nix-csi.nixCacheConfig = lib.mkOption {
    type = nixSubmodule;
  };

  config = lib.mkIf cfg.enable {
    nix-csi =
      let
        sharedSettings = {
          allowed-users = [ "*" ];
          trusted-users = [
            "root"
            "nix"
          ];
          experimental-features = [
            "nix-command"
            "flakes"
            "auto-allocate-uids"
          ];
          auto-allocate-uids = true;
          builders-use-substitutes = true;
          narinfo-cache-negative-ttl = 0;
          narinfo-cache-positive-ttl = 0;
          warn-dirty = false;
        };
      in
      {
        nixNodeConfig.settings = sharedSettings // { };
        nixCacheConfig.settings = sharedSettings // {
          max-jobs = lib.mkDefault 0;
        };
      };
    kubernetes.resources.${cfg.namespace} = {
      ConfigMap.nix-node.data = {
        "nix.conf" = builtins.readFile (cfg.nixNodeConfig.nixConf);
      };
      ConfigMap.nix-cache.data = {
        "nix.conf" = builtins.readFile (cfg.nixCacheConfig.nixConf);
      };
    };
  };
}
