{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nix-csi;
in
{
  config = lib.mkIf cfg.enable {
    kubernetes.resources.${cfg.namespace} = {
      Secret.authorized-keys.stringData = {
        "authorized_keys" = lib.concatLines cfg.authorizedKeys;
      };
      Secret.ssh-config.stringData = {
        "id_ed25519.pub" = cfg.pubKey;
        "id_ed25519" = cfg.privKey;
        "ssh_config" = ''
          Host nix-cache
              User nix
              IdentityFile /etc/ssh/id_ed25519
              IdentitiesOnly yes
              # UserKnownHostsFile /etc/ssh/known_hosts
              StrictHostKeyChecking yes
        '';
        "ssh_known_hosts" = "* ${cfg.pubKey}";
        "sshd_config" = ''
          Port 22
          AddressFamily Any
          HostKey /etc/ssh/id_ed25519
          SyslogFacility DAEMON
          SetEnv PATH=/nix/var/result/bin
          PermitRootLogin no
          PubkeyAuthentication yes
          PasswordAuthentication no
          KbdInteractiveAuthentication no
          UsePAM no
          AuthorizedKeysFile /dev/null
          StrictModes no
          Subsystem sftp internal-sftp

          Match User nix
              AuthorizedKeysFile /etc/authorized_keys/authorized_keys
        '';
      };
    };
  };
}
