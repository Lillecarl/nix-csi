{
  fetchFromGitHub,
  buildPythonPackage,
  setuptools-scm,
  oscrypto,
}:
let
  pname = "certbuilder";
  version = "0.14.2";
in
buildPythonPackage {
  inherit pname version;
  src = fetchFromGitHub {
    owner = "wbond";
    repo = "certbuilder";
    rev = "103855a967d5e8469e432a69c5fe07f08c6d2b89";
    sha256 = "sha256-AEhMSebPiXg7+nrhPfxi94e9/Qny4XSUcYEdS2oaYUY=";
  };
  pyproject = true;
  nativeBuildInputs = [ setuptools-scm ];
  propagatedBuildInputs = [
    oscrypto
  ];
}
