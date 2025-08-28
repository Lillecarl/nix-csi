{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
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

        initScript =
          let
          in
          pkgs.writeScriptBin "cknix-init" # execline
            ''
              #! ${lib.getExe' pkgs.execline "execlineb"}
              foreground { echo "Initializing..."}
            '';

        nix2containerImage = nix2containerLib.buildImage {
          name = "cknix-dev";
          config = {
            entrypoint = [
              (lib.getExe pkgs.tini)
              initScript
            ];
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
          inherit csi-proto-python;
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
        packages = {
          inherit
            certbuilder
            containerimage
            nix2containerImage
            csi-proto-python
            asyncache
            kr8s
            cknix-csi
            shell-operator
            kubenixEval
            ;
          repoenv = pkgs.buildEnv {
            name = "repoenv";
            paths = [
              ourPython
              pkgs.skopeo
              pkgs.uv
            ];
          };

          # Kubenix-generated manifests
          cknix-manifests = kubenixEval.config.kubernetes.resultYAML;
          cknix-manifests-json = kubenixEval.config.kubernetes.result;
        };
        legacyPackages = pkgs;
      }
    );
}
