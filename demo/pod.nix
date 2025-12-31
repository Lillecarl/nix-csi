let
  inputs =
    (
      let
        lockFile = builtins.readFile ../flake.lock;
        lockAttrs = builtins.fromJSON lockFile;
        fcLockInfo = lockAttrs.nodes.flake-compatish.locked;
        fcSrc = builtins.fetchTree fcLockInfo;
        flake-compatish = import fcSrc;
      in
      flake-compatish ../.
    ).inputs;

  pkgs = import inputs.nixpkgs { };
  sysMap = {
    "x86_64-linux" = "aarch64-linux";
    "aarch64-linux" = "x86_64-linux";
  };
  pkgsCross = import pkgs.path { system = sysMap.${builtins.currentSystem}; };

  package =
    pkgs:
    pkgs.buildEnv {
      name = "demoEnv";
      paths = [
        pkgs.bash
        pkgs.fishMinimal
        pkgs.coreutils
        pkgs.moreutils
        pkgs.lixPackageSets.lix_2_93.lix
      ];
    };

  # You can use flakes, npins, niv, fetchTree, fetchFromGitHub or whatever.
  ekn = import inputs.easykubenix {
    inherit pkgs;
    modules = [
      (
        { lib, ... }:
        {
          kluctl = {
            discriminator = "demodeploy"; # Used for kluctl pruning (removing resources not in generated manifests)
          };
          # Will go into the default namespace
          kubernetes.resources.none.Pod.hello.spec = {
            containers = lib.mkNamedList {
              hello = {
                image = "ghcr.io/lillecarl/nix-csi/scratch:1.0.1"; # 1.0.1 sets PATH to /nix/var/result/bin
                command = [
                  "bash"
                  "-c"
                  "hello;sleep infinity"
                ];
                volumeMounts = lib.mkNamedList {
                  nix.mountPath = "/nix";
                };
              };
            };
            # lib.mkNamedList adds metadata that tells easykubenix to convert the atrributeset
            # into a list of attrset with name attribute set
            volumes = lib.mkNamedList {
              nix.csi = {
                driver = "nix.csi.store";
                # these are stringified into storePaths now the manifest depends
                # on pkgs.hello so when we push it we bring the package environment and nix-csi
                # can fetch it.
                volumeAttributes.${pkgs.stdenv.hostPlatform.system} = package pkgs;
                volumeAttributes.${pkgsCross.stdenv.hostPlatform.system} = package pkgsCross;
              };
            };
          };
        }
      )
    ];
  };
in
ekn
