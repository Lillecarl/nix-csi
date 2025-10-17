{ config, lib, ... }:
let
  cfg = config.nix-csi;
in
{
  config = lib.mkIf cfg.enable {
    kubernetes.resources.none.StorageClass.nix-csi = {
      provisioner = "nix.csi.store";
      reclaimPolicy = "Delete";
      volumeBindingMode = "WaitForFirstConsumer";
      allowVolumeExpansion = false;
    };
  };
}
