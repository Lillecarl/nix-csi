{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule rec {
  pname = "shell-operator";
  version = "1.8.1";

  src = fetchFromGitHub {
    owner = "flant";
    repo = "shell-operator";
    rev = "v${version}";
    hash = "sha256-mNZTPV4IrLFV0qcrNMBiBRB1WaNFpAkz6jpwRqwp86Q=";
  };

  vendorHash = "sha256-8+ordY/g90saLAsRqK9xHown+NbgD+2WljiKwxMeu9s=";

  ldflags = [
    "-s"
    "-w"
    "-X github.com/flant/shell-operator/pkg/app.Version=${version}"
  ];

  # Disable tests that require Kubernetes cluster
  doCheck = false;

  meta = with lib; {
    description = "Tool for running event-driven scripts in a Kubernetes cluster";
    homepage = "https://github.com/flant/shell-operator";
    license = licenses.asl20;
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = "shell-operator";
  };
}