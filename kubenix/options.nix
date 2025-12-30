{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nix-csi;
  inputs =
    (
      let
        lockFile = builtins.readFile ../flake.lock;
        lockAttrs = builtins.fromJSON lockFile;
        fcLockInfo = lockAttrs.nodes.flake-compatish.locked;
        fcSrc = builtins.fetchTree fcLockInfo;
        flake-compatish = import fcSrc;
      in
      flake-compatish ../.
    ).inputs;

  keyDrv =
    pkgs.runCommand "nix-csi-ssh-keys"
      {
        nativeBuildInputs = [ pkgs.openssh ];
      }
      ''
        mkdir -p $out
        ssh-keygen -t ed25519 -N "" -f $out/id_ed25519 -C "nix-csi-fallback-insecure"
      '';
in
{
  options.nix-csi = {
    enable = lib.mkEnableOption "nix-csi";
    undeploy = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    namespace = lib.mkOption {
      description = "Which namespace to deploy cknix resources too";
      type = lib.types.str;
      default = "nix-csi";
    };
    authorizedKeys = lib.mkOption {
      description = "SSH public keys that can connect to cache and builders";
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    pubKey = lib.mkOption {
      description = "Public SSH key used for in-cluster SSH communication";
      type = lib.types.str;
      default = builtins.readFile "${keyDrv}/id_ed25519.pub";
    };
    privKey = lib.mkOption {
      description = "Private SSH key used for in-cluster SSH communication";
      type = lib.types.str;
      default = builtins.readFile "${keyDrv}/id_ed25519";
    };
    version = lib.mkOption {
      type = lib.types.str;
      default =
        let
          pyproject = builtins.fromTOML (builtins.readFile ../python/pyproject.toml);
        in
        pyproject.project.version;
    };
    hostMountPath = lib.mkOption {
      description = "Where on the host to put cknix store";
      type = lib.types.path;
      default = "/var/lib/nix-csi";
    };
    internalServiceName = lib.mkOption {
      description = ''
        Internal service name used for reaching builder nodes from cache node
      '';
      type = lib.types.str;
      default = "nix-builders";
    };

    cachePackage = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      internal = true;
    };
    nodePackage = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      internal = true;
    };
    pkgs = lib.mkOption {
      type = lib.types.path;
      default = inputs.nixpkgs;
      internal = true;
    };
    push = lib.mkOption {
      type = lib.types.bool;
      internal = true;
      default = false;
    };
    dinix = lib.mkOption {
      type = lib.types.path;
      internal = true;
      default = inputs.dinix;
    };
  };
  config =
    let
      x86 = "x86_64-linux";
      arm = "aarch64-linux";

      x86Pkgs = import cfg.pkgs {
        system = x86;
        overlays = [ (import ../pkgs) ];
      };
      armPkgs = import cfg.pkgs {
        system = arm;
        overlays = [ (import ../pkgs) ];
      };
      cachePackage = {
        ${x86} = import ../environments/cache {
          pkgs = x86Pkgs;
          inherit (cfg) dinix;
        };
        ${arm} = import ../environments/cache {
          pkgs = armPkgs;
          inherit (cfg) dinix;
        };
      };
      nodePackage = {
        ${x86} = import ../environments/node {
          pkgs = x86Pkgs;
          inherit (cfg) dinix;
        };
        ${arm} = import ../environments/node {
          pkgs = armPkgs;
          inherit (cfg) dinix;
        };
      };
    in
    lib.mkIf cfg.enable {
      nix-csi.cachePackage = cachePackage;
      nix-csi.nodePackage = nodePackage;
      nix-csi.authorizedKeys = [ cfg.pubKey ];
    };
}
