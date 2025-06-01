{
  nglib,
  nixpkgs,
  pkgs,
  ...
}:
let
  ourPkgs = pkgs;
in
nglib.makeSystem {
  inherit nixpkgs;
  inherit (pkgs) system;
  name = "nixng-nix";

  config = (
    { pkgs, ... }:
    {
      nixpkgs.pkgs = ourPkgs;
      dumb-init = {
        enable = true;
        type.shell = { };
      };
      nix = {
        enable = true;
        package = pkgs.lix;
        config = {
          experimental-features = [
            "nix-command"
            "flakes"
          ];
          sandbox = false;
        };
      };
      environment.systemPackages = with pkgs; [
        coreutils
        fish
      ];
    }
  );
}
