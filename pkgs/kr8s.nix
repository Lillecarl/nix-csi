{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  # dependencies
  asyncache,
  cryptography,
  exceptiongroup,
  packaging,
  pyyaml,
  python-jsonpath,
  anyio,
  httpx,
  httpx-ws,
  python-box,
  typing-extensions,
  # build-system
  hatchling,
  hatch-vcs,
}:
buildPythonPackage rec {
  pname = "kr8s";
  version = "0.20.10";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "kr8s-org";
    repo = "kr8s";
    tag = "v${version}";
    hash = "sha256-NiCasvS4P9zEh8JUvFAFJBtLfwOaz9jmr17IkeQDjXQ=";
  };

  build-system = [
    hatchling
    hatch-vcs
  ];

  dependencies = [
    asyncache
    cryptography
    exceptiongroup
    packaging
    pyyaml
    python-jsonpath
    anyio
    httpx
    httpx-ws
    python-box
    typing-extensions
  ];

  nativeCheckInputs = [ ];

  pythonImportsCheck = [ "kr8s" ];

  meta = with lib; {
    description = "A Python client library for Kubernetes";
    homepage = "https://github.com/kr8s-org/kr8s";
    license = licenses.mit;
    maintainers = with maintainers; [ lillecarl ];
  };
}
