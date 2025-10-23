{ lib, ... }:
{
  options.nix-csi = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    undeploy = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    namespace = lib.mkOption {
      description = "Which namespace to deploy cknix resources too";
      type = lib.types.str;
      default = "default";
    };
    image = lib.mkOption {
      type = lib.types.str;
      default =
        let
          pyproject = builtins.fromTOML (builtins.readFile ../python/pyproject.toml);
          version = pyproject.project.version;
          image = "quay.io/nix-csi/nix-csi:${version}";
        in
        image;
    };
    hostMountPath = lib.mkOption {
      description = "Where on the host to put cknix store";
      type = lib.types.path;
      default = "/var/lib/nix-csi/nix";
    };
  };
}
