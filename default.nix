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
            image = imageRef;
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
    imageRef = "bogus.io/${image.imageRefUnsafe}";

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
            sudo -E ${lib.getExe pkgs.nerdctl}
              --namespace k8s.io
              load --input ''${fifo}
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
  };
in
let
  on = persys pkgs;
  off = persys pkgsCross;
in
on
// {
  inherit off;
  upload =
    let
      version = "0.1.0";
      url = system: "quay.io/lillecarl/nix-csi:${version}-${system}";
      manifest = "quay.io/lillecarl/nix-csi:${version}";
    in
    pkgs.writeScriptBin "merge" # fish
      ''
        #! ${lib.getExe pkgs.fishMinimal}
        set buildDir (mktemp -d ocibuild.XXXXXX)
        echo $buildDir
        function cleanup --on-event fish_exit
          rm -rf $buildDir
        end
        ${lib.getExe on.image.copyTo} oci-archive:$buildDir/on:${url on.pkgs.system}
        ${lib.getExe off.image.copyTo} oci-archive:$buildDir/off:${url off.pkgs.system}
        podman load --input $buildDir/on
        podman load --input $buildDir/off
        podman push ${url on.pkgs.system}
        podman push ${url off.pkgs.system}
        podman manifest rm ${manifest}
        podman manifest create ${manifest}
        podman manifest add ${manifest} ${url on.pkgs.system}
        podman manifest add ${manifest} ${url off.pkgs.system}
        podman manifest push ${manifest}
      '';
}
