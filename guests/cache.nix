{
  pkgs ? import <nixpkgs> { },
  dinix ? import <dinix>,
}:
let
  lib = pkgs.lib;
  # This should be in sync with the one from ../pkgs/default.nix we must copy it
  # here since this is executed as a standalone expression without the repo
  nix_init_db =
    pkgs.writeScriptBin "nix_init_db" # execline
      ''
        #! ${lib.getExe' pkgs.execline "execlineb"} -s1
        emptyenv -p
        pipeline { nix-store --option store local --dump-db $@ }
        export USER nobody
        export NIX_STATE_DIR $1
        exec nix-store --load-db --option store local
      '';
  fakeNss = pkgs.buildEnv {
    name = "fakeNss";
    paths =
      let
        loginShell = lib.getExe pkgs.fishMinimal;
      in
      [
        (pkgs.writeTextDir "etc/passwd" # passwd
          ''
            root:x:0:0:root user:/var/empty:${loginShell}
            sshd:x:0:0:root user:/var/empty:${loginShell}
            nobody:x:65534:65534:nobody:/var/empty:${loginShell}
          ''
        )
        (pkgs.writeTextDir "etc/group" # group
          ''
            root:x:0:
            nobody:x:65534:
          ''
        )
        (pkgs.writeTextDir "etc/nsswitch.conf" ''
          hosts: files dns
        '')
      ];
  };

  initCopy =
    pkgs.writeScriptBin "initCopy" # bash
      ''
        #! ${pkgs.runtimeShell}
        set -euo pipefail
        set -x
        # Make fakeNss available so we can use nix_init_db
        rsync --verbose --archive ${fakeNss}/ /
        # Remove result symlink and let rsync overwrite it. This way we get
        # persistence while allowing reconfiguration by relinking a new result.
        unlink /nix-volume/var/result || true
        # rsync nix-csi supplied volume to /nix-volume which will be mounted as
        # /nix in the runtime container.
        rsync --archive --ignore-existing --one-file-system /nix/ /nix-volume/
        # Import Nix database from bootstrapping mount
        nix_init_db /nix-volume/var/nix $(nix path-info --option store local --all)
      '';

  dinixEval = (
    dinix {
      inherit pkgs;
      modules = [
        {
          config = {
            services.boot = {
              depends-on = [
                "nix-serve"
                "openssh"
                "nix-daemon"
              ];
            };
            services.openssh = {
              type = "process";
              command = "${lib.getExe' pkgs.openssh "sshd"} -D -f /etc/ssh/sshd_config -e";
              options = [ "shares-console" ];
              depends-on = [ "setup" ];
            };
            services.nix-daemon = {
              command = "${lib.getExe' pkgs.lix "nix-daemon"} --daemon --store local";
              depends-on = [ "setup" ];
            };
            services.nix-serve = {
              type = "process";
              command = "${lib.getExe pkgs.nix-serve-ng} --host * --port 80";
              options = [ "shares-console" ];
              depends-on = [ "setup" ];
            };
            # set up root filesystem with paths required for a Linux system to function normally
            services.setup = {
              type = "scripted";
              command = lib.getExe (
                pkgs.writeScriptBin "setup" # bash
                  ''
                    #! ${pkgs.runtimeShell}
                    mkdir --parents /usr/bin
                    mkdir --parents /tmp
                    mkdir --parents /tmp/log
                    mkdir --parents ''${HOME}
                    rsync --verbose --archive ${fakeNss}/ /
                    rsync --verbose --archive ${pkgs.dockerTools.binSh}/ /
                    rsync --verbose --archive ${pkgs.dockerTools.caCertificates}/ /
                    rsync --verbose --archive ${pkgs.dockerTools.usrBinEnv}/ /
                    # Tricking OpenSSH's security policies
                    rsync --archive --copy-links --chmod=600 /etc/ssh-mount/ /etc/ssh/
                  ''
              );
            };
          };
        }
      ];
    }
  );
in
pkgs.buildEnv {
  name = "binary-cache-env";
  paths = with pkgs; [
    initCopy
    nix_init_db
    rsync
    coreutils
    fishMinimal
    gitMinimal
    lix
    ncdu
    openssh
    curl
    dinixEval.config.containerWrapper
  ];
}
