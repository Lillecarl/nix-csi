{ lib, ... }:
let
  nsVar = builtins.getEnv "CSINS";
  nsFromEnv = if builtins.stringLength nsVar > 0 then nsVar else "default";
in
{
  options = {
    namespace = lib.mkOption {
      description = "Which namespace to deploy cknix resources too";
      type = lib.types.str;
      default = nsFromEnv;
    };
    dsImage = lib.mkOption {
      type = lib.types.str;
      default = "nix-csi-ds:latest";
    };
    ssImage = lib.mkOption {
      type = lib.types.str;
      default = "nix-csi-ss:latest";
    };
    hostMountPath = lib.mkOption {
      description = "Where on the host to put cknix store";
      type = lib.types.path;
      default = "/var/lib/nix-csi/nix";
    };
  };
}
