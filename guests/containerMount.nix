let
  nixpkgs = builtins.fetchTree {
    type = "github";
    repo = "nixpkgs";
    owner = "NixOS";
    ref = "nixos-unstable";
  };
  dinixSrc = builtins.fetchTree {
    type = "git";
    url = "https://github.com/Lillecarl/dinix.git";
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
            services.boot.depends-on-d = [ "setup" ];
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
    coreutils
    fish
    execline
    lixStatic
    dinixEval.config.package
    (pkgs.writeScriptBin "dinixinit" ''
      #! ${lib.getExe' pkgs.execline "execlineb"}
      foreground { mkdir -p /run }
      exec ${lib.getExe dinixEval.config.dinitLauncher} --container
    '')
  ];
}
