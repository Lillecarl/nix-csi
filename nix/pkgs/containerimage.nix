# You could easily get tempted to create folders that go into container root
# using copyToRoot but it's easy to shoot yourself in the foot with Kubernetes
# mounting it's own shit over those paths making a mess out of your life.
{
  pkgs ? import <nixpkgs> {},
  dinixEval,
  buildImage # nix2container
}:
let
  lib = pkgs.lib;
  fishDinitLauncher =
    pkgs.writeScriptBin "fishDinitLauncher" # fish
      ''
        #! ${lib.getExe pkgs.fish}
        mkdir -p /run
        exec ${lib.getExe dinixEval.config.dinitLauncher} --container
      '';
  initCopy =
    pkgs.writeScriptBin "initCopy" # fish
      ''
        #! ${lib.getExe pkgs.fish}
        exec ${lib.getExe pkgs.rsync} --verbose --archive --ignore-existing --one-file-system /nix/ /nix2/
      '';
  nixUserGroupShadow =
    let
      shell = lib.getExe pkgs.fish;
    in
    ((import ../dockerUtils.nix pkgs).nonRootShadowSetup {
      users = [
        {
          name = "root";
          id = 0;
          inherit shell;
        }
        {
          name = "nix";
          id = 1000;
          inherit shell;
        }
        {
          name = "nixbld";
          id = 1001;
          inherit shell;
        }
      ];
    });
  rootEnv = pkgs.buildEnv {
    name = "rootEnv";
    paths = rootPaths;
  };
  rootPaths = [
    initCopy
    fishDinitLauncher
    dinixEval.config.package
    pkgs.rsync
    pkgs.util-linux
    pkgs.lixStatic
    pkgs.git
    pkgs.fish
    pkgs.uutils-coreutils-noprefix
    pkgs.dockerTools.caCertificates
    nixUserGroupShadow
  ];
in
buildImage {
  name = "nix-csi";
  # Links derivation into containers root
  copyToRoot = rootEnv;
  # Storepaths to bring into container
  # layers = rootPaths ++ [ fishDinitLauncher ];
  # Image configuration
  config = {
    Env = [
      "USER=nix"
      "HOME=/nix/var/nix-csi/home"
      "PATH=/bin"
      "NIX_PATH=nixpkgs=${pkgs.path}"
    ];
    Entrypoint = [ (lib.getExe fishDinitLauncher) ];
    WorkingDir = "/home/nix-csi";
  };
}
