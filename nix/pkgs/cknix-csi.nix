{
  buildPythonApplication,
  setuptools-scm,
  csi-proto-python,
  kubectl,
  util-linux,
  sh,
  uutils-coreutils-noprefix,
  nix_init_db,
  rsync,
}:
let
  pname = "cknix-csi";
  version = "0.1.0";
in
buildPythonApplication {
  inherit pname version;
  src = ../..;
  pyproject = true;
  nativeBuildInputs = [ setuptools-scm ];
  propagatedBuildInputs = [
    rsync
    uutils-coreutils-noprefix
    nix_init_db
    sh
    csi-proto-python
    kubectl
    util-linux
  ];
}
