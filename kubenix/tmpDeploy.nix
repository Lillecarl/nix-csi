{ lib, config, ... }:
{
  config = {
    kubernetes.customResourceAttrs = {
      cknixHelloExpression = lib.mkIf false {
        apiVersion = "cknix.cool/v1";
        kind = "Expression";
        metadata = {
          name = "hello";
          namespace = config.cknixNamespace;
        };
        data = {
          expr = "(import /cknix/default.nix).legacyPackages.x86_64-linux.hello";
        };
      };
    };
    kubernetes.resources.persistentVolumes.cknixtest = lib.mkIf false {
      metadata.namespace = config.cknixNamespace;
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
    kubernetes.resources.configMaps.nix-config = {
      metadata.namespace = config.cknixNamespace;
      data."nix.conf" = ''
        build-users-group = root
        auto-allocate-uids = true
        experimental-features = nix-command flakes auto-allocate-uids
      '';
    };
    kubernetes.resources.pods.testpod = {
      metadata = {
        namespace = config.cknixNamespace;
        annotations."cknix-expr" = "hello";
      };
      spec = {
        containers.this = {
          command = [
            "/nix/var/result/bin/tini"
            "/nix/var/result/bin/init"
          ];
          # image = "gcr.io/distroless/static:latest";
          image = "dramforever/scratch:latest";
          # securityContext.privileged = true;
          env = [
            {
              name = "PATH";
              value = "/nix/var/result/bin";
            }
            {
              name = "container";
              value = "1";
            }
          ];
          volumeMounts = [
            {
              name = "nix-config";
              mountPath = "/etc/nix";
              readOnly = true;
            }
            {
              name = "cknix-volume";
              mountPath = "/nix";
              readOnly = false;
            }
          ];
        };
        hostNetwork = true;
        volumes = [
          {
            name = "nix-config";
            configMap.name = "nix-config";
          }
          {
            name = "cknix-volume";
            csi = {
              driver = "cknix.csi.store";
              volumeAttributes.expr = builtins.readFile ../containerMount.nix;
            };
          }
        ];
      };
    };
  };
}
