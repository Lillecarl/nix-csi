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
        ourPython = pkgs.python3.withPackages (
          p: with p; [
            kopf
            kubernetes-asyncio
            pyngrok
            pyzmq
            fastapi
            hypercorn
            grpclib
            self.packages.${pkgs.system}.certbuilder
            self.packages.${pkgs.system}.csi-proto-python
          ]
        );
      in
      {
        packages = {
          knix-csi =
            pkgs.writeScriptBin "knix-csi-node" # fish
              ''
                #! ${lib.getExe pkgs.fish}
                set --export --prepend PATH $(nix build --no-link --print-out-paths --file /knix spkgs.kubectl.outPath)/bin
                set --export --prepend PATH $(nix build --no-link --print-out-paths --file /knix spkgs.util-linux.outPath)/bin
                set --export --prepend PATH $(nix build --no-link --print-out-paths --file /knix spkgs.rsync.outPath)/bin
                echo $PATH
                exec ${lib.getExe self.packages.${pkgs.system}.knix-csi-py} $argv
              '';
          knix-csi-py =
            pkgs.writeScriptBin "knix-csi-node" # python
              ''
                #! ${lib.getExe ourPython}
                ${builtins.readFile ./python/csi.py}
              '';
          kopf =
            pkgs.writeScriptBin "kopf" # fish
              ''
                #! ${lib.getExe pkgs.fish}
                set --export --prepend PATH ${pkgs.kubectl}/bin
                # ${ourPython}/bin/kopf run --debug --verbose --all-namespaces ./kopferator.py
                ${ourPython}/bin/kopf run --verbose --all-namespaces ./kopferator.py
              '';
          certbuilder = pkgs.python3Packages.callPackage ./nix/pkgs/certbuilder.nix { };
          csi-proto-python = pkgs.python3Packages.callPackage ./nix/pkgs/csi-proto-python/default.nix { };
          repoenv = pkgs.buildEnv {
            name = "repoenv";
            paths = [
              ourPython
              pkgs.protobuf
              pkgs.skopeo
            ];
          };
          containerimage = pkgs.callPackage ./nix/pkgs/containerimage.nix { inherit ourPython; };
          nixng = (
            import ./nix/pkgs/nixng.nix {
              inherit (nixng) nglib;
              inherit nixpkgs;
              inherit pkgs;
            }
          );
        };
        legacyPackages = import nixpkgs { inherit system; };
      }
    );
}
