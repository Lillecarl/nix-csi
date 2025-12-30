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
  pkgs = import inputs.nixpkgs {
    overlays = [
      (import ./pkgs)
    ];
  };
  inherit (pkgs) lib;
  server = "ghcr.io";
  repo = "${server}/lillecarl/nix-csi";
in
rec {
  inherit inputs pkgs;
  images = lib.genAttrs [ "aarch64-linux" "x86_64-linux" ] (
    system:
    let
      pkgs = import inputs.nixpkgs { inherit system; };
      inherit (pkgs) lib;
      initCopy =
        pkgs.writeScriptBin "initCopy" # bash
          ''
            #! ${pkgs.runtimeShell}
            export PATH=${
              lib.makeBinPath [
                pkgs.coreutils
                pkgs.gitMinimal
                pkgs.lixPackageSets.lix_2_93.lix
                pkgs.rsync
                pkgs.openssh
              ]
            }
            set -x
            rsync --archive ${
              pkgs.dockerTools.fakeNss.override {
                extraGroupLines = [
                  "nixbld:x:30000:"
                ];
              }
            }/ /
            mkdir /tmp
            export ARCH=$(nix eval --raw --impure --expr builtins.currentSystem)
            case "$ARCH" in
              "x86_64-linux")
                export ARCH=amd64
              ;;
              "aarch64-linux")
                export ARCH=arm64
              ;;
            esac
            nix \
              build \
                --max-jobs auto \
                --option sandbox false \
                --store /nix-volume \
                --out-link /nix-volume/nix/var/result \
                --fallback \
                ''${!ARCH}
          '';
    in
    pkgs.dockerTools.streamLayeredImage {
      name = "${repo}/lix";
      tag = "${pkgs.lixPackageSets.lix_2_93.lix.version}-${pkgs.stdenv.hostPlatform.system}";
      maxLayers = 125;
      includeNixDB = true;
      contents = [
        pkgs.dockerTools.binSh
        pkgs.dockerTools.caCertificates
        pkgs.dockerTools.usrBinEnv
      ];
      config = {
        Entrypoint = [ (lib.getExe initCopy) ];
      };
    }
  );
  push =
    let
      copyToRegistry = arch: "${images.${arch}} | gzip --fast | skopeo copy docker-archive:/dev/stdin docker://${imageRef arch}";
      imageRef = arch: "${images.${arch}.imageName}:${images.${arch}.imageTag}";
    in
    pkgs.writeScriptBin "push" # bash
      ''
        #! ${pkgs.runtimeShell}
        export PATH=${lib.makeBinPath [ pkgs.regctl pkgs.skopeo pkgs.gz-utils]}:$PATH
        skopeo login -u="$REPO_USERNAME" -p="$REPO_TOKEN" ${server}
        regctl registry login -u="$REPO_USERNAME" -p="$REPO_TOKEN" ${server}
        ${copyToRegistry "aarch64-linux"}
        ${copyToRegistry "x86_64-linux"}
        regctl index create ${repo}/lix:${pkgs.lixPackageSets.lix_2_93.lix.version} \
          --ref ${imageRef "aarch64-linux"} \
          --ref ${imageRef "x86_64-linux"}
        regctl index create ${repo}/lix:latest \
          --ref ${imageRef "aarch64-linux"} \
          --ref ${imageRef "x86_64-linux"}
      '';
}
