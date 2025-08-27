{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  pythonOlder,
  # Dependencies
  poetry-core,
  cachetools,
  # Test dependencies
  pytestCheckHook,
  pytest-asyncio,
}:

buildPythonPackage rec {
  pname = "asyncache";
  version = "unstable-2023-12-04";
  format = "pyproject";

  disabled = pythonOlder "3.7";

  src = fetchFromGitHub {
    owner = "hephex";
    repo = "asyncache";
    rev = "master";
    hash = "sha256-qNPAgVBj3w9sgymM9pw1QW56bhf2zc1cpe3hBUaAApc=";
  };

  nativeBuildInputs = [
    poetry-core
  ];

  propagatedBuildInputs = [
    cachetools
  ];

  nativeCheckInputs = [
    pytestCheckHook
    pytest-asyncio
  ];

  pythonImportsCheck = [
    "asyncache"
  ];

  meta = with lib; {
    description = "Helpers to use cachetools with async functions";
    homepage = "https://github.com/hephex/asyncache";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
    platforms = platforms.unix;
  };
}