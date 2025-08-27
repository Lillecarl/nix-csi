{ ... }:
{
  config = {
    kubernetes.api.resources.cSIDrivers."cknix.csi.store" = {
      spec = {
        attachRequired = false;
        podInfoOnMount = true;
        volumeLifecycleModes = [
          "Persistent"
          "Ephemeral"
        ];
        fsGroupPolicy = "File";
        requiresRepublish = false;
        storageCapacity = false;
      };
    };
  };
}
