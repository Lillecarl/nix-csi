{ config, ... }:
{
  config.kubernetes.resources.none.CSIDriver."nix.csi.store" = {
    spec = {
      attachRequired = false;
      podInfoOnMount = false;
      volumeLifecycleModes = [ "Ephemeral" ];
      fsGroupPolicy = "File";
      requiresRepublish = false;
      storageCapacity = false;
    };
  };
}
