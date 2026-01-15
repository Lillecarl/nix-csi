let
  inputs =
    (
      let
        lock = builtins.fromJSON (builtins.readFile ./flake.lock);
        flake-compatish = import (builtins.fetchTree lock.nodes.flake-compatish.locked);
      in
      flake-compatish {
        source = ./.;
        overrides = {
          self = ./.;
        };
      }
    ).inputs;
in
{
  system ? builtins.currentSystem,
  pkgs ? import inputs.nixpkgs {
    inherit system;
    overlays = [ (import ./pkgs) ];
  },
}:
rec {
  inherit inputs pkgs;
  lib = pkgs.lib;

  easykubenix = import inputs.easykubenix;

  kubenixApply = kubenixInstance { };
  kubenixCI1 = kubenixInstance {
    module.imports = [
      ./kubenix/ci
      {
        nix-csi.cache.enable = true;
        nix-csi.builders.enable = true;
      }
    ];
  };
  kubenixCI2 = kubenixInstance {
    module.imports = [
      ./kubenix/ci
      {
        nix-csi.cache.enable = false;
        nix-csi.builders.enable = false;
      }
    ];
  };
  kubenixLocal = kubenixInstance {
    module.imports = [
      ./kubenix/ci
      (
        { config, ... }:
        {
          kluctl.preDeployScript = # bash
            ''
              expected_context="kind"
              current_context=$(kubectl config current-context)

              if [[ "$current_context" != *"$expected_context" ]]; then
                  echo "Warning: Current context is $current_context, not *$expected_context"* >&2
                  read -rp "Continue anyway? [y/N] " confirm
                  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                      echo "Aborted." >&2
                      exit 1
                  fi
              fi
              cachix push nix-csi ${config.internal.manifestJSONFile}
            '';
          nix-csi.cache.enable = true;
          nix-csi.builders.enable = true;
          nix-csi.push = true;
        }
      )
    ];
  };
  kubenixPush = kubenixInstance {
    module.config = {
      nix-csi.push = true;
    };
  };
  kubenixInstance =
    {
      module ? { },
    }:
    easykubenix {
      inherit pkgs;
      modules = [
        module
        ./kubenix
        {
          _module.args.inputs = inputs;
        }
        {
          config = {
            # Disabled by default so you can include the module in an easykubenix project
            nix-csi.enable = true;
            # Allow easily adding your pubkeys to the cache
            nix-csi.authorizedKeys = lib.pipe (lib.filesystem.listFilesRecursive ./keys) [
              (lib.filter (name: lib.hasSuffix ".pub" name))
              (lib.map (name: builtins.readFile name))
              (lib.map (key: lib.trim key))
            ];
          };
        }
      ];
    };

  push =
    pkgs.writeScriptBin "push" # bash
      ''
        #! ${pkgs.runtimeShell}
        export PATH=${lib.makeBinPath [ pkgs.cachix ]}:$PATH
        # ${lib.concatStrings (lib.attrValues inputs)}
        nix-store -qR --include-outputs $(nix-store -qd ${kubenixPush.manifestJSONFile}) | grep -v '\.drv$' | cachix push nix-csi
      '';

  uploadScratch =
    let
      scratchVersion = "1.0.1";
      scratchUrl = system: "ghcr.io/lillecarl/nix-csi/scratch:${scratchVersion}-${system}";
      scratchManifest = "ghcr.io/lillecarl/nix-csi/scratch:${scratchVersion}";
    in
    pkgs.writeScriptBin "uploadScratch" # bash
      ''
        #! ${pkgs.runtimeShell}
        set -euo pipefail
        set -x
        export PATH=${lib.makeBinPath [ pkgs.buildah ]}:$PATH
        # Build and publish scratch image(s)
        buildah login -u="$REPO_USERNAME" -p="$REPO_TOKEN" ghcr.io
        container=$(buildah from --platform linux/amd64 scratch)
        buildah config --env "PATH=/nix/var/result/bin" $container
        buildah commit $container ${scratchUrl "x86_64-linux"}
        buildah push ${scratchUrl "x86_64-linux"}
        container=$(buildah from --platform linux/arm64 scratch)
        buildah config --env "PATH=/nix/var/result/bin" $container
        buildah commit $container ${scratchUrl "aarch64-linux"}
        buildah push ${scratchUrl "aarch64-linux"}
        buildah manifest rm ${scratchManifest} &>/dev/null || true
        buildah manifest create ${scratchManifest}
        buildah manifest add ${scratchManifest} ${scratchUrl "x86_64-linux"}
        buildah manifest add ${scratchManifest} ${scratchUrl "aarch64-linux"}
        buildah manifest push ${scratchManifest}
      '';
  genModDoc =
    let
      optionsDocs = pkgs.nixosOptionsDoc {
        inherit (kubenixCI1.eval) options;
        warningsAreErrors = false;
        transformOptions =
          opt:
          opt
          // {
            # Remove internal options, modify declarations, etc.
            visible = opt.visible or true && lib.hasPrefix "nix-csi" opt.name;
          };
      };
    in
    pkgs.writeScriptBin "genModDoc" # bash
      ''
        #! ${pkgs.runtimeShell}
        cp --no-preserve=mode ${optionsDocs.optionsCommonMark} $GIT_ROOT/doc/options.md
      '';

  lixImage = pkgs.callPackage ./liximage.nix { };
  scratchImage = pkgs.callPackage ./scratchimage.nix { };
}
