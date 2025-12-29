let
  inputs =
    (
      let
        lockFile = builtins.readFile ./flake.lock;
        lockAttrs = builtins.fromJSON lockFile;
        fcLockInfo = lockAttrs.nodes.flake-compatish.locked;
        fcSrc = builtins.fetchTree fcLockInfo;
        flake-compatish = import fcSrc;
      in
      flake-compatish ./.
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
  inherit pkgs;
  lib = pkgs.lib;

  easykubenix = import inputs.easykubenix;
  kubenixApply = kubenixInstance { };
  kubenixCI = kubenixInstance {
    module.imports = [ ./kubenix/ci ];
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

  pypkgs = (
    pypkgs: with pypkgs; [
      pkgs.nix-csi
      pkgs.csi-proto-python
      pkgs.kr8s
    ]
  );
  python = pkgs.python3.withPackages pypkgs;
  xonsh = pkgs.xonsh.override {
    extraPackages = pypkgs;
  };
  # env to add to PATH with direnv
  repoenv = pkgs.buildEnv {
    name = "repoenv";
    paths = [
      python
      xonsh
      pkgs.cachix
      pkgs.pyright
      pkgs.ruff
      pkgs.kluctl
      pkgs.stern
      pkgs.kubectx
      pkgs.skopeo
      pkgs.regctl
    ];
  };

  push =
    pkgs.writeScriptBin "push" # bash
      ''
        #! ${pkgs.runtimeShell}
        export PATH=${lib.makeBinPath [ pkgs.cachix ]}:$PATH
        cachix push nix-csi ${kubenixPush.manifestJSONFile}
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

  integrationTest =
    pkgs.writeScriptBin "integrationTest" # bash
      ''
        #! ${pkgs.runtimeShell}
        set -euo pipefail
        export PATH=${
          lib.makeBinPath [
            pkgs.kubectl
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.jq
          ]
        }:$PATH

        echo "=== Running nix-csi integration tests ==="

        # Check that ctest pods are running
        echo "Checking ctest pods..."
        CTEST_PODS=$(kubectl get pods -n nix-csi -l app=ctest -o json | jq -r '.items | length')
        if [ "$CTEST_PODS" -eq 0 ]; then
          echo "ERROR: No ctest pods found"
          exit 1
        fi
        echo "Found $CTEST_PODS ctest pod(s)"

        # Get a ctest pod name
        POD_NAME=$(kubectl get pods -n nix-csi -l app=ctest -o jsonpath='{.items[0].metadata.name}')
        echo "Testing with pod: $POD_NAME"

        # Verify /nix mount exists
        echo "Verifying /nix mount exists..."
        if ! kubectl exec -n nix-csi "$POD_NAME" -- test -d /nix/store; then
          echo "ERROR: /nix/store directory not found in pod"
          exit 1
        fi
        echo "✓ /nix/store mount verified"

        # Verify the binary from ctest works
        echo "Verifying ctest binary is accessible..."
        if ! kubectl exec -n nix-csi "$POD_NAME" -- which big-binary; then
          echo "ERROR: big-binary not found in PATH"
          exit 1
        fi
        echo "✓ Binary found in PATH"

        # Verify we can list Nix store contents
        echo "Verifying Nix store contents..."
        STORE_ITEMS=$(kubectl exec -n nix-csi "$POD_NAME" -- sh -c "ls /nix/store | wc -l")
        if [ "$STORE_ITEMS" -lt 1 ]; then
          echo "ERROR: Nix store appears empty"
          exit 1
        fi
        echo "✓ Found $STORE_ITEMS items in Nix store"

        # Check CSI driver registration
        echo "Verifying CSI driver registration..."
        if ! kubectl get csidrivers nix.csi.store; then
          echo "ERROR: CSI driver not registered"
          exit 1
        fi
        echo "✓ CSI driver registered"

        # Check node pods are running
        echo "Verifying node pods..."
        NODE_PODS=$(kubectl get pods -n nix-csi -l app.kubernetes.io/name=csi -o json | jq -r '.items | length')
        if [ "$NODE_PODS" -eq 0 ]; then
          echo "ERROR: No CSI node pods found"
          exit 1
        fi
        echo "✓ Found $NODE_PODS CSI node pod(s)"

        # Check cache pod is running
        echo "Verifying cache pod..."
        CACHE_PODS=$(kubectl get pods -n nix-csi -l app.kubernetes.io/name=cache -o json | jq -r '.items | length')
        if [ "$CACHE_PODS" -eq 0 ]; then
          echo "ERROR: No cache pods found"
          exit 1
        fi
        echo "✓ Found $CACHE_PODS cache pod(s)"

        echo ""
        echo "=== All integration tests passed! ==="
      '';
}
