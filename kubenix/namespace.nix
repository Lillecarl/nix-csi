{ config, lib, ... }:
let
  cfg = config.nix-csi;
  namespace = cfg.namespace;
in
{
  config = lib.mkIf cfg.enable {
    kubernetes.resources.none = lib.mkIf (namespace != "default") {
      Namespace.${namespace} = { };
    };
  };
}
