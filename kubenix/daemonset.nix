{ ... }:
{
  config = {
    kubernetes.api.resources.daemonSets."cknix-csi-node" = {
      metadata.namespace = "default";
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
                    mountPropagation = "HostToContainer";
                  }
                  {
                    name = "registration-dir";
                    mountPath = "/registration";
                  }
                  {
                    name = "supervisorconfig";
                    mountPath = "/etc/supervisor";
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
                  path = "/var/lib/cknix/nix";
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
                name = "supervisorconfig";
                configMap.name = "supervisorconfig";
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
