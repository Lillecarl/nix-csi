{ lib, config, ... }:
let
  readOnly = true;
in
{
  config = {
    kubernetes.customResourceAttrs = {
      nixCsiHelloExpression = lib.mkIf false {
        apiVersion = "nix.csi/v1";
        kind = "Expression";
        metadata = {
          name = "hello";
          namespace = config.namespace;
        };
        data = {
          expr = "(import /nix-csi/default.nix).legacyPackages.x86_64-linux.hello";
        };
      };
    };
    kubernetes.resources.persistentVolumes.nixcsitest = lib.mkIf false {
      metadata.namespace = config.namespace;
      spec = {
        accessModes = [ "ReadWriteMany" ];
        capacity.storage = "1M";
        csi = {
          driver = "nix.csi.store";
          volumeAttributes = { };
          volumeHandle = "nix-csi-test";
        };
        persistentVolumeReclaimPolicy = "Delete";
        storageClassName = "nix-csi";
        volumeMode = "Filesystem";
      };
    };
    kubernetes.resources.configMaps.nix-config = {
      metadata.namespace = config.namespace;
      data."nix.conf" = ''
        build-users-group = root
        auto-allocate-uids = true
        experimental-features = nix-command flakes auto-allocate-uids fetch-tree
      '';
    };
    kubernetes.resources.daemonSets.testd = {
      metadata = {
        namespace = config.namespace;
        annotations."nix-csi-expr" = "hello";
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
                  name = "nix-volume";
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
                name = "nix-volume";
                csi = {
                  driver = "nix.csi.store";
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
