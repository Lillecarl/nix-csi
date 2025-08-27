{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  pythonOlder,
  # Build dependencies
  hatchling,
  hatch-vcs,
  # Dependencies
  asyncache,
  cryptography,
  exceptiongroup,
  pyyaml,
  python-jsonpath,
  anyio,
  httpx,
  httpx-ws,
  python-box,
  typing-extensions,
  # Test dependencies
  pytestCheckHook,
  pytest-asyncio,
  pytest-timeout,
  pytest-rerunfailures,
  pytest-cov,
  trio,
}:

buildPythonPackage rec {
  pname = "kr8s";
  version = "0.20.9";
  format = "pyproject";

  disabled = pythonOlder "3.8";

  src = fetchFromGitHub {
    owner = "kr8s-org";
    repo = "kr8s";
    rev = "refs/tags/v${version}";
    hash = "sha256-zN9Miqs1rputwRoelLnFgGk2oQmx1gioott0PpzI2JQ=";
  };

  nativeBuildInputs = [
    hatchling
    hatch-vcs
  ];

  propagatedBuildInputs = [
    asyncache
    cryptography
    pyyaml
    python-jsonpath
    anyio
    httpx
    httpx-ws
    python-box
    typing-extensions
  ] ++ lib.optionals (pythonOlder "3.12") [
    exceptiongroup
  ];

  nativeCheckInputs = [
    pytestCheckHook
    pytest-asyncio
    pytest-timeout
    pytest-rerunfailures
    pytest-cov
    trio
  ];

  pythonImportsCheck = [
    "kr8s"
  ];

  # Disable all tests as they require a Kubernetes cluster
  doCheck = false;

  meta = with lib; {
    description = "A batteries-included Python client library for Kubernetes that feels familiar for folks who already know how to use kubectl";
    homepage = "https://github.com/kr8s-org/kr8s";
    license = licenses.bsd3;
    maintainers = with maintainers; [ ];
    platforms = platforms.unix;
  };
}