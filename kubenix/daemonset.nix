{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nix-csi;
  nsRes = config.kubernetes.resources.${cfg.namespace};
in
{
  config =
    let
      labels = {
        "app.kubernetes.io/name" = "csi";
        "app.kubernetes.io/part-of" = "nix-csi";
      };
    in
    lib.mkIf cfg.enable {
      kubernetes.resources.${cfg.namespace} = {
        DaemonSet.nix-node = {
          spec = {
            updateStrategy = {
              type = "RollingUpdate";
              rollingUpdate.maxUnavailable = 1;
            };
            selector.matchLabels = labels;
            template = {
              metadata.labels = labels;
              metadata.annotations = {
                "kubectl.kubernetes.io/default-container" = "nix-node";
                configHash = lib.hashAttrs (
                  { }
                  // nsRes.ConfigMap.nix-node or { }
                  // nsRes.Secret.ssh-config or { }
                  // nsRes.Secret.authorized-keys or { }
                );
              };
              spec = {
                serviceAccountName = "nix-csi";
                subdomain = cfg.internalServiceName;
                initContainers = lib.mkNumberedList {
                  "1" = {
                    name = "initcopy";
                    image = "ghcr.io/lillecarl/nix-csi/lix:${pkgs.lixPackageSets.lix_2_93.lix.version}";
                    imagePullPolicy = "Always";
                    securityContext.privileged = true; # chroot store
                    env =
                      lib.mkNamedList {
                        CACHE_ENABLED.value = lib.boolToString cfg.cache.enable;
                        amd64.value =
                          if cfg.push then
                            config.nix-csi.nodePackage.x86_64-linux
                          else
                            builtins.unsafeDiscardStringContext cfg.nodePackage.x86_64-linux;
                        arm64.value =
                          if cfg.push then
                            config.nix-csi.nodePackage.aarch64-linux
                          else
                            builtins.unsafeDiscardStringContext cfg.nodePackage.aarch64-linux;
                      }
                      // lib.optionalAttrs (lib.stringLength (builtins.getEnv "GITHUB_KEY") > 0) {
                        NIX_CONFIG.value = "access-tokens = github.com=${builtins.getEnv "GITHUB_KEY"}";
                      };
                    volumeMounts = lib.mkNamedList {
                      nix-store.mountPath = "/nix-volume";
                      nix-config.mountPath = "/etc/nix";
                    };
                  };
                };
                containers = lib.mkNamedList {
                  nix-node = {
                    image = "ghcr.io/lillecarl/nix-csi/scratch:1.0.1";
                    command = [
                      "dinit"
                      "--log-file"
                      "/var/log/dinit.log"
                      "--quiet"
                      "csi"
                    ];
                    securityContext.privileged = true;
                    env =
                      lib.mkNamedList {
                        CSI_ENDPOINT.value = "unix:///csi/csi.sock";
                        HOME.value = "/nix/var/nix-csi/root";
                        KUBE_NODE_NAME.valueFrom.fieldRef.fieldPath = "spec.nodeName";
                        KUBE_POD_IP.valueFrom.fieldRef.fieldPath = "status.podIP";
                        USER.value = "root";
                      }
                      // lib.optionalAttrs (lib.stringLength (builtins.getEnv "GITHUB_KEY") > 0) {
                        NIX_CONFIG.value = "access-tokens = github.com=${builtins.getEnv "GITHUB_KEY"}";
                      };
                    volumeMounts = lib.mkNamedList {
                      csi-socket.mountPath = "/csi";
                      nix-config.mountPath = "/etc/nix";
                      registration.mountPath = "/registration";
                      ssh-config.mountPath = "/etc/ssh";
                      authorized-keys.mountPath = "/etc/authorized_keys";
                      kubelet = {
                        mountPath = "/var/lib/kubelet";
                        mountPropagation = "Bidirectional";
                      };
                      nix-store = {
                        mountPath = "/nix";
                        mountPropagation = "Bidirectional";
                        subPath = "nix";
                      };
                    };
                  };
                  csi-node-driver-registrar = {
                    image = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.15.0";
                    args = [
                      "--v=5"
                      "--csi-address=/csi/csi.sock"
                      "--kubelet-registration-path=/var/lib/kubelet/plugins/nix.csi.store/csi.sock"
                    ];
                    env = lib.mkNamedList {
                      KUBE_NODE_NAME.valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    };
                    volumeMounts = lib.mkNamedList {
                      csi-socket.mountPath = "/csi";
                      kubelet.mountPath = "/var/lib/kubelet";
                      registration.mountPath = "/registration";
                    };
                  };
                  livenessprobe = {
                    image = "registry.k8s.io/sig-storage/livenessprobe:v2.17.0";
                    args = [ "--csi-address=/csi/csi.sock" ];
                    volumeMounts = lib.mkNamedList {
                      csi-socket.mountPath = "/csi";
                      registration.mountPath = "/registration";
                    };
                  };
                };
                volumes = lib.mkNamedList {
                  nix-config.configMap.name = "nix-node";
                  registration.hostPath.path = "/var/lib/kubelet/plugins_registry";
                  nix-store.hostPath = {
                    path = cfg.hostMountPath;
                    type = "DirectoryOrCreate";
                  };
                  csi-socket.hostPath = {
                    path = "/var/lib/kubelet/plugins/nix.csi.store/";
                    type = "DirectoryOrCreate";
                  };
                  kubelet.hostPath = {
                    path = "/var/lib/kubelet";
                    type = "Directory";
                  };
                  ssh-config.secret = {
                    secretName = "ssh-config";
                    defaultMode = 256; # 400
                  };
                  authorized-keys.secret = {
                    secretName = "authorized-keys";
                    defaultMode = 438; # 666
                  };
                };
              };
            };
          };
        };
        # DNS for pods
        Service.${cfg.internalServiceName}.spec = {
          clusterIP = "None";
          selector = labels;
          ports = lib.mkNamedList {
            ssh.port = 22;
          };
        };
      };
    };
}
