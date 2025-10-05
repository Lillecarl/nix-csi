{
  pkgs,
  dinix,
  nix-csi,
}:
let
  lib = pkgs.lib;
in
import dinix {
  inherit pkgs;
  modules = [
    {
      config = {
        services.boot.depends-on = [ "nix-csi" ];
        services.nix-csi = {
          command = lib.getExe nix-csi;
          options = [ "shares-console" ];
          depends-on = [ "runtimedirs" ];
        };
        services.runtimedirs = {
          type = "scripted";
          command = lib.getExe (
            pkgs.writeScriptBin "setupScript" # fish
              ''
                #! ${lib.getExe pkgs.fish}
                mkdir -p /nix/var/nix-csi/home
                mkdir -p /var/{log,lib,cache}
                mkdir -p /etc
                mkdir -p /run
                mkdir -p /tmp
                mkdir -p /root
              ''
          );
        };
      };
    }
  ];
}
