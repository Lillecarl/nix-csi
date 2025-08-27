{ ... }:
{
  config = {
    kubernetes.api.resources.daemonSets.cknix-hostpath = {
      metadata.namespace = "default";
      spec = {
        selector.matchLabels.app = "cknix-hostpath";
        template = {
          metadata.labels.app = "cknix-hostpath";
          spec = {
            initContainers = [
              {
                name = "init";
                command = [
                  "fish"
                  "-c"
                  "echo asdf && sleep 5 && cp --verbose --archive --update=none /nix/* /nix2/"
                ];
                # todo: update to cknix
                image = "rg.nl-ams.scw.cloud/lillecarl/knix:latest";
                volumeMounts = [
                  {
                    mountPath = "/nix2";
                    name = "cknix";
                  }
                ];
                imagePullPolicy = "Always";
              }
            ];
            containers = [
              {
                name = "sleeper";
                # todo: update to cknix
                image = "rg.nl-ams.scw.cloud/lillecarl/knix:latest";
                command = [
                  "sleep"
                  "infinity"
                ];
                volumeMounts = [
                  {
                    name = "cknix";
                    mountPath = "/nix";
                  }
                  {
                    name = "cknixdev";
                    mountPath = "/cknix";
                  }
                ];
                env = [
                  {
                    name = "CKNIX_NODENAME";
                    valueFrom.fieldRef.fieldPath = "spec.nodeName";
                  }
                ];
                imagePullPolicy = "Always";
              }
            ];
            hostNetwork = true;
            volumes = [
              {
                name = "cknix";
                hostPath = {
                  path = "/var/lib/cknix/nix";
                  type = "DirectoryOrCreate";
                };
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
