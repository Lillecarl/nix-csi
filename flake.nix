{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixng = {
      url = "github:nix-community/NixNG";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };
    nix2container = {
      # url = "github:nlewo/nix2container";
      url = "path:/home/lillecarl/Code/nix2container";
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
        knix-ng = (
          import ./nix/pkgs/nixng.nix {
            inherit (inputs.nixng) nglib;
            inherit (inputs) nixpkgs;
            inherit pkgs;
          }
        );
        knix-csi = pkgs.python3Packages.callPackage ./nix/pkgs/knix-csi.nix {
          inherit kopf csi-proto-python aiopath;
        };

        ourPython = pkgs.python3.withPackages (
          p: with p; [
            knix-csi
            grpclib
            kopf
            csi-proto-python
            aiopath
            aiosqlite
          ]
        );
      in
      {
        packages = {
          inherit
            certbuilder
            containerimage
            nix2containerImage
            csi-proto-python
            knix-ng
            ;
          repoenv = pkgs.buildEnv {
            name = "repoenv";
            paths = [
              ourPython
              pkgs.skopeo
            ];
          };
          knix-csi = knix-csi;
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
        };
        legacyPackages = pkgs;
      }
    );
}
