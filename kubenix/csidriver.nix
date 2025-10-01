{ ... }:
{
  config = {
    kubernetes.api.resources.cSIDrivers."nix.csi.store" = {
      spec = {
        attachRequired = false;
        podInfoOnMount = false;
        volumeLifecycleModes = [ "Ephemeral" ];
        fsGroupPolicy = "File";
        requiresRepublish = false;
        storageCapacity = false;
      };
    };
  };
}
