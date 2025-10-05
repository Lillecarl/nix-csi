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

  initCopy =
    pkgs.writeScriptBin "initCopy" # execline
      ''
        #! ${lib.getExe' pkgs.execline "execlineb"}
        # Remove result symlink and let rsync overwrite it. This way we get
        # persistence while allowing reconfiguration by relinking a new result.
        foreground { rm --recursive --force /nix-volume/var/result }
        # rsync nix-csi supplied volume to /nix-volume which will be mounted as
        # /nix in the runtime container.
        ${lib.getExe pkgs.rsync} --verbose --archive --ignore-existing --one-file-system /nix/ /nix-volume/
      '';

  sshd_config =
    pkgs.writeText "sshd_config" # sshd
      ''
        # Network
        Port 22
        AddressFamily inet
        ListenAddress 0.0.0.0

        # Authentication
        PermitRootLogin no
        PubkeyAuthentication yes
        PasswordAuthentication no
        PermitEmptyPasswords no
        ChallengeResponseAuthentication no

        # Session
        X11Forwarding no
        PrintMotd no
        AcceptEnv LANG LC_*
      '';

  dinixEval = (
    import dinix {
      inherit pkgs;
      modules = [
        {
          config = {
            name = "dinixinit";
            services.boot = {
              depends-on = [ "setup" ];
            };
            services.openssh = {
              type = "process";
              command = "${lib.getExe' pkgs.openssh "sshd"} -D -f ${sshd_config}";
            };
            services.nix-serve-ng = {
              type = "process";
              command = "${lib.getExe pkgs.nix-serve-ng}";
            };
            services.setup = {
              type = "scripted";
              command = lib.getExe (
                pkgs.writeScriptBin "init" ''
                  #! ${lib.getExe' pkgs.execline "execlineb"}
                  foreground { mkdir --parents /etc/ssl/certs }
                  foreground { mkdir --parents /tmp }
                  foreground { ln --symbolic ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-bundle.crt }
                  foreground { ln --symbolic ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt }
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
    rsync
    curl
    uutils-coreutils-noprefix
    (fish.override { usePython = false; })
    execline
    lix
    gitMinimal
    ncdu
    dinixEval.config.package
    dinixEval.config.containerLauncher
  ];
}
