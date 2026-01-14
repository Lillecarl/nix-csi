{
  config,
  pkgs,
  lib,
  mkNCSI,
  subPath,
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
      Job.commandpath-hello = mkNCSI {
        spec = {
          template = {
            spec = {
              restartPolicy = "Never";
              containers = lib.recursiveUpdate containers {
                hello.command = [ (lib.getExe pkgs.hello) ];
              };
              volumes = lib.mkNamedList {
                nix-csi.csi = {
                  driver = "nix.csi.store";
                  readOnly = true;
                };
              };
            };
          };
        };
      };
      Job.env-ssl = mkNCSI {
        spec = {
          template = {
            spec = {
              restartPolicy = "Never";
              containers = lib.recursiveUpdate containers {
                hello = {
                  command = [
                    (lib.getExe (
                      pkgs.writeShellApplication {
                        name = "printer";
                        runtimeInputs = [
                          pkgs.coreutils
                          pkgs.hello
                        ];
                        text = # bash
                          ''
                            set -x
                            hello
                            ls -lah /etc/ssl/certs
                          '';
                      }
                    ))
                  ];
                  env = lib.mkNamedList {
                    SSL_CERT_FILE.value = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
                    SSL_CERT_DIR.value = "${pkgs.cacert}/etc/ssl/certs";
                  };
                  volumeMounts =
                    let
                      mkMount =
                        sPath:
                        let
                          extractSuffix =
                            sPath:
                            let
                              str = toString sPath;
                              matched = builtins.match "/nix/store/[0-9a-df-np-sv-z]{32}-[^/]+(.*)" str;
                            in
                            if matched == null then null else builtins.head matched;
                        in
                        {
                          name = "nix-csi";
                          mountPath = extractSuffix sPath;
                          subPath = subPath "${if lib.pathExists sPath then sPath else throw "path no good homes"}";
                          readOnly = true;
                        };
                      testEnv = pkgs.buildEnv {
                        name = "testenv";
                        paths = [
                          pkgs.dockerTools.fakeNss
                          pkgs.dockerTools.binSh
                        ];
                      };
                    in
                    lib.mkForce [
                      (mkMount "${testEnv}/etc")
                      {
                        name = "nix-csi";
                        mountPath = "/nix";
                        subPath = "nix";
                        readOnly = true;
                      }
                    ];
                };
              };
              volumes = lib.mkNamedList {
                nix-csi.csi = {
                  driver = "nix.csi.store";
                  readOnly = true;
                };
              };
            };
          };
        };
      };
    };
  };
}
