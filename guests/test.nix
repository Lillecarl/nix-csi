let
  nixpkgs = builtins.fetchTree {
    type = "github";
    owner = "NixOS";
    repo = "nixpkgs";
    ref = "nixos-unstable";
  };
  dinixSrc = builtins.fetchTree {
    type = "github";
    owner = "lillecarl";
    repo = "dinix";
    ref = "main";
  };
  pkgs = import nixpkgs { };
  lib = pkgs.lib;
  folderPaths = [
    "/tmp"
    "/var/tmp"
    "/var/log"
    "/var/lib"
    "/var/run"
    "/etc/ssl/certs"
  ];
  dinixEval = (
    import dinixSrc {
      inherit pkgs;
      modules = [
        {
          config = {
            services.boot.depends-on = [ "setup" ];
            services.setup = {
              type = "scripted";
              command = lib.getExe (
                pkgs.writeScriptBin "init" ''
                  #! ${lib.getExe' pkgs.execline "execlineb"}
                  export PATH "/nix/var/result/bin"
                  foreground { echo "Initializing" }
                  ${lib.concatMapStringsSep "\n" (folder: "foreground { mkdir --parents ${folder} }") folderPaths}
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
  name = "containerEnv";
  paths = with pkgs; [
    curl
    uutils-coreutils-noprefix
    fishMinimal
    execline
    lix
    gitMinimal
    ncdu
    dinixEval.config.containerWrapper
  ];
}
