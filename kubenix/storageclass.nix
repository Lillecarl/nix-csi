{ ... }:
{
  config = {
    kubernetes.api.resources.storageClasses."nix-csi" = {
      provisioner = "nix.csi.store";
      reclaimPolicy = "Delete";
      volumeBindingMode = "WaitForFirstConsumer";
      allowVolumeExpansion = false;
    };
  };
}
