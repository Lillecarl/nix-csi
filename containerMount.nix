let
  nixpkgs = builtins.fetchTree {
    type = "github";
    repo = "nixpkgs";
    owner = "NixOS";
    ref = "nixos-unstable";
  };
  pkgs = import nixpkgs { };
  lib = pkgs.lib;
  folderPaths = [
    "/tmp"
    "/var/tmp"
    "/var/log"
    "/var/lib"
    "/var/run"
  ];
in
pkgs.buildEnv {
  name = "containerEnv";
  paths = with pkgs; [
    curl
    coreutils
    fish
    execline
    tini
    lixStatic
    (pkgs.writeScriptBin "init" ''
      #! ${lib.getExe' pkgs.execline "execlineb"}
      export PATH "/nix/var/result/bin"
      foreground { echo "Initializing" }
      foreground { echo "Sleeping for infinity" }
      ${lib.concatMapStringsSep "\n" (folder: "foreground { mkdir --parents ${folder} }") folderPaths}
      foreground { ln --symbolic ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-bundle.crt }
      foreground { ln --symbolic ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt }
      exec sleep infinity
    '')
  ];
}
