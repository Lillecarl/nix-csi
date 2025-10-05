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
          command = "${lib.getExe nix-csi} --loglevel DEBUG";
          options = [ "shares-console" ];
          depends-on = [ "setup" ];
        };
        # set up root filesystem with paths required for a Linux system to function normally
        services.setup = {
          type = "scripted";
          options = [ "shares-console" ];
          command = lib.getExe (
            pkgs.writeScriptBin "setup" # execline
              ''
                #! ${lib.getExe' pkgs.execline "execlineb"}
                importas -S HOME
                foreground { mkdir --parents /tmp }
                foreground { mkdir --parents ''${HOME} }
                foreground { rsync --verbose --archive ${pkgs.dockerTools.fakeNss}/ / }
                foreground { rsync --verbose --archive ${pkgs.dockerTools.caCertificates}/ / }
              ''
          );
        };
      };
    }
  ];
}
