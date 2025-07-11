{
  buildPythonPackage,
  buildPythonApplication,
  setuptools-scm,
  kopf,
  csi-proto-python,
  kubectl,
  util-linux,
  rsync,
  aiopath,
  aiosqlite,
}:
let
  pname = "knix-csi";
  version = "0.1.0";
in
buildPythonApplication {
  inherit pname version;
  src = ../..;
  pyproject = true;
  nativeBuildInputs = [ setuptools-scm ];
  propagatedBuildInputs = [
    kopf
    csi-proto-python
    kubectl
    util-linux
    rsync
    aiopath
    aiosqlite
  ];
}
