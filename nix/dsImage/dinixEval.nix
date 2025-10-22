{
  pkgs,
  dinix,
}:
let
  lib = pkgs.lib;

  fakeNss = pkgs.buildEnv {
    name = "fakeNss";
    paths = [
      (pkgs.writeTextDir "etc/passwd" # passwd
        ''
          root:x:0:0:root user:/nix/var/nix-csi/home:/nix/var/result/nologin
          nobody:x:65534:65534:nobody:/nix/var/nix-csi/home:/nix/var/result/nologin
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
in
import dinix {
  inherit pkgs;
  modules = [
    {
      config = {
        services.boot.depends-on = [ "nix-csi" ];
        services.nix-csi = {
          command = "${lib.getExe pkgs.nix-csi} --loglevel DEBUG";
          options = [ "shares-console" ];
          depends-on = [
            "setup"
            "nix-daemon"
            "gc"
          ];
        };
        services.nix-daemon = {
          command = "${lib.getExe' pkgs.lix "nix-daemon"} --daemon --store local";
          options = [ "shares-console" ];
          depends-on = [ "setup" ];
        };
        services.gc = {
          type = "scripted";
          command = "${lib.getExe' pkgs.lix "nix-store"} --gc";
          options = [ "shares-console" ];
          depends-on = [ "nix-daemon" ];
        };
        # set up root filesystem with paths required for a Linux system to function normally
        services.setup = {
          type = "scripted";
          options = [ "shares-console" ];
          command = lib.getExe (
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
                mkdir --parents /usr/bin
                ln --symbolic --force ${lib.getExe' pkgs.coreutils "env"} /usr/bin/env
                mkdir --parents /tmp
                mkdir --parents ''${HOME}
                rsync --verbose --archive ${fakeNss}/ /
                rsync --verbose --archive ${pkgs.dockerTools.caCertificates}/ /
                # Tricking OpenSSH's security policies, allow this to fail, sshc might not exist
                rsync --archive --copy-links --chmod=600 /etc/sshc/ ''${HOME}/.ssh/ || true
                # Remove nix2container gcroots (they might be old, /nix/var/result is a valid gcroot)
                rm --recursive --force /nix/var/nix/gcroots/docker
                # Collect garbage on startup
              ''
          );
        };
      };
    }
  ];
}
