{ lib, ... }:
{
  config = {
    kubernetes.customResourceAttrs = {
      cknixHelloExpression = lib.mkIf false {
        apiVersion = "cknix.cool/v1";
        kind = "Expression";
        metadata = {
          name = "hello";
        };
        data = {
          expr = "(import /cknix/default.nix).legacyPackages.x86_64-linux.hello";
        };
      };
    };
    kubernetes.resources.persistentVolumes.cknixtest = lib.mkIf false {
      spec = {
        accessModes = [ "ReadWriteMany" ];
        capacity.storage = "1M";
        csi = {
          driver = "cknix.csi.store";
          volumeAttributes = { };
          volumeHandle = "cknixtest";
        };
        persistentVolumeReclaimPolicy = "Delete";
        storageClassName = "cknix-csi";
        volumeMode = "Filesystem";
      };
    };
    kubernetes.resources.pods.ubuntu1 = {
      metadata = {
        labels.run = "ubuntu";
        annotations."cknix-expr" = "hello";
      };
      spec = {
        containers.ubuntu = {
          command = [
            "sleep"
            "infinity"
          ];
          image = "ubuntu:22.04";
          volumeMounts = [
            {
              name = "cknix-volume";
              mountPath = "/nix";
              readOnly = true;
            }
          ];
        };
        hostNetwork = true;
        volumes = [
          {
            name = "cknix-volume";
            csi = {
              driver = "cknix.csi.store";
              volumeAttributes.expr = "(import /cknix/default.nix).spkgs.mtr.outPath";
            };
          }
        ];
      };
    };
  };
}
