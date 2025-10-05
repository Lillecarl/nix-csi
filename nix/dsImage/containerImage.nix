# You could easily get tempted to create folders that go into container root
# using copyToRoot but it's easy to shoot yourself in the foot with Kubernetes
# mounting it's own shit over those paths making a mess out of your life.
{
  pkgs,
  dinixEval,
  buildImage, # nix2container
}:
let
  lib = pkgs.lib;
  fishMinimal = pkgs.fish.override { usePython = false; };
  initCopy =
    pkgs.writeScriptBin "initCopy" # execline
      ''
        #! ${lib.getExe' pkgs.execline "execlineb"}
        foreground { rm --recursive --force /nix-volume/var/result }
        exec ${lib.getExe pkgs.rsync} --verbose --archive --ignore-existing --one-file-system /nix/ /nix-volume/
      '';
  nixUserGroupShadow =
    let
      shell = lib.getExe fishMinimal;
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
    dinixEval.config.containerLauncher
    dinixEval.config.package
    pkgs.rsync
    pkgs.util-linuxMinimal
    pkgs.lix
    pkgs.gitMinimal
    fishMinimal
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
      # Set HOME to a persistent path so fetcher cache is persisted
      "HOME=/nix/var/nix-csi/home"
      "PATH=/bin"
      "NIX_PATH=nixpkgs=${pkgs.path}"
    ];
    Entrypoint = [ (lib.getExe dinixEval.config.containerLauncher) ];
    WorkingDir = "/nix/var/nix-csi/home";
  };
}
