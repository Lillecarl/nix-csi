{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  pythonOlder,
  # Build dependencies
  hatchling,
  # Test dependencies
  pytestCheckHook,
}:

buildPythonPackage rec {
  pname = "python-jsonpath";
  version = "1.3.1";
  format = "pyproject";

  disabled = pythonOlder "3.8";

  src = fetchFromGitHub {
    owner = "jg-rp";
    repo = "python-jsonpath";
    rev = "refs/tags/v${version}";
    hash = "sha256-DSou9CEitp1zGW4VqO2KcW0rjluxX/4RJAv3/6M+OPM=";
  };

  nativeBuildInputs = [
    hatchling
  ];

  # Tests require additional test data files not included in the tarball
  doCheck = false;

  pythonImportsCheck = [
    "jsonpath"
  ];

  meta = with lib; {
    description = "A more powerful JSONPath implementation in Python";
    homepage = "https://pypi.org/project/python-jsonpath/";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
    platforms = platforms.unix;
  };
}