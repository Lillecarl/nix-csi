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
  };
  outputs =
    {
      nixpkgs,
      flake-utils,
      nixng,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
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
        csi-proto-python = pkgs.python3Packages.callPackage ./nix/pkgs/csi-proto-python/default.nix { };
        containerimage = import ./nix/pkgs/containerimage.nix {
          inherit pkgs;
        };
        knix-ng = (
          import ./nix/pkgs/nixng.nix {
            inherit (nixng) nglib;
            inherit nixpkgs;
            inherit pkgs;
          }
        );
        knix-csi = pkgs.python3Packages.callPackage ./nix/pkgs/knix-csi.nix {
          inherit kopf csi-proto-python;
        };

        ourPython = pkgs.python3.withPackages (
          p: with p; [
            knix-csi
            grpclib
            kopf
            csi-proto-python
          ]
        );
      in
      {
        packages = {
          inherit
            certbuilder
            containerimage
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
            meta =  pkgs.python3Packages.supervisor // {
              mainProgram = "supervisord";
            };
          };
          supervisorctl = pkgs.python3Packages.supervisor // {
            meta =  pkgs.python3Packages.supervisor // {
              mainProgram = "supervisorctl";
            };
          };
        };
        legacyPackages = import nixpkgs { inherit system; };
      }
    );
}
