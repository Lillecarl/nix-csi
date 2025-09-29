{ config, lib, ... }:
{
  options = {
    nix-csi.image = lib.mkOption {
      type = lib.types.str;
      default = "nix-csi:latest";
    };
  };
  config = {
    kubernetes.resources.configMaps.nixos-unstable = {
      metadata.namespace = config.cknixNamespace;
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
    kubernetes.api.resources.daemonSets."cknix-csi-node" = {
      metadata.namespace = config.cknixNamespace;
      spec = {
        selector.matchLabels.app = "cknix-csi-node";
        template = {
          metadata.labels.app = "cknix-csi-node";
          spec = {
            serviceAccountName = "cknix";
            hostNetwork = true;
            initContainers = [
              {
                name = "init";
                command = [
                  # "rsync"
                  # "--archive"
                  # "/nix"
                  # "/nix2"
                  "fish"
                  "-c"
                  "echo asdf && sleep 5 && cp --verbose --archive --update=none /nix/* /nix2/"
                ];
                image = "rg.nl-ams.scw.cloud/lillecarl/knix:latest";
                volumeMounts = [
                  {
                    mountPath = "/nix2";
                    name = "cknix-store";
                  }
                ];
                imagePullPolicy = "Always";
              }
            ];
            containers = [
              {
                name = "cknix-csi-node";
                image = "rg.nl-ams.scw.cloud/lillecarl/knix:latest";
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
                    name = "cknix-store";
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
                    name = "cknixdev";
                    mountPath = "/cknix";
                  }
                ];
              }
              {
                name = "cknix-csi-registrar";
                image = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.10.0";
                args = [
                  "--v=5"
                  "--csi-address=/csi/csi.sock"
                  "--kubelet-registration-path=/var/lib/kubelet/plugins/cknix.csi.nixstore/csi.sock"
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
                name = "cknix-csi-liveness";
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
                name = "cknix-store";
                hostPath = {
                  path = config.hostMountPath;
                  type = "DirectoryOrCreate";
                };
              }
              {
                name = "socket-dir";
                hostPath = {
                  path = "/var/lib/kubelet/plugins/cknix.csi.nixstore/";
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
                name = "cknixdev";
                hostPath = {
                  path = "/home/lillecarl/Code/cknix";
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
