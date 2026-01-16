{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  # dependencies
  # build-system
  poetry-core,
}:
buildPythonPackage (finalAttrs: {
  pname = "shellous";
  version = "0.39.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "byllyfish";
    repo = "shellous";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Atuj5O8sN5OtMW1+AuJ+eGMOVweYFZsUpPPF+89im7I=";
  };

  build-system = [
    poetry-core
  ];

  dependencies = [
  ];

  pythonImportsCheck = [ "shellous" ];

  meta = with lib; {
    description = "asyncio library that provides an API for running subprocesses";
    homepage = "https://github.com/${finalAttrs.owner}/${finalAttrs.repo}";
    license = licenses.asl20;
    maintainers = with maintainers; [ lillecarl ];
  };
})
