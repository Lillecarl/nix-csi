{
  pkgs,
  config,
  lib,
  ...
}:
{
  config = {
    # mounts to /nix/var/nix-csi/home/.ssh
    kubernetes.resources.secrets.sshc = lib.mkIf config.enableBinaryCache {
      metadata.namespace = config.namespace;
      stringData = {
        known_hosts = builtins.readFile ../id_ed25519.pub;
        id_ed25519 = builtins.readFile ../id_ed25519;
        sshd_config = # ssh
          ''
            Host nix-cache
                HostName nix-cache.${config.namespace}.svc
                User nix-cache
                Port 22
                IdentityFile ~/.ssh/id_ed25519
                # StrictHostKeyChecking accept-new
                UserKnownHostsFile ~/.ssh/known_hosts
          '';
      };
    };

    kubernetes.api.resources.daemonSets."nix-csi-node" = {
      metadata.namespace = config.namespace;
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
            initContainers.populate-nix = {
              name = "populate-nix";
              image = config.image;
              volumeMounts = [
                {
                  mountPath = "/nix-volume";
                  name = "nix-store";
                }
              ];
              imagePullPolicy = "IfNotPresent";
            };
            containers.nix-csi-node = {
              name = "nix-csi-node";
              image = "dramforever/scratch@sha256:adf10351862ad5351ac2e714e04a0afb020b9df658ac99a07cbf49c0e18f8e43";
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
                  name = "hoststat";
                  mountPath = "/hoststat";
                }
                {
                  name = "nix-config";
                  mountPath = "/etc/nix";
                }
              ];
            };
            containers.nix-csi-registrar = {
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
            };
            containers.nix-csi-liveness = {
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
            };
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
                name = "hoststat";
                hostPath = {
                  path = "/proc/stat";
                  type = "File";
                };
              }
              {
                name = "nix-config";
                configMap.name = "nix-config";
              }
            ];
          };
        };
      };
    };
  };
}
