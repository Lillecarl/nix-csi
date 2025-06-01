{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    nixng = {
      url = "github:nix-community/NixNG";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nixng,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;

        kopf = pkgs.python3Packages.kopf.overrideAttrs (prev: {
          propagatedBuildInputs = (prev.propagatedBuildInputs or [ ]) ++ [ certbuilder ];
          doCheck = false;
          doInstallCheck = false;
        });
        certbuilder = pkgs.python3Packages.callPackage ./nix/pkgs/certbuilder.nix { };
        csi-proto-python = pkgs.python3Packages.callPackage ./nix/pkgs/csi-proto-python/default.nix { };
        containerimage = pkgs.callPackage ./nix/pkgs/containerimage.nix { inherit knix-csi; };
        nixng = (
          import ./nix/pkgs/nixng.nix {
            inherit (nixng) nglib;
            inherit nixpkgs;
            inherit pkgs;
          }
        );
        knix-csi = pkgs.python3Packages.callPackage ./nix/pkgs/knix-csi.nix {
          inherit kopf csi-proto-python;
        };

        ourPython = pkgs.python3.withPackages (p: with p; [
          knix-csi
          grpclib
          kopf
          csi-proto-python
        ]);
      in
      {
        packages = {
          inherit certbuilder containerimage csi-proto-python;
          repoenv = pkgs.buildEnv {
            name = "repoenv";
            paths = [
              ourPython
              pkgs.skopeo
            ];
          };
          knix-csi = knix-csi;
        };
        legacyPackages = import nixpkgs { inherit system; };
      }
    );
}
