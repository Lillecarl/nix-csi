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
        services.setup = {
          type = "scripted";
          options = [ "shares-console" ];
          command = lib.getExe (
            pkgs.writeScriptBin "setup" # execline
              ''
                #! ${lib.getExe' pkgs.execline "execlineb"}
                foreground { mkdir --parents /tmp }
                foreground { mkdir --parents /nix/var/nix-csi/home }
                foreground { rsync --verbose --archive ${pkgs.dockerTools.fakeNss}/ / }
                foreground { rsync --verbose --archive ${pkgs.dockerTools.caCertificates}/ / }
              ''
          );
        };
      };
    }
  ];
}
