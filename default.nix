{
  pkgs ?
    let
      ft = import (builtins.fetchTree {
        type = "github";
        repo = "nixpkgs";
        owner = "NixOS";
        ref = "nixos-unstable";
      }) { };
      np = import <nixpkgs> { };
      npt = builtins.tryEval np;
    in
    if npt.success then npt.value else ft,
}:
let
  lib = pkgs.lib;

  # kubenix is only published as a flake :(
  flake-compatish = import (
    builtins.fetchGit {
      url = "https://github.com/lillecarl/flake-compatish.git";
      ref = "main";
    }
  );
  flake = flake-compatish ./.;

  dinixSrc = builtins.fetchTree {
    type = "git";
    url = "https://github.com/Lillecarl/dinix.git";
  };
  n2cSrc = builtins.fetchTree {
    type = "git";
    url = "https://github.com/nlewo/nix2container.git";
  };
in
rec {
  n2c = import n2cSrc {
    inherit pkgs;
    system = builtins.currentSystem;
  };
  csi-proto-python = pkgs.python3Packages.callPackage ./nix/pkgs/csi-proto-python/default.nix { };
  nix-csi = pkgs.python3Packages.callPackage ./nix/pkgs/nix-csi.nix {
    inherit csi-proto-python;
  };
  dinixEval = (
    import dinixSrc {
      inherit pkgs;
      modules = [
        {
          config = {
            services.boot.depends-on-d = [ "nix-csi" ];
            services.nix-csi = {
              command = lib.getExe nix-csi;
            };
          };
        }
      ];
    }
  );

  # kubenix evaluation
  kubenixEval = flake.inputs.kubenix.evalModules.${builtins.currentSystem} {
    module = _: {
      imports = [
        ./kubenix
        {
          config.image = containerImage.imageRefUnsafe;
        }
      ];
    };
  };
  manifestYAML = kubenixEval.config.kubernetes.resultYAML;
  manifestJSON = kubenixEval.config.kubernetes.result;

  nixUserGroupShadow =
    let
      shell = lib.getExe pkgs.fish;
    in
    ((import ./nix/dockerUtils.nix pkgs).nonRootShadowSetup {
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
  # script to build container image
  containerImage = pkgs.callPackage ./nix/pkgs/containerimage.nix {
    inherit dinixEval nixUserGroupShadow;
    inherit (n2c.nix2container) buildImage;
  };

  copyToContainerd =
    pkgs.writeScriptBin "copyToContainerd" # fish
      ''
        #! ${lib.getExe pkgs.fish}
        set archivedir $(mktemp -d)
        set --export CONTAINERD_ADDRESS /run/containerd/containerd.sock
        ${lib.getExe n2c.skopeo-nix2container} --insecure-policy copy nix:${containerImage} oci-archive:$archivedir/archive.tar:docker.io/library/${containerImage.imageRefUnsafe}
        sudo -E ${lib.getExe' pkgs.containerd "ctr"} --namespace k8s.io images import $archivedir/archive.tar
        rm -r $archivedir
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
