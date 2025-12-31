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
  options.nix-csi.cache = {
    enable = lib.mkEnableOption "cache";
    storageClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    loadBalancerPort = lib.mkOption {
      type = lib.types.int;
      default = 2222;
    };
  };
  config =
    let
      labels = {
        "app.kubernetes.io/name" = "cache";
        "app.kubernetes.io/part-of" = "nix-csi";
      };
    in
    lib.mkIf (cfg.enable && cfg.cache.enable) {
      kubernetes.resources.${cfg.namespace} = {
        ConfigMap.authorized-keys.data.authorized_keys = lib.concatLines cfg.authorizedKeys;
        StatefulSet.nix-cache = {
          spec = {
            serviceName = "nix-cache";
            replicas = 1;
            selector.matchLabels = labels;
            template = {
              metadata.labels = labels;
              metadata.annotations = {
                "kubectl.kubernetes.io/default-container" = "nix-cache";
                configHash = lib.hashAttrs (
                  { }
                  // nsRes.ConfigMap.nix-cache or { }
                  // nsRes.Secret.ssh-config or { }
                  // nsRes.Secret.authorized-keys or { }
                );
              };
              spec = {
                serviceAccountName = "nix-csi";
                initContainers = lib.mkNumberedList {
                  "1" = {
                    name = "initcopy";
                    image = "ghcr.io/lillecarl/nix-csi/scratch:1.0.1";
                    command = [ "initCopy" ];
                    imagePullPolicy = "Always";
                    securityContext.privileged = true; # chroot store
                    volumeMounts = lib.mkNamedList {
                      init-store.mountPath = "/nix";
                      nix-store.mountPath = "/nix-volume";
                      nix-config.mountPath = "/etc/nix";
                    };
                  };
                };
                containers = lib.mkNamedList {
                  cache = {
                    command = [
                      "dinit"
                      "--log-file"
                      "/var/log/dinit.log"
                      "--quiet"
                      "cache"
                    ];
                    image = "ghcr.io/lillecarl/nix-csi/scratch:1.0.1";
                    env = lib.mkNamedList {
                      HOME.value = "/nix/var/nix-csi/root";
                      KUBE_NAMESPACE.valueFrom.fieldRef.fieldPath = "metadata.namespace";
                      BUILDERS_SERVICE_NAME.value = cfg.internalServiceName;
                    };
                    ports = lib.mkNamedList {
                      ssh.containerPort = 22;
                      http.containerPort = 80;
                    };
                    volumeMounts = lib.mkNamedList {
                      nix-config.mountPath = "/etc/nix";
                      ssh-config.mountPath = "/etc/ssh";
                      authorized-keys.mountPath = "/etc/authorized_keys";
                      nix-store = {
                        mountPath = "/nix";
                        subPath = "nix";
                      };
                    };
                  };
                };
                volumes = lib.mkNamedList {
                  nix-config.configMap.name = "nix-cache";
                  ssh-config.secret = {
                    secretName = "ssh-config";
                    defaultMode = 256; # 400
                  };
                  authorized-keys.secret = {
                    secretName = "authorized-keys";
                    defaultMode = 438; # 666
                  };
                  init-store.csi = {
                    driver = "nix.csi.store";
                    volumeAttributes = {
                      x86_64-linux =
                        if cfg.push then
                          config.nix-csi.cachePackage.x86_64-linux
                        else
                          builtins.unsafeDiscardStringContext cfg.cachePackage.x86_64-linux;
                      aarch64-linux =
                        if cfg.push then
                          config.nix-csi.cachePackage.aarch64-linux
                        else
                          builtins.unsafeDiscardStringContext cfg.cachePackage.aarch64-linux;
                    };
                  };
                };
              };
            };
            volumeClaimTemplates = lib.mkNumberedList {
              "1" = {
                metadata.name = "nix-store";
                spec = {
                  accessModes = [ "ReadWriteOnce" ];
                  resources.requests.storage = "10Gi";
                  inherit (cfg.cache) storageClassName;
                };
              };
            };
          };
        };

        Service.nix-cache = {
          spec = {
            selector = labels;
            ports = lib.mkNamedList {
              ssh = {
                port = 22;
                targetPort = "ssh";
              };
            };
            type = "ClusterIP";
          };
        };
        Service.nix-cache-lb = {
          spec = {
            selector = labels;
            ports = lib.mkNamedList {
              ssh = {
                port = cfg.cache.loadBalancerPort;
                targetPort = "ssh";
              };
            };
            type = "LoadBalancer";
          };
        };
      };
    };
}
