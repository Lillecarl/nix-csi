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
              command = "${lib.getExe' pkgs.openssh "sshd"} -D -f /etc/ssh/sshd_config";
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
                    foreground { mkdir --parents ''${HOME} }
                    foreground { rsync --verbose --archive ${pkgs.dockerTools.fakeNss}/ / }
                    foreground { rsync --verbose --archive ${pkgs.dockerTools.caCertificates}/ / }
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
