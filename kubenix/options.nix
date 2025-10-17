{ lib, ... }:
{
  options.nix-csi = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    namespace = lib.mkOption {
      description = "Which namespace to deploy cknix resources too";
      type = lib.types.str;
      default = "default";
    };
    enableBinaryCache = lib.mkOption {
      description = "Enable deployment of a cluster-internal nix binary cache";
      type = lib.types.bool;
      default = true;
    };
    image = lib.mkOption {
      type = lib.types.str;
      default = "nix-csi-ds:latest";
    };
    hostMountPath = lib.mkOption {
      description = "Where on the host to put cknix store";
      type = lib.types.path;
      default = "/var/lib/nix-csi/nix";
    };
  };
}
