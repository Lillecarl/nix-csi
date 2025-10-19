{
  # Do a dance where we try to use NIX_PATH if it exists.
  pkgs ?
    let
      nimport = builtins.tryEval (import <nixpkgs> { });
    in
    if nimport.success then
      nimport.value
    else
      import (builtins.fetchTree {
        type = "github";
        owner = "NixOS";
        repo = "nixpkgs";
        ref = "nixos-unstable";
      }) { },
}:
let
  pkgs' = pkgs.extend (import ./pkgs);
in
let
  pkgs = pkgs';
  lib = pkgs.lib;

  dinix =
    let
      path = /home/lillecarl/Code/dinix;
    in
    if builtins.pathExists path then
      path
    else
      import (builtins.fetchTree {
        type = "github";
        owner = "lillecarl";
        repo = "dinix";
      }) { };

  n2cSrc = builtins.fetchTree {
    type = "github";
    owner = "nlewo";
    repo = "nix2container";
    ref = "master";
  };
  crossAttrs = {
    "x86_64-linux" = "aarch64-linux";
    "aarch64-linux" = "x86_64-linux";
  };
  pkgsCross = import pkgs.path {
    system = crossAttrs.${builtins.currentSystem};
    overlays = [ (import ./pkgs) ];
  };
  persys = pkgs: rec {
    inherit pkgs lib;
    n2c = import n2cSrc {
      inherit pkgs;
      system = pkgs.system;
    };
    csi-proto-python = pkgs.python3Packages.callPackage ./nix/csi-proto-python { };
    nix-csi = pkgs.python3Packages.callPackage ./python {
      inherit csi-proto-python;
    };
    easykubenix =
      let
        try = builtins.tryEval (import /home/lillecarl/Code/easykubenix);
      in
      if try.success then
        try.value
      else
        import (
          builtins.fetchTree {
            type = "github";
            owner = "lillecarl";
            repo = "easykubenix";
          }
        );

    # kubenix evaluation
    kubenixEval = easykubenix {
      modules = [
        ./kubenix
        {
          config = {
            nix-csi.image = imageRef;
            nix-csi.enableBinaryCache = true;
            kluctl.discriminator = "nix-csi";
          };
        }
      ];
    };

    # dinix evaluation for daemonset
    dinixEval = import ./nix/dsImage/dinixEval.nix { inherit pkgs dinix nix-csi; };
    # script to build daemonset image
    image = import ./nix/dsImage {
      inherit pkgs dinix nix-csi;
      inherit (n2c) nix2container;
    };
    imageToContainerd = copyToContainerd image;
    imageRef = "quay.io/nix-csi/${image.imageRefUnsafe}";

    copyToContainerd =
      image:
      pkgs.writeScriptBin "copyToContainerd" # execline
        ''
          #!${pkgs.execline}/bin/execlineb -P

          # Set up a socket we can write to
          backtick -E fifo { mktemp -u ocisocket.XXXXXX }
          foreground { mkfifo $fifo }
          trap { default { rm ''${fifo} } }

          # Dump image to socket in the background
          background {
            # Ignore stdout (since containerd requires sudo and we want a clean prompt)
            redirfd -w 1 /dev/null
            ${lib.getExe n2c.skopeo-nix2container}
              --insecure-policy copy
              nix:${image}
              oci-archive:''${fifo}:${imageRef}
          }
          export CONTAINERD_ADDRESS /run/containerd/containerd.sock

          foreground {
            sudo -E ${lib.getExe' pkgs.containerd "ctr"}
              --namespace k8s.io
              images import ''${fifo}
          }
          rm ''${fifo}
        '';

    deploy =
      pkgs.writers.writeFishBin "deploy" # fish
        ''
          # Generate binary cache keys
          if ! test -f ./cache-secret || ! test -f ./cache-public
              nix-store --generate-binary-cache-key nix-csi-cache-1 ./cache-secret ./cache-public
          end
          # Generate ssh keys
          if ! test -f ./id_ed25519 || ! test -f ./id_ed25519.pub
              ssh-keygen -t ed25519 -f ./id_ed25519 -C nix-cache -N ""
          end
          # Build DaemonSet containerImage
          nix run --file . imageToContainerd || begin
              echo "DaemonSet image failed"
              return 1
          end
          ${lib.getExe kubenixEval.deploymentScript} $argv
        '';

    # simpler than devshell
    python = pkgs.python3.withPackages (
      pypkgs: with pypkgs; [
        nix-csi
        csi-proto-python
        grpclib
        cachetools
      ]
    );
    # env to add to PATH with direnv
    repoenv = pkgs.buildEnv {
      name = "repoenv";
      paths = [
        python
        n2c.skopeo-nix2container
        pkgs.kluctl
        pkgs.buildah
      ];
    };
  };
in
let
  on = persys pkgs;
  off = persys pkgsCross;
in
on
// {
  inherit off;
  uploadCsi =
    let
      csiUrl = system: "quay.io/nix-csi/nix-csi:${on.nix-csi.version}-${system}";
      csiManifest = "quay.io/nix-csi/nix-csi:${on.nix-csi.version}";
    in
    pkgs.writeScriptBin "merge" # bash
      ''
        #! ${pkgs.runtimeShell}
        set -euo pipefail
        set -x
        buildDir=$(mktemp -d ocibuild.XXXXXX)
        echo $buildDir
        mkdir -p $buildDir
        cleanup() {
          rm -rf "$buildDir"
        }
        trap cleanup EXIT
        # Build and publish nix-csi image(s)
        ${lib.getExe on.image.copyTo} oci-archive:$buildDir/csi-${on.pkgs.system}:${csiUrl on.pkgs.system}
        ${lib.getExe off.image.copyTo} oci-archive:$buildDir/csi-${off.pkgs.system}:${csiUrl off.pkgs.system}
        podman load --input $buildDir/csi-${on.pkgs.system}
        podman load --input $buildDir/csi-${off.pkgs.system}
        podman push ${csiUrl on.pkgs.system}
        podman push ${csiUrl off.pkgs.system}
        podman manifest rm ${csiManifest} &>/dev/null || true
        podman manifest create ${csiManifest}
        podman manifest add ${csiManifest} ${csiUrl on.pkgs.system}
        podman manifest add ${csiManifest} ${csiUrl off.pkgs.system}
        podman manifest push ${csiManifest}
      '';
  uploadScratch =
    let
      scratchVersion = "1.0.0";
      scratchUrl = system: "quay.io/nix-csi/scratch:${scratchVersion}-${system}";
      scratchManifest = "quay.io/nix-csi/scratch:${scratchVersion}";
    in
    pkgs.writeScriptBin "merge" # bash
      ''
        #! ${pkgs.runtimeShell}
        set -euo pipefail
        set -x
        # Build and publish scratch image(s)
        buildah commit $(buildah from --platform linux/amd64 scratch) ${scratchUrl on.pkgs.system}
        buildah push ${scratchUrl on.pkgs.system}
        buildah commit $(buildah from --platform linux/arm64 scratch) ${scratchUrl off.pkgs.system}
        buildah push ${scratchUrl off.pkgs.system}
        buildah manifest rm ${scratchManifest} &>/dev/null || true
        buildah manifest create ${scratchManifest}
        buildah manifest add ${scratchManifest} ${scratchUrl on.pkgs.system}
        buildah manifest add ${scratchManifest} ${scratchUrl off.pkgs.system}
        buildah manifest push ${scratchManifest}
      '';
}
