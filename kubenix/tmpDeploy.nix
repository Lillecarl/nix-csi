{ lib, config, ... }:
let
  readOnly = true;
in
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
    kubernetes.resources.daemonSets.testd = {
      metadata = {
        namespace = config.cknixNamespace;
        annotations."cknix-expr" = "hello";
      };
      spec = {
        updateStrategy = {
          type = "RollingUpdate";
          rollingUpdate.maxUnavailable = 1;
        };
        selector.matchLabels.app = "testd";
        template = {
          metadata.labels.app = "testd";
          spec = {
            containers.this = {
              # command = [
              #   "/nix/var/result/bin/tini"
              #   "/nix/var/result/bin/init"
              # ];
              # image = "dramforever/scratch:latest";
              command = [
                "tail"
                "-f"
                "/dev/null"
              ];
              image = "ubuntu:latest";
              env = [
                # {
                #   name = "PATH";
                #   value = "/nix/var/result/bin";
                # }
                {
                  name = "container";
                  value = "1";
                }
              ];
              volumeMounts = [
                {
                  name = "nix-config";
                  mountPath = "/etc/nix";
                  inherit readOnly;
                }
                {
                  name = "cknix-volume";
                  mountPath = "/nix";
                  inherit readOnly;
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
                  inherit readOnly;
                  volumeAttributes.expr = builtins.readFile ../containerMount.nix;
                };
              }
            ];
          };
        };
      };
    };
  };
}
