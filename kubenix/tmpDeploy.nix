{ lib, config, ... }:
let
  readOnly = false;
in
{
  config = {
    kubernetes.resources.configMaps.nix-config = {
      metadata.namespace = config.namespace;
      data."nix.conf" = ''
        build-users-group = root
        auto-allocate-uids = true
        experimental-features = nix-command flakes auto-allocate-uids fetch-closure
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
              command = [
                # "/nix/var/result/bin/tini"
                # "/nix/var/result/bin/init"
                "/nix/var/result/init"
                "sleep"
                "infinity"
              ];
              image = "dramforever/scratch:latest";
              # command = [
              #   "tail"
              #   "-f"
              #   "/dev/null"
              # ];
              # image = "ubuntu:latest";
              env = [
                {
                  name = "PATH";
                  value = "/nix/var/result/bin";
                }
              ];
              volumeMounts = [
                # {
                #   name = "nix-config";
                #   mountPath = "/etc/nix";
                #   inherit readOnly;
                # }
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
                  # volumeAttributes.expr = builtins.readFile ../containerMount.nix;
                  volumeAttributes.expr = builtins.readFile ../nixNG.nix;
                };
              }
            ];
          };
        };
      };
    };
  };
}
