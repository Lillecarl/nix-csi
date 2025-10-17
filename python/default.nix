{
  buildPythonApplication,
  setuptools-scm,
  csi-proto-python, # CSI GRPC bindings
  util-linuxMinimal, # mount, umount
  uutils-coreutils-noprefix, # ln
  rsync, # hardlinking
  nix_init_db, # Import from one nix DB to another
}:
let
  pname = "nix-csi";
  version = "0.1.0";

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
