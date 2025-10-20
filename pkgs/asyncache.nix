{
  lib,
  buildPythonPackage,
  fetchPypi,
  fetchFromGitHub,
  # dependencies
  cachetools,
  # build-system
  poetry-core,
}:
let
  cachetools600 = cachetools.overrideAttrs rec {
    version = "5.5.2";
    src = fetchFromGitHub {
      owner = "tkem";
      repo = "cachetools";
      tag = "v${version}";
      hash = "sha256-CWgl2UW7+rBXRQ6N/QY3vJiLsrPfmplmQbxPp2vcdU0=";
    };
  };
in
buildPythonPackage rec {
  pname = "asyncache";
  version = "0.3.1";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    sha256 = "sha256-mh5gp1Zo55RldIm96mVA7n4yWcSDUXuTRnDbdgC/UDU=";
  };

  build-system = [
    poetry-core
  ];

  dependencies = [
    cachetools600
  ];

  meta = with lib; {
    description = "Helpers to use cachetools with async functions";
    homepage = "https://github.com/hephex/asyncache";
    license = licenses.mit;
    maintainers = with maintainers; [ lillecarl ];
  };
}
