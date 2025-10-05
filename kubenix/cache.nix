{ config, lib, ... }:
{
  config = lib.mkIf config.enableBinaryCache {
    # Mounts to /etc/nix-serve
    kubernetes.resources.secrets.nix-serve = {
      metadata.namespace = config.namespace;
      stringData.secret = builtins.readFile ../cache-secret;
    };

    # Mounts to /etc/ssh
    kubernetes.resources.secrets.sshd = {
      metadata.namespace = config.namespace;
      stringData = {
        authorized_keys = builtins.readFile ../id_ed25519.pub;
        id_ed25519 = builtins.readFile ../id_ed25519;
        sshd_config = # sshd
          ''
            Port 22
            HostKey /etc/ssh/id_ed25519

            PermitRootLogin no
            PubkeyAuthentication yes
            PasswordAuthentication no
            ChallengeResponseAuthentication no
            UsePAM no

            AuthorizedKeysFile /etc/ssh/authorized_keys

            StrictModes no

            Subsystem sftp internal-sftp
          '';
      };
    };

    kubernetes.resources.statefulSets.nix-cache = {
      metadata.namespace = config.namespace;
      spec = {
        serviceName = "nix-cache";
        replicas = 1;
        selector.matchLabels.app = "nix-cache";
        template = {
          metadata.labels.app = "nix-cache";
          spec = {
            initContainers.populate-nix = {
              command = [ "initCopy" ];
              image = "dramforever/scratch@sha256:adf10351862ad5351ac2e714e04a0afb020b9df658ac99a07cbf49c0e18f8e43";
              env = [
                {
                  name = "PATH";
                  value = "/nix/var/result/bin";
                }
              ];
              volumeMounts = [
                {
                  name = "nix-config";
                  mountPath = "/etc/nix";
                }
                {
                  name = "nix-csi";
                  mountPath = "/nix";
                }
                {
                  name = "nix-cache";
                  mountPath = "/nix-volume";
                }
              ];
            };
            containers.nix-serve = {
              command = [ "dinixLauncher" ];
              image = "dramforever/scratch@sha256:adf10351862ad5351ac2e714e04a0afb020b9df658ac99a07cbf49c0e18f8e43";
              env = [
                {
                  name = "PATH";
                  value = "/nix/var/result/bin";
                }
                {
                  name = "NIX_SECRET_KEY_FILE";
                  value = "/etc/nix-serve/secret";
                }
              ];
              ports = [
                {
                  containerPort = 80;
                  name = "http";
                }
              ];
              volumeMounts = [
                {
                  name = "nix-config";
                  mountPath = "/etc/nix";
                }
                {
                  name = "nix-cache";
                  mountPath = "/nix";
                }
                {
                  name = "nix-serve";
                  mountPath = "/etc/nix-serve";
                }
              ];
            };
            volumes = [
              {
                name = "nix-config";
                configMap.name = "nix-config";
              }
              {
                name = "nix-serve";
                secret.secretName = "nix-serve";
              }
              {
                name = "nix-csi";
                csi = {
                  driver = "nix.csi.store";
                  readOnly = true;
                  volumeAttributes.expr = builtins.readFile ../guests/binary-cache.nix;
                };
              }
              {
                name = "nix-cache";
                hostPath = {
                  path = "/var/lib/nix-csi-cache";
                  type = "DirectoryOrCreate";
                };
              }
            ];
          };
        };
        # volumeClaimTemplates = [
        #   {
        #     metadata.name = "nix-cache";
        #     spec = {
        #       accessModes = [ "ReadWriteOnce" ];
        #       resources.requests.storage = "10Gi";
        #     };
        #   }
        # ];
      };
    };

    kubernetes.resources.services.nix-cache = {
      metadata.namespace = config.namespace;
      spec = {
        selector.app = "nix-cache";
        ports = [
          {
            port = 80;
            targetPort = 80;
            name = "http";
          }
        ];
        type = "ClusterIP";
      };
    };
  };
}
