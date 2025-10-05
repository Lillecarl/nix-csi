# You could easily get tempted to create folders that go into container root
# using copyToRoot but it's easy to shoot yourself in the foot with Kubernetes
# mounting it's own shit over those paths making a mess out of your life.
{
  pkgs,
  dinixEval,
  nix2container,
}:
let
  lib = pkgs.lib;
  initCopy =
    pkgs.writeScriptBin "initCopy" # execline
      ''
        #! ${lib.getExe' pkgs.execline "execlineb"}
        foreground { rsync --archive --ignore-existing --one-file-system /nix/ /nix-volume/ }
        # Link rootEnv to /nix/var/result
        foreground { mkdir --parents /nix-volume/var }
        foreground { ln --symbolic --force --no-dereference ${rootEnv} /nix-volume/var/result }
        # Add gcroot for result
        foreground { mkdir --parents /nix-volume/var/nix/gcroots/nix-csi }
        foreground { ln --symbolic --force --no-dereference /nix-volume/var/result /nix-volume/var/nix/gcroots/nix-csi/result }
      '';
  rootEnv = pkgs.buildEnv {
    name = "rootEnv";
    paths = rootPaths;
  };
  rootPaths = [
    dinixEval.config.containerLauncher
    dinixEval.config.package
    pkgs.rsync
    pkgs.lix
    pkgs.util-linuxMinimal
    pkgs.gitMinimal
    pkgs.fishMinimal
    pkgs.uutils-coreutils-noprefix
  ];
in
nix2container.buildImage {
  name = "nix-csi";
  config = {
    Env = [
      "PATH=${rootEnv}/bin"
    ];
    Entrypoint = [ (lib.getExe initCopy) ];
  };
}
