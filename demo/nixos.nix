{
  pkgs ? import <nixpkgs> { },
}:
let
  lib = pkgs.lib;
  # You can use flakes, npins, niv, fetchTree, fetchFromGitHub or whatever.
  easykubenix = builtins.fetchTree {
    type = "github";
    owner = "lillecarl";
    repo = "easykubenix";
  };
  nixos = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    inherit pkgs;
    modules = [
      (
        {
          config,
          pkgs,
          lib,
          ...
        }:
        {
          boot.isContainer = true;
          boot.specialFileSystems = lib.mkForce { };
          services.journald.console = "/dev/stderr";
          networking.resolvconf.enable = false;
          environment.etc.hostname.enable = lib.mkForce false;
          environment.etc.hosts.enable = lib.mkForce false;
          system.stateVersion = "25.05";
        }
      )
    ];
  };
  ekn = import easykubenix {
    inherit pkgs;
    modules = [
      {
        kluctl = {
          discriminator = "demodeploy"; # Used for kluctl pruning (removing resources not in generated manifests)
          pushManifest = {
            enable = true; # Push manifest (which depends on pkgs.hello) before deploying
            to = "ssh://root@192.168.88.20"; # Shouldn't be root but here we are currently, maybe shouldn't be a module option either?
            failCachePush = true;
          };
        };
        kubernetes.resources.none.Pod.nixos.spec = {
          automountServiceAccountToken = false;
          containers = {
            _namedlist = true; # This is a meta thing to use attrsets instead of lists
            hello = {
              image = "quay.io/nix-csi/scratch:1.0.1"; # 1.0.1 sets PATH to /nix/var/result/bin
              command = [
                "/nix/var/result/init"
                "--system"
                "--log-level=debug"
                "--log-target=console"
              ];
              volumeMounts = {
                _namedlist = true;
                nix.mountPath = "/nix";
                run.mountPath = "/run";
                tmp.mountPath = "/tmp";
                cgroup.mountPath = "/sys/fs/cgroup";
              };
              env = {
                _namedlist = true;
                container.value = "1";
              };
            };
          };
          volumes = {
            _namedlist = true;
            run.emptyDir.medium = "Memory";
            tmp.emptyDir.medium = "Memory";
            cgroup.hostPath.path = "/sys/fs/cgroup";
            nix.csi = {
              driver = "nix.csi.store";
              volumeAttributes.${pkgs.system} = pkgs.buildEnv {
                name = "initenv";
                paths = [
                  pkgs.fish
                  pkgs.bash
                  nixos.config.system.build.toplevel
                  # (pkgs.writeScriptBin "init" # bash
                  #   ''
                  #     #! ${pkgs.runtimeShell}
                  #     export PATH=${
                  #       lib.makeBinPath [
                  #         pkgs.coreutils
                  #         pkgs.util-linuxMinimal
                  #       ]
                  #     }:$PATH
                  #     set -x
                  #     export container=1
                  #     source ${nixos.config.system.build.toplevel}/init
                  #   ''
                  # )
                ];
              };
            };
          };
        };
      }
    ];
  };
in
ekn // { inherit nixos; }
