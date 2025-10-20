self: pkgs: {
  # Overlay lib
  lib = pkgs.lib.extend (import ../lib);

  # execline script that takes NIX_STATE_DIR as first and second arg, then
  # storepaths as consecutive args. Dumps nix database one NIX_STATE_DIR and
  # imports it into another NIX_STATE_DIR database
  nix_init_db =
    pkgs.writeScriptBin "nix_init_db" # execline
      ''
        #! ${self.lib.getExe' pkgs.execline "execlineb"} -s1
        emptyenv -p
        pipeline { nix-store --dump-db $@ }
        export USER nobody
        export NIX_STATE_DIR $1
        exec nix-store --load-db
      '';

  asyncache = pkgs.python3Packages.callPackage ./asyncache.nix { };
  python-jsonpath = pkgs.python3Packages.callPackage ./python-jsonpath.nix { };
  kr8s = pkgs.python3Packages.callPackage ./kr8s.nix { inherit (self) asyncache python-jsonpath; };
}
