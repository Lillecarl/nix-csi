{
  config,
  lib,
  pkgs,
  x86Pkgs,
  armPkgs,
  mkNCSI,
  ...
}:
let
  cfg = config.nix-csi;
  nsRes = config.kubernetes.resources.${cfg.namespace};
in
{
  options.nix-csi.node = {
    enable = (lib.mkEnableOption "cache") // {
      default = true;
    };
    nixConfig = lib.mkOption {
      description = "nix.conf for CSI/mounter/DaemonSet pods";
      type = (import ./nixOptions.nix) pkgs;
    };
  };
  config =
    let
      labels = {
        "app.kubernetes.io/name" = "csi";
        "app.kubernetes.io/part-of" = "nix-csi";
      };
    in
    lib.mkIf cfg.enable {
      kubernetes.resources.${cfg.namespace} = {
        DaemonSet.nix-node = mkNCSI {
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
                  { } // nsRes.ConfigMap.nix-node or { } // nsRes.configMap.ssh-config or { }
                );
              };
              spec = {
                serviceAccountName = "nix-csi";
                priorityClassName = "system-node-critical";
                subdomain = cfg.internalServiceName;
                initContainers = lib.mkNumberedList {
                  "1" = {
                    name = "initcopy";
                    image = "ghcr.io/lillecarl/nix-csi/lix:${pkgs.lixPackageSets.lix_2_93.lix.version}";
                    imagePullPolicy = "Always";
                    securityContext.privileged = true; # chroot store
                    env = lib.mkNamedList {
                      # Use GOARCH instead of system since system is not valid bash variable identifier
                      # Only render storePaths here, building is done with a ConfigMap (config.nix) only if cfg.push is set
                      # this is so users don't have to build locally to deploy.
                      ${x86Pkgs.go.GOARCH}.value = x86Pkgs.nix-csi-node-env;
                      ${armPkgs.go.GOARCH}.value = armPkgs.nix-csi-node-env;
                    };
                    volumeMounts = lib.mkNamedList {
                      nix-store.mountPath = "/nix-volume";
                      nix-config.mountPath = "/etc/nix";

                      ssh-config.mountPath = "/etc/ssh";
                      ssh-key.mountPath = "/etc/ssh-key";
                      ssh-dynauth.mountPath = "/etc/ssh-dynauth";
                    };
                    resources = {
                      requests = {
                        memory = "128Mi";
                        cpu = "100m";
                      };
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
                    env = lib.mkNamedList {
                      BUILDERS_ENABLED.value = lib.boolToString cfg.builders.enable;
                      CACHE_ENABLED.value = lib.boolToString cfg.cache.enable;
                      CSI_ENDPOINT.value = "unix:///csi/csi.sock";
                      HOME.value = "/nix/var/nix-csi/root";
                      KUBE_NAMESPACE.valueFrom.fieldRef.fieldPath = "metadata.namespace";
                      KUBE_NODE_NAME.valueFrom.fieldRef.fieldPath = "spec.nodeName";
                      KUBE_POD_IP.valueFrom.fieldRef.fieldPath = "status.podIP";
                      NIX_BUILD_TIMEOUT.value = toString cfg.nodeBuildTimeout;
                      RSYNC_CONCURRENCY.value = toString cfg.rsyncConcurrency;
                      USER.value = "root";
                    };
                    volumeMounts = lib.mkNamedList {
                      csi-socket.mountPath = "/csi";
                      nix-config.mountPath = "/etc/nix";
                      registration.mountPath = "/registration";
                      kubelet = {
                        mountPath = "/var/lib/kubelet";
                        mountPropagation = "Bidirectional";
                      };
                      nix-store = {
                        mountPath = "/nix";
                        mountPropagation = "Bidirectional";
                        subPath = "nix";
                      };

                      ssh-config.mountPath = "/etc/ssh";
                      ssh-dynauth.mountPath = "/etc/ssh-dynauth";
                      ssh-key.mountPath = "/etc/ssh-key";
                    };
                    resources = {
                      requests = {
                        memory = "128Mi";
                        cpu = "100m";
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
                    resources = {
                      requests = {
                        memory = "10Mi";
                        cpu = "10m";
                      };
                    };
                  };
                  livenessprobe = {
                    image = "registry.k8s.io/sig-storage/livenessprobe:v2.17.0";
                    args = [ "--csi-address=/csi/csi.sock" ];
                    volumeMounts = lib.mkNamedList {
                      csi-socket.mountPath = "/csi";
                      registration.mountPath = "/registration";
                    };
                    resources = {
                      requests = {
                        memory = "10Mi";
                        cpu = "10m";
                      };
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

                  ssh-config.configMap = {
                    name = "ssh-config";
                    defaultMode = 292; # 444
                  };
                  ssh-dynauth.configMap = {
                    name = "ssh-dynauth";
                    defaultMode = 292; # 444
                  };
                  ssh-key.secret = {
                    secretName = "ssh-key";
                    defaultMode = 256; # 400
                  };
                };
              };
            };
          };
        };
        # DNS for pods
        Service.${cfg.internalServiceName} = mkNCSI {
          spec = {
            clusterIP = "None";
            selector = labels;
            ports = lib.mkNamedList {
              ssh.port = 22;
            };
          };
        };
      };
    };
}
