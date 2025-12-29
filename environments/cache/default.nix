{
  pkgs,
  dinix,
}:
let
  lib = pkgs.lib;
  dinixEval = import dinix {
    inherit pkgs;
    modules = [
      {
        config = {
          users = {
            enable = true;
            users.root = {
              shell = pkgs.runtimeShell;
              homeDir = "/nix/var/nix-csi/root";
            };
            users.nix = {
              uid = 1000;
              gid = 1000;
              comment = "Nix worker user";
            };
            groups.nix.gid = 1000;
            groups.nixbld.gid = 30000;
            users.sshd = {
              uid = 993;
              gid = 992;
              comment = "SSH privilege separation user";
            };
            groups.sshd.gid = 992;
          };
          env-file.variables = {
            PYTHONUNBUFFERED = "1"; # If something ends up print logging
            NIXPKGS_ALLOW_UNFREE = "1"; # Allow building anything
          };
          services.openssh = {
            type = "process";
            command =
              pkgs.writeScriptBin "openssh-launcher" # bash
                ''
                  #! ${pkgs.runtimeShell}
                  for i in $(seq 1 10); do
                    test -f /etc/ssh/sshd_config && break
                    sleep 1
                  done
                  exec ${lib.getExe' pkgs.openssh "sshd"} -D -f /etc/ssh/sshd_config -e
                '';
            depends-on = [ "shared-setup" ];
            log-type = "file";
            logfile = "/var/log/ssh.log";
          };
          services.nix-daemon = {
            command = "${lib.getExe pkgs.lixPackageSets.lix_2_93.lix} daemon --store local";
            depends-on = [ "shared-setup" ];
            log-type = "file";
            logfile = "/var/log/nix-daemon.log";
          };
          services.config-reconciler = {
            type = "process";
            log-type = "file";
            logfile = "/var/log/config-reconciler.log";
            command =
              pkgs.writeScriptBin "config-reconciler" # bash
                ''
                  #! ${pkgs.runtimeShell}
                  set -euo pipefail
                  export PATH=${
                    lib.makeBinPath [
                      pkgs.rsync
                      pkgs.coreutils
                    ]
                  }
                  while true
                  do
                    # Tricking OpenSSH's security policies like a pro!
                    #
                    # Exclude authorized_keys from root, we don't want anyone
                    # logging in as root in our containers.
                    rsync --archive --mkpath --copy-links --chmod=D700,F600 --exclude='authorized_keys' /etc/ssh-mount/ $HOME/.ssh/
                    # Here authorized_keys don't matter since we only check %h
                    # for authorized_keys in sshd config
                    rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=root:root /etc/ssh-mount/ /etc/ssh/
                    # Everyone should log in as Nix to build or substitute
                    rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=nix:nix /etc/ssh-mount/ /home/nix/.ssh/

                    # Copy mounted Nix config to nix config dir
                    # (Need RW /etc/nix for writing machines file)
                    rsync --archive --mkpath --copy-links --chmod=D755,F644 --chown=root:root /etc/nix-mount/ /etc/nix/
                    # 60s reconciliation is good enough(TM)
                    sleep 60
                  done
                '';
          };
          services.shared-setup = {
            type = "scripted";
            log-type = "file";
            logfile = "/var/log/shared-setup.log";
            depends-on = [ "config-reconciler" ];
            command =
              pkgs.writeScriptBin "shared-setup" # bash
                ''
                  #! ${pkgs.runtimeShell}
                  set -euo pipefail
                  set -x
                  export PATH=${
                    lib.makeBinPath (
                      with pkgs;
                      [
                        rsync
                        coreutils
                        lix
                      ]
                    )
                  }
                  mkdir --parents {/tmp,/var/tmp}
                  chmod -R 1777 {/tmp,/var/tmp}
                  mkdir --parents {/var/log}
                  chmod -R 0755 {/var/log}
                  rsync --archive ${pkgs.dockerTools.binSh}/ /
                  rsync --archive ${pkgs.dockerTools.caCertificates}/ /
                  rsync --archive ${pkgs.dockerTools.usrBinEnv}/ /
                  rsync --archive --mkpath --copy-links --chmod=D700,F600 --exclude='authorized_keys' /etc/ssh-mount/ $HOME/.ssh/
                  rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=root:root /etc/ssh-mount/ /etc/ssh/
                  rsync --archive --mkpath --copy-links --chmod=D700,F600 --chown=nix:nix /etc/ssh-mount/ /home/nix/.ssh/
                  # Fix gcroots for /nix/var/result. The one created by initCopy
                  # points to invalid symlinks in the chain
                  # (auto -> /nix-volume/var/result) rather than
                  # (auto -> /nix/var/result). The link back to store works
                  # though so this just fixes gcroots.
                  nix build --store local --out-link /nix/var/result /nix/var/result
                '';
          };
          # Umbrella service for cache
          services.cache = {
            type = "scripted";
            options = [ "starts-rwfs" ];
            command =
              pkgs.writeScriptBin "cache" # bash
                ''
                  #! ${pkgs.runtimeShell}
                  mkdir --parents /run
                  mkdir --parents /var/log
                '';
            depends-on = [
              "cache-daemon"
              "cache-logger"
              "cache-gc"
              "openssh"
            ];
          };
          services.cache-daemon = {
            command = "${lib.getExe pkgs.nix-cache} --loglevel DEBUG";
            log-type = "file";
            logfile = "/var/log/cache-daemon.log";
            depends-on = [ "shared-setup" ];
            depends-ms = [ "nix-daemon" ];
          };
          services.cache-logger = {
            command = "${lib.getExe' pkgs.coreutils "tail"} --follow /var/log/cache-daemon.log /var/log/dinit.log";
            options = [ "shares-console" ];
            depends-on = [ "cache-daemon" ];
          };
          # Make OpenSSH depend on cache-daemon so it can create the secret that'll
          # be mounted into /etc/ssh-mount when it's crashed once.
          # services.openssh.waits-for = [ "cache-daemon" ];
          services.cache-gc = {
            type = "scripted";
            command =
              pkgs.writeScriptBin "cache-gc" # bash
                ''
                  #! ${pkgs.runtimeShell}
                  # Fix gcroots for /nix/var/result
                  nix build --out-link /nix/var/result /nix/var/result
                  # Collect old shit
                  ${lib.getExe pkgs.nix-timegc} 86400
                '';
            log-type = "file";
            logfile = "/var/log/cache-gc.log";
            depends-on = [
              "nix-daemon"
              "shared-setup"
            ];
          };
        };
      }
    ];
  };
  pathEnv = pkgs.buildEnv {
    name = "cacheEnv";
    paths = with pkgs; [
      dinixEval.config.containerWrapper
      bash # Used for build and upload scripts
      coreutils
      fishMinimal
      lix
      openssh
      util-linuxMinimal
      gnugrep
      getent
      doggo
      iputils
      curl
    ];
    # So we can peek into eval
    passthru.dinixEval = dinixEval;
  };
in
pathEnv
