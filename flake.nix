{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  outputs = { self, ... }@inputs: {
    packages.x86_64-linux = let
      system = "x86_64-linux";
      pkgs = import inputs.nixpkgs { inherit system; }; 
      lib = pkgs.lib;
      python = pkgs.python3.withPackages (p: with p; [
        kopf
        kubernetes-asyncio
        pyngrok
        pyzmq
        fastapi
        hypercorn
        self.packages.${pkgs.system}.certbuilder
      ]);
    in
    {
      knix-daemonset = pkgs.writeScriptBin "knix-daemonset" # python
      ''
        #! ${lib.getExe python}
        ${builtins.readFile ./knix-daemonset.py}
      '';
      knix-deployment = pkgs.writeScriptBin "knix-daemonset" # python
      ''
        #! ${lib.getExe python}
        ${builtins.readFile ./knix-deployment.py}
      '';
      kopf = pkgs.writeScriptBin "kopf" # fish
      ''
        #! ${lib.getExe pkgs.fish}
        set --export --prepend PATH ${pkgs.kubectl}/bin
        # ${python}/bin/kopf run --debug --verbose --all-namespaces ./kopferator.py
        ${python}/bin/kopf run --verbose --all-namespaces ./kopferator.py
      '';
      certbuilder = pkgs.python3Packages.callPackage ./certbuilder.nix {};
      repoenv = pkgs.buildEnv {
        name = "repoenv";
        paths = [
          python
        ];
      };
    };
    legacyPackages.x86_64-linux = import inputs.nixpkgs { system = "x86_64-linux"; };
  };
}
