{
  pkgs ? import <nixpkgs> { },
  nix-csi,
}:
let
  dinixSrc = builtins.fetchTree {
    type = "git";
    url = "https://github.com/Lillecarl/dinix.git";
  };
  lib = pkgs.lib;
in
import dinixSrc {
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
