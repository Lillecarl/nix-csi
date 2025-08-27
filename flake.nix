{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix2container = {
      url = "github:nlewo/nix2container";
      # url = "path:/home/lillecarl/Code/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    kubenix = {
      url = "github:hall/kubenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    inputs:
    inputs.flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [ ];
        };
        lib = pkgs.lib;

        kopf = pkgs.python3Packages.kopf.overrideAttrs (prev: {
          propagatedBuildInputs = (prev.propagatedBuildInputs or [ ]) ++ [ certbuilder ];
          doCheck = false;
          doInstallCheck = false;
        });
        certbuilder = pkgs.python3Packages.callPackage ./nix/pkgs/certbuilder.nix { };
        aiofile = pkgs.python3Packages.aiofile.overrideAttrs (pattrs: rec {
          version = "3.8.8";
          src = pkgs.fetchPypi {
            pname = "aiofile";
            version = version;
            hash = "sha256-QfPcQL1zBFnVhhBHboLl77L4Subp+giKlUU4XYOLikM=";
          };
          doCheck = false;
          doInstallCheck = false;
        });
        aiopath = pkgs.python3Packages.callPackage ./nix/pkgs/aiopath.nix { inherit aiofile; };
        csi-proto-python = pkgs.python3Packages.callPackage ./nix/pkgs/csi-proto-python/default.nix { };
        asyncache = pkgs.python3Packages.callPackage ./nix/pkgs/asyncache.nix { };
        python-jsonpath = pkgs.python3Packages.callPackage ./nix/pkgs/python-jsonpath.nix { };
        kr8s = pkgs.python3Packages.callPackage ./nix/pkgs/kr8s.nix { inherit asyncache python-jsonpath; };
        containerimage = import ./nix/pkgs/containerimage.nix {
          inherit pkgs;
        };
        nix2containerLib = inputs.nix2container.packages.${pkgs.system}.nix2container;

        nix2containerImage = nix2containerLib.buildImage {
          name = "cknix-dev";
          config = {
            # Should be some supervisor
            entrypoint = [ "${lib.getExe pkgs.bash}" ];
          };
          # Packages "extracted" from their storepaths
          copyToRoot = [
            pkgs.bash
          ];
          # Useful for running Nix in the container
          initializeNixDatabase = true;
          maxLayers = 50;
          layers = [
            (nix2containerLib.buildLayer {
              copyToRoot = [
                (pkgs.runCommand "folders" { } ''
                  mkdir -p $out/tmp
                  mkdir -p $out/var/log
                  mkdir -p $out/var/lib/attic
                  mkdir -p $out/etc
                  mkdir -p $out/run
                  mkdir -p $out/home/nix
                '')
                pkgs.dockerTools.binSh
                pkgs.dockerTools.caCertificates
                ((import ./nix/dockerUtils.nix pkgs).nonRootShadowSetup {
                  users = [
                    {
                      name = "root";
                      id = 0;
                    }
                    {
                      name = "nix";
                      id = 1000;
                    }
                    {
                      name = "nixbld";
                      id = 1001;
                    }
                  ];
                  shell = pkgs.lib.getExe pkgs.fish;
                })
              ];
              deps = [
                pkgs.fish
                pkgs.bash
                pkgs.ripgrep
                pkgs.fd
              ];
            })
          ];
        };
        cknix-csi = pkgs.python3Packages.callPackage ./nix/pkgs/cknix-csi.nix {
          inherit kopf csi-proto-python aiopath;
        };
        shell-operator = pkgs.callPackage ./nix/pkgs/shell-operator.nix { };

        ourPython = pkgs.python3.withPackages (
          p: with p; [
            cknix-csi
            grpclib
            kopf
            csi-proto-python
            aiopath
            aiosqlite
            plumbum
            kr8s
          ]
        );

        kubenixEval = (
          inputs.kubenix.evalModules.${system} {
            module =
              { kubenix, ... }:
              {
                imports = [
                  ./kubenix
                ];
              };
          }
        );
      in
      {
        packages = rec {
          inherit
            certbuilder
            containerimage
            nix2containerImage
            csi-proto-python
            asyncache
            kr8s
            cknix-csi
            shell-operator
            ;
          repoenv = pkgs.buildEnv {
            name = "repoenv";
            paths = [
              ourPython
              pkgs.skopeo
              pkgs.uv
            ];
          };
          createstore = pkgs.writeScriptBin "cknix-local" ''
            #! ${lib.getExe pkgs.bash}
            export PATH=${repoenv}/bin:$PATH
            ./createstore.py
          '';
          cknix-local = pkgs.writeScriptBin "cknix-local" ''
            #!${pkgs.bash}/bin/bash

            # cknix-local - Run shell-operator with cknix hooks

            export SHELL_OPERATOR_HOOKS_DIR="$PWD/shell-operator/hooks"
            export LOG_LEVEL="info"

            # Create temporary directory for debug socket to avoid permission errors
            DEBUG_SOCKET_DIR="$(${pkgs.coreutils}/bin/mktemp -d)"
            DEBUG_SOCKET="$DEBUG_SOCKET_DIR/shell-operator-debug.sock"

            if [ ! -d "$SHELL_OPERATOR_HOOKS_DIR" ]; then
              echo "Error: hooks directory not found at $SHELL_OPERATOR_HOOKS_DIR"
              echo "Please run from the cknix project root directory"
              exit 1
            fi

            echo "Starting cknix shell-operator..."
            echo "Hooks directory: $SHELL_OPERATOR_HOOKS_DIR"
            echo "Log level: $LOG_LEVEL"
            echo "Debug socket: $DEBUG_SOCKET"

            exec ${shell-operator}/bin/shell-operator start --debug-unix-socket="$DEBUG_SOCKET" "$@"
          '';
          supervisord = pkgs.python3Packages.supervisor // {
            meta = pkgs.python3Packages.supervisor // {
              mainProgram = "supervisord";
            };
          };
          supervisorctl = pkgs.python3Packages.supervisor // {
            meta = pkgs.python3Packages.supervisor // {
              mainProgram = "supervisorctl";
            };
          };

          # Kubenix-generated manifests
          cknix-manifests = kubenixEval.config.kubernetes.resultYAML;
          cknix-manifests-json = pkgs.writeTextFile {
            name = "cknix-manifests.json";
            text = builtins.toJSON kubenixEval.config.kubernetes.result;
          };
        };
        legacyPackages = pkgs;
      }
    );
}
