let
  nixpkgs = builtins.fetchTree {
    type = "github";
    owner = "NixOS";
    repo = "nixpkgs";
    ref = "nixos-unstable";
  };
  dinix = builtins.fetchTree {
    type = "github";
    owner = "lillecarl";
    repo = "dinix";
    ref = "main";
  };
  pkgs = import nixpkgs { };
  lib = pkgs.lib;
  fakeNss = pkgs.buildEnv {
    name = "fakeNss";
    paths =
      let
        # loginShell = lib.getExe' pkgs.shadow "nologin";
        loginShell = lib.getExe pkgs.fish;
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
    pkgs.writeScriptBin "initCopy" # execline
      ''
        #! ${lib.getExe' pkgs.execline "execlineb"}
        # Remove result symlink and let rsync overwrite it. This way we get
        # persistence while allowing reconfiguration by relinking a new result.
        foreground { unlink /nix-volume/var/result }
        # rsync nix-csi supplied volume to /nix-volume which will be mounted as
        # /nix in the runtime container.
        ${lib.getExe pkgs.rsync} --archive --ignore-existing --one-file-system /nix/ /nix-volume/
      '';

  dinixEval = (
    import dinix {
      inherit pkgs;
      modules = [
        {
          config = {
            services.boot = {
              depends-on = [
                "nix-serve"
              ];
              waits-for = [
                "openssh"
              ];
            };
            services.openssh = {
              type = "process";
              command = "${lib.getExe' pkgs.openssh "sshd"} -D -f /etc/ssh/sshd_config -e";
              options = [ "shares-console" ];
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
                pkgs.writeScriptBin "setup" # execline
                  ''
                    #! ${lib.getExe' pkgs.execline "execlineb"}
                    importas -S HOME
                    foreground { mkdir --parents /tmp }
                    foreground { mkdir --parents /tmp/log }
                    foreground { mkdir --parents ''${HOME} }
                    foreground { rsync --verbose --archive --copy-links ${fakeNss}/ / }
                    foreground { rsync --verbose --archive ${pkgs.dockerTools.caCertificates}/ / }
                    # Tricking OpenSSH's security policies
                    foreground { rsync --archive --copy-links --chmod=600 /etc/ssh-mount/ /etc/ssh/ }
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
  paths = [
    initCopy
    pkgs.rsync
    pkgs.uutils-coreutils-noprefix
    pkgs.fishMinimal
    pkgs.gitMinimal
    pkgs.execline
    pkgs.lix
    pkgs.ncdu
    pkgs.openssh
    pkgs.curl
    dinixEval.config.package
    dinixEval.config.containerLauncher
  ];
}
