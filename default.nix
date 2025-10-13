{
  # Do a dance where we try to use NIX_PATH if it exists.
  pkgs ?
    let
      ft = import (builtins.fetchTree {
        type = "github";
        owner = "NixOS";
        repo = "nixpkgs";
        ref = "nixos-unstable";
      }) { };
      np = import <nixpkgs> { };
      npt = builtins.tryEval np;
    in
    if npt.success then npt.value else ft,
}:
let
  lib = pkgs.lib;

  dinix = /home/lillecarl/Code/dinix;

  n2cSrc = builtins.fetchTree {
    type = "github";
    owner = "nlewo";
    repo = "nix2container";
    ref = "master";
  };
in
rec {
  n2c = import n2cSrc {
    inherit pkgs;
    system = builtins.currentSystem;
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
          image = image.imageRefUnsafe;
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
            oci-archive:''${fifo}:docker.io/library/${image.imageRefUnsafe}
        }
        export CONTAINERD_ADDRESS /run/k3s/containerd/containerd.sock

        foreground {
          sudo -E ${lib.getExe pkgs.nerdctl}
            --namespace k8s.io
            load --input ''${fifo}
        }
        rm ''${fifo}
      '';

  kluctlProject = dinixEval.pkgs.writeMultipleFiles {
    name = "kluctlproject";
    files = {
      ".kluctl.yaml" = {
        content = # yaml
          ''
            targets:
              - name: local
          '';
      };
      "deployment.yaml" = {
        content = # yaml
          ''
            deployments:
              - path: manifests
          '';
      };
      "manifests/kubenix.yaml" = {
        content = builtins.toJSON kubenixEval.config.kubernetes.generated;
      };
    };
  };

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
        ${lib.getExe pkgs.kluctl} deploy --target local --discriminator ${kubenixEval.config.kubenix.project} --project-dir ${kluctlProject} $argv
      '';

  # simpler than devshell
  python = pkgs.python3.withPackages (
    pypkgs: with pypkgs; [
      nix-csi
      csi-proto-python
      grpclib
      sh
    ]
  );
  # env to add to PATH with direnv
  repoenv = pkgs.buildEnv {
    name = "repoenv";
    paths = [
      python
      n2c.skopeo-nix2container
      pkgs.kluctl
    ];
  };
  inherit pkgs;
}
