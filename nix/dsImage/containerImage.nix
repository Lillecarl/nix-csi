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

  build =
    pkgs.writeScriptBin "build" # bash
      ''
        #! ${pkgs.runtimeShell}
        export PATH=${lib.makeBinPath [ pkgs.rsync ]}:$PATH
        mkdir --parents $HOME
        rsync --verbose --archive ${pkgs.dockerTools.binSh}/ /
        rsync --verbose --archive ${pkgs.dockerTools.fakeNss}/ /
        rsync --verbose --archive ${pkgs.dockerTools.caCertificates}/ /
        rsync --verbose --archive ${pkgs.dockerTools.usrBinEnv}/ /
        source /buildscript/run
      '';

  initCopy =
    pkgs.writeScriptBin "initCopy" # bash
      ''
        #! ${pkgs.runtimeShell}
        set -euo pipefail
        set -x
        export PATH=${
          lib.makeBinPath (
            with pkgs;
            [
              rsync
              coreutils
              lix
              nix_init_db
            ]
          )
        }
        rsync --archive --ignore-existing --one-file-system /nix/ /nix-volume/
        # Link rootEnv to /nix/var/result
        ln --symbolic --force ${rootEnv} /nix-volume/var/result
        # Import(merge) Nix database with paths from image
        nix_init_db /nix-volume/var/nix $(nix path-info --all)
        # Add gcroot for result, /nix/var/result will be available in the
        # runtime container.
        mkdir --parents /nix-volume/var/nix/gcroots/nix-csi
        ln --symbolic --force --no-dereference /nix/var/result /nix-volume/var/nix/gcroots/nix-csi/result
      '';

  rootEnv = pkgs.buildEnv {
    name = "rootEnv";
    paths = with pkgs; [
      # We only need containerWrapper, the rest are just for troubleshooting
      # and development purposes
      dinixEval.config.containerWrapper
      fishMinimal
      coreutils
      lix
      build
      util-linuxMinimal
    ];
  };
in
nix2container.buildImage {
  name = "nix-csi";
  initializeNixDatabase = true;
  maxLayers = 120;
  # Include NSS so we can run Nix in the init container
  copyToRoot = with pkgs; [ dockerTools.fakeNss ];
  # This images only function is to copy itself into a hostPath mount
  config.Entrypoint = [ (lib.getExe initCopy) ];
}
