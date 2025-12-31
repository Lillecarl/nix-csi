{
  config,
  pkgs,
  lib,
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
        nix-csi.mountPath = "/nix";
      };
    };
  };
in
{
  config = {
    kubernetes.resources.${cfg.namespace} = {
      Job.flake-hello = {
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
      Job.expr-hello = {
        spec = {
          template = {
            spec = {
              restartPolicy = "Never";
              inherit containers;
              volumes = lib.mkNamedList {
                nix-csi.csi = {
                  driver = "nix.csi.store";
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
      Job.path-hello = {
        spec = {
          template = {
            spec = {
              restartPolicy = "Never";
              inherit containers;
              volumes = lib.mkNamedList {
                nix-csi.csi = {
                  driver = "nix.csi.store";
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
