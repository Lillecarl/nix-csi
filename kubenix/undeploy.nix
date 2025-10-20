{ config, lib, ... }:
let
  cfg = config.nix-csi;
in
{
  config = lib.mkIf cfg.undeploy {
    assertions = [
      {
        assertion = !(cfg.enable && cfg.undeploy);
        message = "nix-csi.undeploy cannot be true when nix-csi.enable is also true.";
      }
      {
        assertion = !(cfg.undeploy && lib.hasPrefix "/nix" cfg.hostMountPath);
        message = "nix-csi.undeploy will not undeploy /nix based mount locations like ${cfg.hostMountPath}";
      }
    ];

    kubernetes.resources.${cfg.namespace}.DaemonSet.nix-csi-cleanup = {
      spec.selector.matchLabels.app = "nix-csi-cleanup";
      spec.template = {
        metadata.labels.app = "nix-csi-cleanup";
        spec = {
          containers = lib.mkNamedList {
            cleanup = {
              name = "cleanup";
              image = "busybox:latest";
              command = [
                "find"
                "/nix"
                "-mindepth"
                "1"
                "-delete"
              ];

              volumeMounts = lib.mkNamedList {
                nix-store.mountPath = "/nix";
              };
              securityContext.privileged = true;
            };
          };

          volumes = lib.mkNamedList {
            nix-store.hostPath.path = cfg.hostMountPath;
          };
        };
      };
    };
  };
}
