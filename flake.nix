{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;
        python = pkgs.python3.withPackages (
          p: with p; [
            kopf
            kubernetes-asyncio
            pyngrok
            pyzmq
            fastapi
            hypercorn
            grpcio-tools
            self.packages.${pkgs.system}.certbuilder
            self.packages.${pkgs.system}.csi-proto-python
          ]
        );
      in
      {
        packages = {
          knix-daemonset =
            pkgs.writeScriptBin "knix-daemonset" # python
              ''
                #! ${lib.getExe python}
                ${builtins.readFile ./python/knix-daemonset.py}
              '';
          knix-deployment =
            pkgs.writeScriptBin "knix-daemonset" # python
              ''
                #! ${lib.getExe python}
                ${builtins.readFile ./python/knix-deployment.py}
              '';
          kopf =
            pkgs.writeScriptBin "kopf" # fish
              ''
                #! ${lib.getExe pkgs.fish}
                set --export --prepend PATH ${pkgs.kubectl}/bin
                # ${python}/bin/kopf run --debug --verbose --all-namespaces ./kopferator.py
                ${python}/bin/kopf run --verbose --all-namespaces ./kopferator.py
              '';
          certbuilder = pkgs.python3Packages.callPackage ./nix/pkgs/certbuilder.nix { };
          csi-proto-python = pkgs.python3Packages.callPackage ./nix/pkgs/csi-proto-python.nix { };
          repoenv = pkgs.buildEnv {
            name = "repoenv";
            paths = [
              python
              pkgs.protobuf
              pkgs.skopeo
            ];
          };
          containerimage = pkgs.callPackage ./nix/pkgs/containerimage.nix { };
        };
        legacyPackages = import nixpkgs { inherit system; };
      }
    );
}
