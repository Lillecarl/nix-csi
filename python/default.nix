{
  buildPythonApplication,
  hatchling,
  csi-proto-python, # CSI GRPC bindings
  util-linuxMinimal, # mount, umount
  uutils-coreutils-noprefix, # ln
  rsync, # hardlinking
  openssh, # Copying to cache
  nix_init_db, # Import from one nix DB to another
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
    openssh
    rsync
    uutils-coreutils-noprefix
    nix_init_db
    csi-proto-python
    util-linuxMinimal
  ];
  meta.mainProgram = "nix-csi";
}
