{
  buildPythonApplication,
  hatchling,
  csi-proto-python, # CSI GRPC bindings
  cachetools,
  gitMinimal, # Lix requires Git CLI since it doesn't use libgit2
  lix, # We need a Nix implementation.... :)
  nix_init_db, # Import from one nix DB to another
  openssh, # Copying to cache
  rsync, # hardlinking
  util-linuxMinimal, # mount, umount
  coreutils, # ln
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
    csi-proto-python
    cachetools
    gitMinimal
    lix
    nix_init_db
    openssh
    rsync
    util-linuxMinimal
    coreutils
  ];
  meta.mainProgram = "nix-csi";
}
