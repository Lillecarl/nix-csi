{ config, lib, ... }:
let
  cfg = config.nix-csi;
in
{
  config = lib.mkIf cfg.enable {
    kubernetes.resources.${cfg.namespace} = {
      # mounts to /nix/var/nix-csi/home/.ssh
      Secret.sshc = lib.mkIf cfg.enableBinaryCache {
        stringData = {
          known_hosts = "nix-cache.${cfg.namespace}.svc ${builtins.readFile ../id_ed25519.pub}";
          id_ed25519 = builtins.readFile ../id_ed25519;
          config = # ssh
            ''
              Host nix-cache
                  HostName nix-cache.${cfg.namespace}.svc
                  User root
                  Port 22
                  IdentityFile ~/.ssh/id_ed25519
                  UserKnownHostsFile ~/.ssh/known_hosts
            '';
        };
      };

      DaemonSet.nix-csi-node = {
        spec = {
          updateStrategy = {
            type = "RollingUpdate";
            rollingUpdate.maxUnavailable = 1;
          };
          selector.matchLabels.app = "nix-csi-node";
          template = {
            metadata.labels.app = "nix-csi-node";
            metadata.annotations."kubectl.kubernetes.io/default-container" = "nix-csi-node";
            spec = {
              initContainers = [
                {
                  name = "populate-nix";
                  image = cfg.image;
                  volumeMounts = [
                    {
                      mountPath = "/nix-volume";
                      name = "nix-store";
                    }
                  ];
                  imagePullPolicy = "IfNotPresent";
                }
              ];
              containers = [
                {
                  name = "nix-csi-node";
                  image = "quay.io/nix-csi/scratch:1.0.0";
                  securityContext.privileged = true;
                  command = [ "dinixLauncher" ];
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
                      name = "PATH";
                      value = "/nix/var/result/bin";
                    }
                    {
                      name = "HOME";
                      value = "/nix/var/nix-csi/home";
                    }
                    {
                      name = "USER";
                      value = "root";
                    }
                    {
                      name = "BUILD_CACHE";
                      value = lib.boolToString cfg.enableBinaryCache;
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
                      mountPropagation = "Bidirectional";
                    }
                    {
                      name = "registration-dir";
                      mountPath = "/registration";
                    }
                    {
                      name = "nix-config";
                      mountPath = "/etc/nix";
                    }
                  ]
                  ++ lib.optional cfg.enableBinaryCache {
                    name = "sshc";
                    mountPath = "/etc/sshc";
                  };
                }
                {
                  name = "csi-node-driver-registrar";
                  image = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.15.0";
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
                  name = "livenessprobe";
                  image = "registry.k8s.io/sig-storage/livenessprobe:v2.17.0";
                  args = [ "--csi-address=/csi/csi.sock" ];
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
                    path = cfg.hostMountPath;
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
                  name = "nix-config";
                  configMap.name = "nix-config";
                }
              ]
              ++ lib.optional cfg.enableBinaryCache {
                name = "sshc";
                secret.secretName = "sshc";
              };
            };
          };
        };
      };
    };
  };
}
