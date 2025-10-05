{
  pkgs,
  dinix,
  nix-csi,
}:
let
  lib = pkgs.lib;
  fishMinimal = pkgs.fish.override { usePython = false; };
  nixUserGroupShadow =
    let
      shell = lib.getExe fishMinimal;
    in
    ((import ../dockerUtils.nix pkgs).nonRootShadowSetup {
      users = [
        {
          name = "root";
          id = 0;
          inherit shell;
        }
        {
          name = "nix";
          id = 1000;
          inherit shell;
        }
        {
          name = "nixbld";
          id = 1001;
          inherit shell;
        }
      ];
    });
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
                foreground { rsync --verbose --archive ${nixUserGroupShadow}/ / }
                foreground { rsync --verbose --archive ${pkgs.dockerTools.caCertificates}/ / }
              ''
          );
        };
      };
    }
  ];
}
