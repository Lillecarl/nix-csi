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
              options = [ "shares-console" ];
              depends-on-d = [ "runtimedirs" ];
            };
            services.runtimedirs = {
              type = "scripted";
              command = lib.getExe (
                pkgs.writeScriptBin "setupScript" # fish
                  ''
                    #! ${lib.getExe pkgs.fish}
                    mkdir -p /home/{nix,root}
                    mkdir -p /var/{log,lib,cache}
                    mkdir -p /etc
                    mkdir -p /run
                    mkdir -p /tmp
                    mkdir -p /root
                  ''
              );
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
            nix:${containerImage}
            oci-archive:''${fifo}:docker.io/library/${containerImage.imageRefUnsafe}
        }

        foreground {
          export CONTAINERD_ADDRESS /run/containerd/containerd.sock
          sudo ${lib.getExe pkgs.nerdctl}
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
