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

  # kubenix is only published as a flake :(
  flake-compatish = import (
    builtins.fetchTree {
      type = "github";
      owner = "lillecarl";
      repo = "flake-compatish";
      ref = "main";
    }
  );
  flake = flake-compatish ./.;

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

  # kubenix evaluation
  kubenixEval = flake.inputs.kubenix.evalModules.${builtins.currentSystem} {
    module = _: {
      imports = [
        ./kubenix
        {
          config.dsImage = dsImage.imageRefUnsafe;
        }
      ];
    };
  };
  manifestYAML = kubenixEval.config.kubernetes.resultYAML;
  manifestJSON = kubenixEval.config.kubernetes.result;

  # dinix evaluation for daemonset
  dsDinix = import ./nix/dsImage/dinixEval.nix { inherit pkgs dinix nix-csi; };
  # script to build daemonset image
  dsImage = import ./nix/dsImage {
    inherit pkgs dinix nix-csi;
    inherit (n2c.nix2container) buildImage;
  };
  dsImageCopy = copyToContainerd dsImage;

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
    ];
  };
  inherit pkgs;
}
