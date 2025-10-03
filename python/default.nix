{
  buildPythonApplication,
  setuptools-scm,
  csi-proto-python, # CSI GRPC bindings
  util-linuxMinimal, # mount, umount
  uutils-coreutils-noprefix, # ln
  rsync, # hardlinking
  execline, # easier "shell" operations than python subprocess API
  writeScriptBin, # create shebanged scripts
  lib, # getExe/getExe'
}:
let
  pname = "nix-csi";
  version = "0.1.0";

  # execline script that takes NIX_STATE_DIR as first arg and storepaths
  # as consecutive args. Dumps nix database and imports it into NIX_STATE_DIR database
  nix_init_db =
    writeScriptBin "nix_init_db" # execline
      ''
        #! ${lib.getExe' execline "execlineb"} -s1
        emptyenv -p
        pipeline { nix-store --dump-db $@ }
        export USER nobody
        export NIX_STATE_DIR $1
        exec nix-store --load-db
      '';
in
buildPythonApplication {
  inherit pname version;
  src = ./.;
  pyproject = true;
  nativeBuildInputs = [ setuptools-scm ];
  propagatedBuildInputs = [
    rsync
    uutils-coreutils-noprefix
    nix_init_db
    csi-proto-python
    util-linuxMinimal
  ];
  meta.mainProgram = "nix-csi";
  passthru = {
    inherit nix_init_db;
  };
}
