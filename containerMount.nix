let
  nixpkgs = builtins.fetchTree {
    type = "github";
    repo = "nixpkgs";
    owner = "NixOS";
    ref = "nixos-unstable";
  };
  pkgs = import nixpkgs { };
in
pkgs.buildEnv {
  name = "containerEnv";
  paths = with pkgs; [
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
      exec sleep infinity
    '')
  ];
}
