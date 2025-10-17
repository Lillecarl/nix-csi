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
    pkgs.writeScriptBin "initCopy" # bash
      ''
        #! ${pkgs.runtimeShell}
        set -euo pipefail
        set -x
        rsync --archive --ignore-existing --one-file-system /nix/ /nix-volume/
        # Link rootEnv to /nix/var/result
        ln --symbolic --force --no-dereference ${rootEnv} /nix-volume/var/result
        # Import(merge) Nix database with paths from image
        nix_init_db /nix-volume/var/nix $(nix path-info --all)
        # Add gcroot for result, /nix/var/result will be available in the
        # runtime container.
        mkdir --parents /nix-volume/var/nix/gcroots/nix-csi
        ln --symbolic --force --no-dereference /nix/var/result /nix-volume/var/nix/gcroots/nix-csi/result
      '';
  rootEnv = pkgs.buildEnv {
    name = "rootEnv";
    paths = rootPaths ++ utilPaths;
  };
  utilPaths = with pkgs; [
    nix_init_db
    openssh
    rsync
    lix
    util-linuxMinimal
    gitMinimal
    fishMinimal
    uutils-coreutils-noprefix
  ];
  rootPaths = [
    dinixEval.config.containerLauncher
    dinixEval.config.package
  ];
in
nix2container.buildImage {
  name = "nix-csi";
  initializeNixDatabase = true;
  maxLayers = 120; # Does this include "layers?""
  # Include NSS so we can run Nix in the init container
  copyToRoot = with pkgs; [
    dockerTools.fakeNss
  ];
  config = {
    Env = [
      "PATH=${rootEnv}/bin"
    ];
    Entrypoint = [ (lib.getExe initCopy) ];
  };
  layers = lib.map (
    package:
    nix2container.buildLayer {
      deps = [ package ];
    }
  ) utilPaths;
}
