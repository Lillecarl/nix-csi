{ config, lib, ... }:
let
  cfg = config.nix-csi;
in
{
  config = lib.mkIf cfg.enable {
    kubernetes.resources.${cfg.namespace} = lib.mkIf (cfg.enableBinaryCache) {
      # Mounts to /etc/nix-serve
      Secret.nix-serve = {
        stringData.secret = builtins.readFile ../cache-secret;
      };

      # Mounts to /etc/ssh
      Secret.sshd = {
        stringData = {
          authorized_keys = builtins.readFile ../id_ed25519.pub;
          id_ed25519 = builtins.readFile ../id_ed25519;
          sshd_config = # sshd
            ''
              Port 22
              AddressFamily Any

              HostKey /etc/ssh/id_ed25519

              SyslogFacility DAEMON
              SetEnv PATH=/nix/var/result/bin

              PermitRootLogin prohibit-password
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

      StatefulSet.nix-cache = {
        spec = {
          serviceName = "nix-cache";
          replicas = 1;
          selector.matchLabels.app = "nix-cache";
          template = {
            metadata.labels.app = "nix-cache";
            spec = {
              initContainers = [
                {
                  name = "populate-nix";
                  command = [ "initCopy" ];
                  image = "quay.io/nix-csi/scratch:1.0.0";
                  env = [
                    {
                      name = "PATH";
                      value = "/nix/var/result/bin";
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "nix-csi";
                      mountPath = "/nix";
                    }
                    {
                      name = "nix-cache";
                      mountPath = "/nix-volume";
                    }
                  ];
                }
              ];
              containers = [
                {
                  name = "nix-serve";
                  command = [ "dinixLauncher" ];
                  image = "quay.io/nix-csi/scratch:1.0.0";
                  env = [
                    {
                      name = "PATH";
                      value = "/nix/var/result/bin";
                    }
                    {
                      name = "HOME";
                      value = "/var/empty";
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
                    {
                      name = "sshd";
                      mountPath = "/etc/ssh-mount";
                    }
                  ];
                }
              ];
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
                  name = "sshd";
                  secret.secretName = "sshd";
                }
                {
                  name = "nix-csi";
                  csi = {
                    driver = "nix.csi.store";
                    readOnly = false;
                    volumeAttributes.expression = builtins.readFile ../guests/cache.nix;
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

      Service.nix-cache = {
        spec = {
          selector.app = "nix-cache";
          ports = [
            {
              port = 22;
              targetPort = 22;
              name = "ssh";
            }
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
  };
}
