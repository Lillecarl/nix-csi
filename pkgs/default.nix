_: pkgs:
let
  inherit (pkgs) lib;
in
{
  # Overlay lib
  lib = pkgs.lib.extend (import ../lib);

  # execline script that takes NIX_STATE_DIR as first and second arg, then
  # storepaths as consecutive args. Dumps nix database one NIX_STATE_DIR and
  # imports it into another NIX_STATE_DIR database
  nix_init_db =
    pkgs.writeScriptBin "nix_init_db" # execline
      ''
        #! ${lib.getExe' pkgs.execline "execlineb"} -s1
        emptyenv -p
        pipeline { nix-store --dump-db $@ }
        export USER nobody
        export NIX_STATE_DIR $1
        exec nix-store --load-db
      '';
}
