self: pkgs: {
  # Overlay lib
  lib = pkgs.lib.extend (import ../lib);

  # First argument is NIX_STATE_DIR which is where we init the dumped database
  nix_init_db =
    pkgs.writeScriptBin "nix_init_db" # bash
      ''
        #! ${pkgs.runtimeShell}
        NSD="$1"
        shift
        export USER nobody
        nix-store --option store local --dump-db "$@" | NIX_STATE_DIR="$NSD" nix-store --load-db --option store local
      '';

  nix-csi = self.csi-root.csi;
  nix-cache = self.csi-root.cache;
  nix-timegc = self.csi-root.timegc;
  csi-root = pkgs.python3Packages.callPackage ../python {
    inherit (self) csi-proto-python kr8s;
  };

  lixPackageSets.lix_2_93 = pkgs.lixPackageSets.lix_2_93.overrideScope (
    setSelf: set: {
      lix = set.lix.overrideAttrs (oldAttrs: {
        patches = (oldAttrs.patches or [ ]) ++ [
          (pkgs.fetchpatch {
            url = "https://github.com/Lillecarl/lix/commit/9ac72bbd0c7802ca83a907d1fec135f31aab6d24.patch";
            hash = "sha256-NLyURqjzbyftbjxwOGWW26jcLRtvvE0hdIriiYEnQ4Q=";
          })
        ];
        doCheck = false;
        doInstallCheck = false;
      });
    }
  );

  csi-proto-python = pkgs.python3Packages.callPackage ./csi-proto-python { };
  python-jsonpath = pkgs.python3Packages.callPackage ./python-jsonpath.nix { };
  kr8s = pkgs.python3Packages.callPackage ./kr8s.nix { inherit (self) python-jsonpath; };
}
