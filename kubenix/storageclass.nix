{ ... }:
{
  config = {
    kubernetes.api.resources.storageClasses."cknix-csi" = {
      provisioner = "cknix.csi.store";
      reclaimPolicy = "Delete";
      volumeBindingMode = "WaitForFirstConsumer";
      allowVolumeExpansion = false;
    };
  };
}
