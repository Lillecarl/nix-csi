{
  buildPythonApplication, # Builder
  hatchling, # Build system
  coreutils, # ln
  cryptography, # ssh-keygen Python
  csi-proto-python, # CSI GRPC bindings
  googleapis-common-protos, # Google Errors
  gitMinimal, # Lix requires Git since it doesn't use libgit2
  kr8s, # Kubernetes API
  shellous, # subprocessing
  lix, # We need a Nix implementation.... :)
  nix_init_db, # Import from one nix DB to another
  openssh, # Copying to cache
  rsync, # hardlinking
  util-linuxMinimal, # mount, umount
}:
let
  pyproject = builtins.fromTOML (builtins.readFile ./pyproject.toml);
in
buildPythonApplication {
  pname = pyproject.project.name;
  version = pyproject.project.version;
  src = ./.;
  pyproject = true;
  build-system = [ hatchling ];
  dependencies = [
    coreutils
    cryptography
    csi-proto-python
    googleapis-common-protos
    gitMinimal
    kr8s
    shellous
    lix
    nix_init_db
    openssh
    rsync
    util-linuxMinimal
  ];
  meta.mainProgram = "nix-csi";
}
