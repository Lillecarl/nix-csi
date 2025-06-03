{ self, system, nixpkgs, pkgs, ... }:
nixpkgs.lib.nixosSystem {
  inherit system pkgs;
  modules = [
    ./default.nix
  ];
}
