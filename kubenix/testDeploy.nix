{ lib, config, ... }:
let
  readOnly = false;
in
{
  config = lib.mkIf (builtins.stringLength (builtins.getEnv "CSITEST") > 0) {
    kubernetes.resources.daemonSets.testd = {
      metadata.namespace = config.namespace;
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
                "/nix/var/result/bin/dinixinit"
              ];
              image = "dramforever/scratch@sha256:adf10351862ad5351ac2e714e04a0afb020b9df658ac99a07cbf49c0e18f8e43";
              # image = "ghcr.io/lillecarl/nix-csi/scratch:1.0.0";
              env = [
                {
                  name = "PATH";
                  value = "/nix/var/result/bin";
                }
              ];
              volumeMounts = [
                {
                  name = "nix-config";
                  mountPath = "/etc/nix";
                }
                {
                  name = "nix-volume";
                  mountPath = "/nix";
                  inherit readOnly;
                }
              ];
            };
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
                  volumeAttributes.expr = builtins.readFile ../guests/test.nix;
                  # volumeAttributes.expr = builtins.readFile ../guests/nixNG.nix;
                };
              }
            ];
          };
        };
      };
    };
  };
}
