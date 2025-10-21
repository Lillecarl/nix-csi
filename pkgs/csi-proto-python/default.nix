{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  grpcio-tools,
  grpcio,
  grpclib,
  protobuf,
  mypy-protobuf,
  python,
  pythonRelaxDepsHook,
}:
let
  version = "1.11.0";
  spec = fetchFromGitHub {
    owner = "container-storage-interface";
    repo = "spec";
    rev = "v${version}";
    sha256 = "sha256-mDvlHB2vVqJIQO6y2UJlDohzHUbCvzJ9hJc7XFAbFb0=";
  };
in
buildPythonPackage {
  inherit version;
  pname = "csi-proto-python";

  src = ./.;

  # src = fetchFromGitHub {
  #   owner = "container-storage-interface";
  #   repo = "spec";
  #   rev = "v${version}"; # Update as needed
  #   sha256 = "sha256-mDvlHB2vVqJIQO6y2UJlDohzHUbCvzJ9hJc7XFAbFb0=";
  # };

  # src = ../../../spec;

  buildInputs = [
    # protobuf
    # mypy-protobuf
    # grpcio-tools
  ];

  nativeBuildInputs = [
    # protobuf
    grpclib
    mypy-protobuf
    grpcio-tools
  ];

  propagatedBuildInputs = [
    # protobuf
    grpclib
    # grpcio
    mypy-protobuf
  ];

  # There's no setup.py, so we use a custom buildPhase and installPhase
  format = "pyproject";
  preBuild = ''
    mkdir -p src/csi
    # python -m grpc_tools.protoc \
    #   --proto_path="${spec}" \
    #   --python_out="src/csi" \
    #   --grpc_python_out="src/csi" \
    #   --mypy_out="src/csi" \
    #   csi.proto
    protoc \
      --proto_path="${spec}" \
      --python_out="src/csi" \
      --grpclib_python_out="src/csi" \
      --mypy_out="src/csi" \
      csi.proto

    substituteInPlace src/csi/csi_grpc.py \
      --replace-fail "import csi_pb2" "from . import csi_pb2"
  '';

  meta = with lib; {
    description = "Python gRPC/protobuf library for Kubernetes CSI spec";
    homepage = "https://github.com/container-storage-interface/spec";
    license = licenses.asl20;
    platforms = platforms.all;
  };
}
