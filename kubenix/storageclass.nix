{ ... }:
{
  config.kubernetes.resources.none.StorageClass.nix-csi = {
    provisioner = "nix.csi.store";
    reclaimPolicy = "Delete";
    volumeBindingMode = "WaitForFirstConsumer";
    allowVolumeExpansion = false;
  };
}
