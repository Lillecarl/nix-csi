{
  fetchFromGitHub,
  buildPythonPackage,
  setuptools-scm,
  aiofile,
  anyio
}:
let
  pname = "aiopath";
  version = "0.7.1";
in
buildPythonPackage {
  inherit pname version;
  src = fetchFromGitHub {
    owner = "alexdelorenzo";
    repo = "aiopath";
    rev = "v${version}";
    sha256 = "sha256-4/LAS2k01YMHqrhI+f27/NE7RiNPgIH/t/14/Y6zyJY=";
  };
  pyproject = true;
  nativeBuildInputs = [ setuptools-scm ];
  propagatedBuildInputs = [
    aiofile
    anyio
  ];
}
