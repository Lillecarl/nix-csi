{ lib
, buildPythonPackage
, fetchFromGitHub
, grpcio-tools
, protobuf
, python
, pythonRelaxDepsHook
}:
let
  version = "1.11.0";
in
buildPythonPackage {
  inherit version;
  pname = "csi-proto-python";

  src = fetchFromGitHub {
    owner = "container-storage-interface";
    repo = "spec";
    rev = "v${version}"; # Update as needed
    sha256 = "sha256-mDvlHB2vVqJIQO6y2UJlDohzHUbCvzJ9hJc7XFAbFb0=";
  };

  nativeBuildInputs = [
    grpcio-tools
    protobuf
    pythonRelaxDepsHook
  ];

  propagatedBuildInputs = [
    grpcio-tools
    protobuf
  ];

  # There's no setup.py, so we use a custom buildPhase and installPhase
  format = "other";
  buildPhase = ''
    export OUTDIR="$TMPDIR/csi"
    mkdir -p "$OUTDIR"
    cd $src
    python -m grpc_tools.protoc \
      -I. \
      --python_out="$OUTDIR" \
      --grpc_python_out="$OUTDIR" \
      csi.proto
    touch "$OUTDIR/__init__.py"
  '';

  installPhase = ''
    moddir="$out/${python.sitePackages}/csi"
    mkdir -p "$moddir"
    cp $TMPDIR/csi/*.py "$moddir/"
  '';

  meta = with lib; {
    description = "Python gRPC/protobuf library for Kubernetes CSI spec";
    homepage = "https://github.com/container-storage-interface/spec";
    license = licenses.asl20;
    platforms = platforms.all;
  };
}
