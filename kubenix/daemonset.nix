{ config, lib, ... }:
{
  config = {
    kubernetes.resources.configMaps.nixos-unstable = {
      metadata.namespace = config.namespace;
      data."default.nix" = # nix
        ''
          import (builtins.fetchTree {
            type = "github";
            repo = "nixpkgs";
            owner = "NixOS";
            ref = "nixos-unstable";
          }).outPath
        '';
    };
    kubernetes.api.resources.daemonSets."nix-csi-node" = {
      metadata.namespace = config.namespace;
      spec = {
        selector.matchLabels.app = "nix-csi-node";
        template = {
          metadata.labels.app = "nix-csi-node";
          spec = {
            serviceAccountName = "nix-csi";
            hostNetwork = true;
            initContainers = [
              {
                name = "init";
                command = [
                  "rsync"
                  "--verbose"
                  "--archive"
                  "/nix/."
                  "/nix2/"
                ];
                image = config.image;
                volumeMounts = [
                  {
                    mountPath = "/nix2";
                    name = "nix-store";
                  }
                ];
                imagePullPolicy = "IfNotPresent";
              }
            ];
            containers = [
              {
                name = "nix-csi-node";
                image = config.image;
                command = [
                  "sleep"
                  "infinity"
                ];
                securityContext.privileged = true;
                env = [
                  {
                    name = "CSI_ENDPOINT";
                    value = "unix:///csi/csi.sock";
                  }
                  {
                    name = "KUBE_NODE_NAME";
                    valueFrom.fieldRef.fieldPath = "spec.nodeName";
                  }
                  {
                    name = "NIX_PATH";
                    value = "nixos-unstable=/etc/nixpaths/nixos-unstable";
                  }
                ];
                volumeMounts = [
                  {
                    name = "socket-dir";
                    mountPath = "/csi";
                  }
                  {
                    name = "kubelet-dir";
                    mountPath = "/var/lib/kubelet";
                    mountPropagation = "Bidirectional";
                  }
                  {
                    name = "nix-store";
                    mountPath = "/nix";
                    # mountPropagation = "HostToContainer";
                    mountPropagation = "Bidirectional";
                  }
                  {
                    name = "registration-dir";
                    mountPath = "/registration";
                  }
                  {
                    name = "nixos-unstable";
                    mountPath = "/etc/nixpaths/nixos-unstable";
                    readOnly = true;
                  }
                  {
                    name = "nixdev";
                    mountPath = "/nixdev";
                  }
                ];
              }
              {
                name = "nix-csi-registrar";
                image = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.10.0";
                args = [
                  "--v=5"
                  "--csi-address=/csi/csi.sock"
                  "--kubelet-registration-path=/var/lib/kubelet/plugins/nix.csi.store/csi.sock"
                ];
                env = [
                  {
                    name = "KUBE_NODE_NAME";
                    valueFrom.fieldRef.fieldPath = "spec.nodeName";
                  }
                ];
                volumeMounts = [
                  {
                    name = "socket-dir";
                    mountPath = "/csi";
                  }
                  {
                    name = "kubelet-dir";
                    mountPath = "/var/lib/kubelet";
                  }
                  {
                    name = "registration-dir";
                    mountPath = "/registration";
                  }
                ];
              }
              {
                name = "nix-csi-liveness";
                image = "registry.k8s.io/sig-storage/livenessprobe:v2.12.0";
                args = [
                  "--csi-address=/csi/csi.sock"
                  "--v=5"
                ];
                volumeMounts = [
                  {
                    name = "socket-dir";
                    mountPath = "/csi";
                  }
                  {
                    name = "registration-dir";
                    mountPath = "/registration";
                  }
                ];
              }
            ];
            volumes = [
              {
                name = "nix-store";
                hostPath = {
                  path = config.hostMountPath;
                  type = "DirectoryOrCreate";
                };
              }
              {
                name = "socket-dir";
                hostPath = {
                  path = "/var/lib/kubelet/plugins/nix.csi.store/";
                  type = "DirectoryOrCreate";
                };
              }
              {
                name = "kubelet-dir";
                hostPath = {
                  path = "/var/lib/kubelet";
                  type = "Directory";
                };
              }
              {
                name = "registration-dir";
                hostPath.path = "/var/lib/kubelet/plugins_registry";
              }
              {
                name = "nixos-unstable";
                configMap.name = "nixos-unstable";
              }
              {
                name = "nixdev";
                hostPath = {
                  path = "/home/lillecarl/Code/nix-csi";
                  type = "Directory";
                };
              }
            ];
          };
        };
      };
    };
  };
}
