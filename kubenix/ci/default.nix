{
  config,
  pkgs,
  lib,
  mkNCSI,
  inputs,
  ...
}:
let
  cfg = config.nix-csi;
  system = pkgs.stdenv.hostPlatform.system;

  containers = lib.mkNamedList {
    hello = {
      image = "ghcr.io/lillecarl/nix-csi/scratch:1.0.1";
      command = [ "hello" ];
      volumeMounts = lib.mkNamedList {
        nix-csi = {
          mountPath = "/nix";
          subPath = "nix";
        };
      };
    };
  };
in
{
  config = {
    nix-csi.loggingConfig = {
      version = 1;
      formatters = {
        standard = {
          format = "%(levelname)s [%(name)s] %(message)s";
        };
      };
      handlers = {
        console = {
          class = "logging.StreamHandler";
          formatter = "standard";
          stream = "ext://sys.stdout";
        };
      };
      loggers = {
        nix-csi = {
          level = "DEBUG";
          handlers = [ "console" ];
          propagate = false;
        };
        httpx = {
          level = "WARNING";
          handlers = [ "console" ];
          propagate = false;
        };
      };
      root = {
        level = "INFO";
        handlers = [ "console" ];
      };
    };
    kubernetes.resources.${cfg.namespace} = {
      ConfigMap.inputs.data = inputs;
      Job.flake-hello = mkNCSI {
        spec = {
          template = {
            spec = {
              restartPolicy = "Never";
              inherit containers;
              volumes = lib.mkNamedList {
                nix-csi.csi = {
                  driver = "nix.csi.store";
                  volumeAttributes.flakeRef = "github:nixos/nixpkgs/nixos-unstable#hello";
                };
              };
            };
          };
        };
      };
      Job.expr-hello = mkNCSI {
        spec = {
          template = {
            spec = {
              restartPolicy = "Never";
              inherit containers;
              volumes = lib.mkNamedList {
                nix-csi.csi = {
                  driver = "nix.csi.store";
                  readOnly = true;
                  volumeAttributes.nixExpr = # nix
                    ''
                      let
                        nixpkgs = builtins.fetchTree {
                          type = "github";
                          owner = "nixos";
                          repo = "nixpkgs";
                          ref = "nixos-unstable";
                        };
                        pkgs = import nixpkgs { };
                      in
                      pkgs.hello
                    '';
                };
              };
            };
          };
        };
      };
      Job.path-hello = mkNCSI {
        spec = {
          template = {
            spec = {
              restartPolicy = "Never";
              inherit containers;
              volumes = lib.mkNamedList {
                nix-csi.csi = {
                  driver = "nix.csi.store";
                  readOnly = true;
                  volumeAttributes.${system} = pkgs.hello;
                };
              };
            };
          };
        };
      };
    };
  };
}
