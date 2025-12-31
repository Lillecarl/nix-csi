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
            command = "${lib.getExe' pkgs.openssh "sshd"} -D -f /etc/ssh/sshd_config -e -d";
            depends-on = [ "setup" ];
            log-type = "file";
            logfile = "/var/log/ssh.log";
          };
          services.nix-daemon = {
            command = "${lib.getExe pkgs.lixPackageSets.lix_2_93.lix} daemon --store local";
            depends-on = [ "setup" ];
            log-type = "file";
            logfile = "/var/log/nix-daemon.log";
          };
          services.setup = {
            type = "scripted";
            log-type = "file";
            logfile = "/var/log/setup.log";
            command =
              pkgs.writeScriptBin "setup" # bash
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
              # "openssh"
            ];
            depends-ms = [
              "openssh"
            ];
          };
          services.cache-daemon = {
            command = "${lib.getExe pkgs.nix-cache} --loglevel DEBUG";
            log-type = "file";
            logfile = "/var/log/cache-daemon.log";
            depends-on = [ "setup" ];
            depends-ms = [ "nix-daemon" ];
          };
          services.cache-logger = {
            command = "${lib.getExe' pkgs.coreutils "tail"} --follow /var/log/cache-daemon.log /var/log/dinit.log /var/log/ssh.log";
            options = [ "shares-console" ];
            depends-on = [ "cache-daemon" ];
          };
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
              "setup"
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
