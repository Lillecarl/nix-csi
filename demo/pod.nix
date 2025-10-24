{
  pkgs ? import <nixpkgs> { },
}:
let
  sysMap = {
    "x86_64-linux" = "aarch64-linux";
    "aarch64-linux" = "x86_64-linux";
  };
  pkgsCrossish = import pkgs.path { system = sysMap.${builtins.currentSystem}; };

  # You can use flakes, npins, niv, fetchTree, fetchFromGitHub or whatever.
  easykubenix = builtins.fetchTree {
    type = "github";
    owner = "lillecarl";
    repo = "easykubenix";
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
          };
        };
        kubernetes.resources.none.Pod.hello.spec = {
          containers = {
            _namedlist = true; # This is a meta thing to use attrsets instead of lists
            hello = {
              image = "quay.io/nix-csi/scratch:1.0.1"; # 1.0.1 sets PATH to /nix/var/result/bin
              command = [ "hello" ];
              volumeMounts = {
                _namedlist = true;
                nix.mountPath = "/nix";
              };
            };
          };
          volumes = {
            _namedlist = true;
            nix.csi = {
              driver = "nix.csi.store";
              volumeAttributes.${pkgs.system} = pkgs.hello; # this is stringified into a storepath,
              volumeAttributes.${pkgsCrossish.system} = pkgsCrossish.hello; # this is stringified into a storepath,
              # Now the manifest depends on pkgs.hello so when we push it we bring pkgs.hello and nix-csi can fetch it.
            };
          };
        };
      }
    ];
  };
in
ekn
